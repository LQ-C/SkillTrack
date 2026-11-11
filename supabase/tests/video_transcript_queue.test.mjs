// Local fixture only. No network, Supabase credentials or model download.
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { test } from 'node:test';
const { PGlite } = await import(process.env.PGLITE_MODULE || '@electric-sql/pglite');
const queue = await readFile(new URL('../migrations/001_video_transcription.sql', import.meta.url), 'utf8');
const discovery = await readFile(new URL('../migrations/002_video_transcription_discovery.sql', import.meta.url), 'utf8');
const consolidated = await readFile(new URL('../migrations/003_consolidate_video_transcripts.sql', import.meta.url), 'utf8');
const simplified = await readFile(new URL('../migrations/004_simplify_video_transcripts.sql', import.meta.url), 'utf8');
const resource = '10000000-0000-0000-0000-000000000001';
const object = '20000000-0000-0000-0000-000000000001';
const url = 'https://example.supabase.co/storage/v1/object/public/videos/a.mp4';
async function setup(t, simplify = true) {
  const db = new PGlite();
  t.after(() => db.close());
  await db.exec(`
    create role anon; create role authenticated; create role service_role bypassrls;
    create schema storage;
    create table storage.objects(id uuid primary key, bucket_id text, name text,
      version text, metadata jsonb, updated_at timestamptz);
    create table public.learning_resources(id uuid primary key, kind text, status text,
      moderation_hidden boolean not null default false, external_url text);
    grant usage on schema public, storage to service_role;
    grant select on public.learning_resources, storage.objects to service_role;
    -- SELECT FOR SHARE also requires UPDATE privilege in PostgreSQL.
    grant update on public.learning_resources, storage.objects to service_role;
  `);
  await db.exec(queue);
  await db.exec(discovery);
  await db.exec(consolidated);
  if (simplify) await db.exec(simplified);
  await db.query(`insert into learning_resources values($1, 'Video','published',false,$2)`, [resource,url]);
  await db.query(`insert into storage.objects values($1,'videos','a.mp4','v1','{}',now())`, [object]);
  return db;
}
async function enqueue(db, draft = false) {
  return (await db.query(`select enqueue_discovered_video($1,$2,'videos','a.mp4',$3) id`,
    [resource,url,draft])).rows[0].id;
}


async function claim(db) {
  return (await db.query('select claim_video_transcript(60) work')).rows[0].work;
}
async function complete(db, work, text='saved text') {
  return (await db.query(`select complete_video_transcript($1,$2,$3,'en','[]') ok`,
    [work.id,work.claim_token,text])).rows[0].ok;
}
async function fail(db, work) {
  return (await db.query(`select fail_video_transcript($1,$2,'download_failed') ok`,
    [work.id,work.claim_token])).rows[0].ok;
}

test('final schema has one table, one row identity, nullable pending text and enforced ready text',async t=>{
  const db=await setup(t);
  assert.equal((await db.query("select to_regclass('public.video_transcription_jobs') old")).rows[0].old,null);
  const fields=(await db.query("select column_name from information_schema.columns where table_schema='public' and table_name='video_transcripts'")).rows.map(r=>r.column_name);
  for(const field of ['job_id','queued_at','completed_at','max_attempts']) assert.ok(!fields.includes(field));
  const id=await enqueue(db);
  const row=(await db.query('select * from video_transcripts')).rows[0];
  assert.equal(row.id,id); assert.equal(row.transcript_text,null); assert.equal(row.status,'pending');
  assert.equal(await enqueue(db),id);
  const work=await claim(db);
  assert.equal(work.id,id); assert.ok(!('job_id' in work));
  await assert.rejects(complete(db,work,''),/Invalid transcript/);
  await assert.rejects(db.query("update video_transcripts set status='ready',lease_expires_at=null"),/ready_check/);
  assert.equal(await complete(db,work),true);
  assert.equal(await complete(db,work,'duplicate'),true);
  assert.equal((await db.query('select transcript_text from video_transcripts')).rows[0].transcript_text,'saved text');
});

