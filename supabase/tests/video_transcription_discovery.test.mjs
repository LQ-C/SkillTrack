// Local fixture only. No network, Supabase credentials or model download.
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { test } from 'node:test';
const { PGlite } = await import(process.env.PGLITE_MODULE || '@electric-sql/pglite');
const queue = await readFile(new URL('../migrations/001_video_transcription.sql', import.meta.url), 'utf8');
const discovery = await readFile(new URL('../migrations/002_video_transcription_discovery.sql', import.meta.url), 'utf8');
const consolidated = await readFile(new URL('../migrations/003_consolidate_video_transcripts.sql', import.meta.url), 'utf8');
const resource = '10000000-0000-0000-0000-000000000001';
const object = '20000000-0000-0000-0000-000000000001';
const url = 'https://example.supabase.co/storage/v1/object/public/videos/a.mp4';
async function setup(t, migrate = true) {
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
  if (migrate) await db.exec(consolidated);
  await db.query(`insert into learning_resources values($1, 'Video','published',false,$2)`, [resource,url]);
  await db.query(`insert into storage.objects values($1,'videos','a.mp4','v1','{}',now())`, [object]);
  return db;
}
async function enqueue(db, draft = false) {
  return (await db.query(`select enqueue_discovered_video($1,$2,'videos','a.mp4',$3) id`,
    [resource,url,draft])).rows[0].id;
}

test('published candidates are bounded and paginated; drafts require an explicit UUID', async t => {
  const db=await setup(t);
  await db.exec(`insert into learning_resources select
    ('10000000-0000-0000-0000-' || lpad(i::text,12,'0'))::uuid,
    'Video','published',false,'${url}' from generate_series(2,5) i`);
  const page=(await db.query('select * from video_transcription_candidates(2)')).rows;
  assert.equal(page.length,2);
  assert.equal((await db.query('select * from video_transcription_candidates(2,$1)',[page[1].id])).rows.length,2);
  await db.query("update learning_resources set status='draft' where id=$1",[resource]);
  assert.equal((await db.query('select * from video_transcription_candidates(25,null,$1)',[resource])).rows.length,1);
  assert.equal(await enqueue(db),null);
  assert.ok(await enqueue(db,true));
  await db.query('update learning_resources set moderation_hidden=true where id=$1',[resource]);
  assert.equal((await db.query('select * from video_transcription_candidates(25,null,$1)',[resource])).rows.length,0);
  assert.equal(await enqueue(db,true),null);
});

test('discovery reuses jobs and never resets terminal failures; replacement gets a new job',async t=>{
  const db=await setup(t);
  const first=await enqueue(db);
  assert.equal(await enqueue(db),first);
  await db.query("update video_transcripts set status='failed',attempt_count=3 where job_id=$1",[first]);
  assert.equal(await enqueue(db),first);
  assert.deepEqual((await db.query('select status,attempt_count from video_transcripts')).rows,
    [{status:'failed',attempt_count:3}]);
  await db.exec("update storage.objects set version='v2'");
  assert.notEqual(await enqueue(db),first);
  assert.equal((await db.query('select count(*)::int n from video_transcripts')).rows[0].n,2);
});

test('completed transcript is skipped and identity is preserved atomically',async t=>{
  const db=await setup(t);
  const id=await enqueue(db);
  const claim=(await db.query('select claim_transcription_job() job')).rows[0].job;
  assert.equal(claim.job_id,id);
  await db.query("select complete_transcription_job($1,$2,'text','en','[]')",[id,claim.claim_token]);
  assert.equal(await enqueue(db),null);
  assert.deepEqual((await db.query('select resource_id,source_file_id,source_version from video_transcripts')).rows,
    [{resource_id:resource,source_file_id:object,source_version:'v1'}]);
  assert.equal((await db.query('select status from video_transcripts')).rows[0].status,'ready');
});

test('missing objects, changed references, hidden, non-video and archived resources are skipped',async t=>{
  const db=await setup(t);
  for(const update of ["external_url='https://youtube.com/x'", "moderation_hidden=true", "kind='PDF'", "status='archived'"]) {
    await db.exec(`update learning_resources set ${update}`);
    assert.equal(await enqueue(db,true),null);
    await db.query("update learning_resources set external_url=$1,moderation_hidden=false,kind='Video',status='published'",[url]);
  }
  await db.exec('delete from storage.objects');
  assert.equal(await enqueue(db),null);
});

test('Storage metadata fallback detects replacement; RPCs are backend only',async t=>{
  const db=await setup(t);
  await db.exec(`update storage.objects set version=null,metadata='{"eTag":"first"}'`);
  const first=await enqueue(db);
  await db.exec(`update storage.objects set metadata='{"eTag":"second"}'`);
  assert.notEqual(await enqueue(db),first);
  await db.exec("update storage.objects set metadata='{}',updated_at='2026-11-09T00:00:00Z'");
  const second=await enqueue(db);
  await db.exec("update storage.objects set updated_at='2026-11-09T00:01:00Z'");
  assert.notEqual(await enqueue(db),second);
  for (const role of ['anon','authenticated']) {
    await db.exec(`set role ${role}`);
    await assert.rejects(db.query('select * from video_transcription_candidates()'), /permission denied/);
    await assert.rejects(enqueue(db), /permission denied/);
    await db.exec('reset role');
  }
  await db.exec('set role service_role');
  assert.equal((await db.query('select * from video_transcription_candidates()')).rows.length,1);
  assert.ok(await enqueue(db));
});

async function claim(db) {
  return (await db.query('select claim_transcription_job(60) job')).rows[0].job;
}
async function complete(db, work, text = 'saved text') {
  return (await db.query(`select complete_transcription_job($1,$2,$3,'en','[]') ok`,
    [work.job_id,work.claim_token,text])).rows[0].ok;
}
async function readReady(db) {
  return (await db.query(`select * from read_ready_video_transcript($1,$2,'videos','a.mp4')`,
    [resource,url])).rows;
}

test('migration preserves completed IDs and every unfinished work state including an active claim', async t => {
  const db=await setup(t,false);
  await enqueue(db);
  const ready=await claim(db);
  await complete(db,ready);
  const original=(await db.query('select * from video_transcripts')).rows[0];
  await db.exec("update storage.objects set version='v2'");
  await enqueue(db);
  const active=await claim(db);
  await db.exec("update storage.objects set version='v3'");
  await enqueue(db);
  await db.exec("update storage.objects set version='v4'");
  const failed=await enqueue(db);
  await db.query("update video_transcription_jobs set status='failed',attempt_count=3,error_code='download_failed' where id=$1",[failed]);
  const before=(await db.query('select * from video_transcription_jobs order by source_version')).rows;
  await db.exec(consolidated);
  assert.equal((await db.query("select to_regclass('public.video_transcription_jobs') gone")).rows[0].gone,null);
  const after=(await db.query('select * from video_transcripts order by source_version')).rows;
  assert.equal(after.length,4);
  for(let i=0;i<4;i++) {
    for(const key of ['status','attempt_count','max_attempts','claim_token','lease_expires_at','next_attempt_at','error_code','updated_at','completed_at'])
      assert.deepEqual(after[i][key],before[i][key]);
    assert.equal(after[i].job_id,before[i].id);
  }
  for(const key of ['id','created_at','transcript_text','language','segments'])
    assert.deepEqual(after[0][key],original[key]);
  assert.equal(after[1].transcript_text,null);
  assert.equal((await db.query('select renew_transcription_claim($1,$2,60) ok',[active.job_id,active.claim_token])).rows[0].ok,true);
  assert.equal(await complete(db,active),true);
  assert.equal(await complete(db,active,'ignored duplicate text'),true);
  assert.equal((await db.query('select transcript_text from video_transcripts where job_id=$1',[active.job_id])).rows[0].transcript_text,'saved text');
});

test('claims are exclusive, expired claims recover, stale completion fails and attempts terminate',async t=>{
  const db=await setup(t);
  const id=await enqueue(db);
  const claims=await Promise.all([claim(db),claim(db)]);
  assert.equal(claims.filter(Boolean).length,1);
  const first=claims.find(Boolean);
  await db.query("update video_transcripts set lease_expires_at=now()-interval '1 second' where job_id=$1",[id]);
  const second=await claim(db);
  assert.notEqual(first.claim_token,second.claim_token);
  assert.equal(await complete(db,first),false);
  assert.equal((await db.query('select renew_transcription_claim($1,$2,60) ok',[id,first.claim_token])).rows[0].ok,false);
  assert.equal((await db.query("select fail_transcription_job($1,$2,'download_failed') ok",[id,second.claim_token])).rows[0].ok,true);
  assert.equal(await claim(db),null);
  await db.exec("update video_transcripts set next_attempt_at=now()-interval '1 second'");
  const third=await claim(db);
  assert.ok(third);
  await db.exec("update video_transcripts set lease_expires_at=now()-interval '1 second'");
  assert.equal(await claim(db),null);
  assert.equal((await db.query('select status from video_transcripts')).rows[0].status,'failed');
  assert.equal(await enqueue(db),id);
  assert.equal(await complete(db,third),false);
});