test('migration preserves completed text and unfinished rows, identifiers, leases and timestamps',async t=>{
  const db=await setup(t,false);
  await enqueue(db);
  const ready=(await db.query('select claim_transcription_job() work')).rows[0].work;
  await db.query(`select complete_transcription_job($1,$2,'existing text','en','[]')`,[ready.job_id,ready.claim_token]);
  await db.exec("update storage.objects set version='v2'");
  await enqueue(db);
  const active=(await db.query('select claim_transcription_job() work')).rows[0].work;
  await db.exec("update storage.objects set version='v3'");
  await enqueue(db);
  await db.exec("update storage.objects set version='v4'");
  const failed=await enqueue(db);
  await db.query("update video_transcripts set status='failed',attempt_count=3 where job_id=$1",[failed]);
  const before=(await db.query('select * from video_transcripts order by source_version')).rows;
  await db.exec(simplified);
  const after=(await db.query('select * from video_transcripts order by source_version')).rows;
  assert.equal(after.length,4);
  for(let i=0;i<4;i++) for(const key of Object.keys(after[i])) assert.deepEqual(after[i][key],before[i][key]);
  assert.equal((await db.query('select renew_video_transcript($1,$2,60) ok',[active.transcript_id,active.claim_token])).rows[0].ok,true);
  assert.equal(await complete(db,{id:active.transcript_id,claim_token:active.claim_token}),true);
});

test('exclusive claims, lease recovery and fixed three-attempt retry limit',async t=>{
  const db=await setup(t);
  await enqueue(db);
  const claims=await Promise.all([claim(db),claim(db)]);
  assert.equal(claims.filter(Boolean).length,1);
  const first=claims.find(Boolean);
  await db.exec("update video_transcripts set lease_expires_at=now()-interval '1 second'");
  const second=await claim(db);
  assert.notEqual(first.claim_token,second.claim_token);
  assert.equal(await complete(db,first),false);
  assert.equal(await fail(db,first),false);
  assert.equal(await fail(db,second),true);
  assert.equal(await claim(db),null);
  await db.exec("update video_transcripts set next_attempt_at=now()-interval '1 second'");
  const third=await claim(db);
  assert.equal(await fail(db,third),true);
  assert.equal(await claim(db),null);
  assert.equal(await enqueue(db),third.id);
  assert.deepEqual((await db.query('select status,attempt_count,transcript_text from video_transcripts')).rows,
    [{status:'failed',attempt_count:3,transcript_text:null}]);
});

test('replacement gets a new pending row and the reader excludes historical text',async t=>{
  const db=await setup(t);
  const oldId=await enqueue(db);
  await complete(db,await claim(db));
  const read=()=>db.query(`select id from read_ready_video_transcript($1,$2,'videos','a.mp4')`,[resource,url]);
  assert.equal((await read()).rows[0].id,oldId);
  await db.exec("update storage.objects set version='v2'");
  assert.deepEqual((await read()).rows,[]);
  const nextId=await enqueue(db);
  assert.notEqual(nextId,oldId);
  assert.deepEqual((await read()).rows,[]);
  await complete(db,await claim(db),'new text');
  assert.equal((await read()).rows[0].id,nextId);
  assert.equal((await db.query('select count(*)::int n from video_transcripts')).rows[0].n,2);
});

test('unknown routine and view dependencies stop column removal and roll back changes',async t=>{
  const db=await setup(t,false);
  await db.exec(`create function external_reader() returns uuid language plpgsql as $$
    begin return (select job_id from public.video_transcripts limit 1); end $$`);
  await assert.rejects(db.exec(simplified),/Review transcription dependencies/);
  await db.exec('rollback');
  await db.exec('drop function external_reader()');
  await db.exec('create view external_reader as select job_id from video_transcripts');
  await assert.rejects(db.exec(simplified),/depend/);
  await db.exec('rollback');
  assert.ok((await db.query("select to_regprocedure('claim_transcription_job(integer)') old")).rows[0].old);
  assert.equal((await db.query("select to_regprocedure('claim_video_transcript(integer)') new")).rows[0].new,null);
});

test('backend-only RPC permissions and RLS survive simplification',async t=>{
  const db=await setup(t);
  await enqueue(db);
  assert.equal((await db.query("select relrowsecurity from pg_class where oid='video_transcripts'::regclass")).rows[0].relrowsecurity,true);
  for(const role of ['anon','authenticated']) {
    await db.exec(`set role ${role}`);
    await assert.rejects(claim(db),/permission denied/);
    await assert.rejects(db.query("update video_transcripts set transcript_text='fake'"),/permission denied/);
    await db.exec('reset role');
  }
  await db.exec('set role service_role');
  const work=await claim(db);
  assert.ok(work.id);
  assert.equal(await complete(db,work),true);
});