test('reader rejects unfinished, obsolete or hidden content and permits only current ready text',async t=>{
  const db=await setup(t);
  await enqueue(db);
  assert.deepEqual(await readReady(db),[]);
  const work=await claim(db);
  await assert.rejects(complete(db,work,''), /Invalid transcript/);
  assert.equal(await complete(db,work),true);
  assert.equal((await readReady(db))[0].transcript_text,'saved text');
  await db.exec("update storage.objects set version='v2'");
  assert.deepEqual(await readReady(db),[]);
  const replacement=await enqueue(db);
  assert.notEqual(replacement,work.job_id);
  assert.deepEqual(await readReady(db),[]);
  await complete(db,await claim(db),'replacement text');
  assert.equal((await readReady(db))[0].transcript_text,'replacement text');
  await db.exec('update learning_resources set moderation_hidden=true');
  assert.deepEqual(await readReady(db),[]);
  await db.exec("set role authenticated");
  await assert.rejects(readReady(db), /permission denied/);
  await assert.rejects(db.query('select * from video_transcripts'), /permission denied/);
});

test('inconsistent deployed data aborts migration without losing source tables',async t=>{
  const db=await setup(t,false);
  await enqueue(db);
  await db.exec("update video_transcription_jobs set status='ready'");
  await assert.rejects(db.exec(consolidated), /Inconsistent transcription data/);
  await db.exec('rollback');
  assert.equal((await db.query('select count(*)::int n from video_transcription_jobs')).rows[0].n,1);
  assert.equal((await db.query("select count(*)::int n from information_schema.columns where table_name='video_transcripts' and column_name='status'")).rows[0].n,0);
});

test('ready requires text; failure at max attempts is terminal and clients cannot claim',async t=>{
  const db=await setup(t);
  await enqueue(db);
  await assert.rejects(db.exec("update video_transcripts set status='ready'"),/video_transcripts_ready_check/);
  await db.exec('update video_transcripts set max_attempts=1');
  const work=await claim(db);
  await db.query("select fail_transcription_job($1,$2,'transcription_failed')",[work.job_id,work.claim_token]);
  assert.deepEqual((await db.query('select status,transcript_text,attempt_count from video_transcripts')).rows,
    [{status:'failed',transcript_text:null,attempt_count:1}]);
  assert.equal(await claim(db),null);
  for(const role of ['anon','authenticated']) {
    await db.exec(`set role ${role}`);
    await assert.rejects(claim(db), /permission denied/);
    await assert.rejects(complete(db,work), /permission denied/);
    await db.exec('reset role');
  }
});


test('unexpected dependencies abort the final drop and roll back copied state',async t=>{
  const db=await setup(t,false);
  await enqueue(db);
  await db.exec('create view unexpected_queue_consumer as select * from video_transcription_jobs');
  await assert.rejects(db.exec(consolidated), /depend/);
  await db.exec('rollback');
  assert.equal((await db.query('select count(*)::int n from video_transcription_jobs')).rows[0].n,1);
  assert.equal((await db.query('select count(*)::int n from video_transcripts')).rows[0].n,0);
  assert.equal((await db.query("select count(*)::int n from information_schema.columns where table_name='video_transcripts' and column_name='status'")).rows[0].n,0);
});

test('enqueue requires both a real video resource and the uploaded Storage object',async t=>{
  const db=await setup(t);
  await db.exec('delete from learning_resources');
  await assert.rejects(db.query("select enqueue_video_transcription($1,$2,'v1','videos','a.mp4')",[resource,object]), /Eligible video resource not found/);
  assert.equal((await db.query('select count(*)::int n from video_transcripts')).rows[0].n,0);
});


test('stored routine references to the old table stop its removal',async t=>{
  const db=await setup(t,false);
  await enqueue(db);
  await db.exec(`create function external_queue_reader() returns bigint language plpgsql as $$
    begin return (select count(*) from public.video_transcription_jobs); end $$`);
  await assert.rejects(db.exec(consolidated), /Review old transcription table dependencies/);
  await db.exec('rollback');
  assert.equal((await db.query('select external_queue_reader()::int n')).rows[0].n,1);
  assert.equal((await db.query('select count(*)::int n from video_transcripts')).rows[0].n,0);
});
