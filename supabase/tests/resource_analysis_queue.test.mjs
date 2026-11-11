import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {test} from 'node:test';
const {PGlite}=await import(process.env.PGLITE_MODULE || '@electric-sql/pglite');
const names=['001_video_transcription','002_video_transcription_discovery','003_consolidate_video_transcripts','004_simplify_video_transcripts','005_save_resource_analysis','006_resource_analysis_queue','008_automatic_resource_analysis'];
const migrations=await Promise.all(names.map(name=>readFile(new URL(`../migrations/${name}.sql`,import.meta.url),'utf8')));
const scheduler=await readFile(new URL('../migrations/007_resource_analysis_scheduler.sql',import.meta.url),'utf8');
const resource='10000000-0000-0000-0000-000000000001',owner='20000000-0000-0000-0000-000000000001',object='30000000-0000-0000-0000-000000000001';
const url='https://example.supabase.co/storage/v1/object/public/videos/a.mp4';
async function setup(t,installQueue=true){
 const db=new PGlite();t.after(()=>db.close());
 await db.exec(`create role anon;create role authenticated;create role service_role bypassrls;
 create schema storage;
 create table storage.objects(id uuid primary key,bucket_id text,name text,version text,metadata jsonb,updated_at timestamptz default now());
 create table learning_resources(id uuid primary key,author_id uuid,title text,summary text,category text,body text,tags text[],kind text,external_url text,status text,moderation_hidden boolean,created_at timestamptz default now(),updated_at timestamptz default now());
 create table resource_index(resource_id uuid primary key references learning_resources(id),keywords text[] not null,topic_tags text[] not null,analysed_at timestamptz not null);
 alter table learning_resources enable row level security;alter table resource_index enable row level security;
 grant usage on schema public,storage to service_role;
 grant select,insert,update on all tables in schema public,storage to service_role;`);
 for(const sql of migrations.slice(0,installQueue?7:5))await db.exec(sql);
 await db.query(`insert into learning_resources(id,author_id,title,summary,category,body,tags,kind,external_url,status,moderation_hidden)
 values($1,$2,'Title','Summary','Category','Body',array['Dart'],'Video',$3,'published',false)`,[resource,owner,url]);
 await db.query("insert into storage.objects(id,bucket_id,name,version,metadata) values($1,'videos','a.mp4','v1','{}')",[object]);
 return db;
}
async function transcribe(db,version='v1'){
 await db.query('update storage.objects set version=$1',[version]);
 await db.query("select enqueue_video_transcription($1,$2,$3,'videos','a.mp4')",[resource,object,version]);
 const work=(await db.query('select claim_video_transcript() work')).rows[0].work;
 await db.query("select complete_video_transcript($1,$2,'Video text','en','[]')",[work.id,work.claim_token]);
 return work;
}
async function claim(db){return (await db.query('select claim_resource_analysis_job() job')).rows[0].job;}
async function finish(db,job){
 const source=(await db.query('select to_jsonb(r) data from learning_resources r')).rows[0].data;
 const transcript=(await db.query('select to_jsonb(t) data from video_transcripts t where id=$1',[job.transcript_id])).rows[0]?.data ?? null;
 return (await db.query("select complete_resource_analysis_job($1,$2,$3,$4,array['dart'],array['mobile development']) saved",[job.id,job.claim_token,source,transcript])).rows[0].saved;
}
async function fail(db,job){return (await db.query("select fail_resource_analysis_job($1,$2,'gemini_unavailable') ok",[job.id,job.claim_token])).rows[0].ok;}

test('ready completion queues atomically and repeated completion/backfill creates one job',async t=>{
 const db=await setup(t);await db.exec('set role service_role');const transcript=await transcribe(db);
 await db.query("select complete_video_transcript($1,$2,'Duplicate','en','[]')",[transcript.id,transcript.claim_token]);
 await db.query('select enqueue_ready_resource_analysis()');
 const jobs=(await db.query('select * from resource_analysis_jobs')).rows;
 assert.equal(jobs.length,1);assert.equal(jobs[0].transcript_id,transcript.id);assert.equal(jobs[0].source_version,'v1');
 const job=await claim(db);const saved=await finish(db,job);
 assert.equal(saved.resource_id,resource);
 assert.equal((await db.query('select status from resource_analysis_jobs')).rows[0].status,'ready');
 assert.equal(await claim(db),null);
});

test('a queue insert failure rolls back transcript completion',async t=>{
 const db=await setup(t);
 await db.exec("alter table resource_analysis_jobs add constraint force_failure check(false)");
 await db.query("select enqueue_video_transcription($1,$2,'v1','videos','a.mp4')",[resource,object]);
 const work=(await db.query('select claim_video_transcript() work')).rows[0].work;
 await assert.rejects(db.query("select complete_video_transcript($1,$2,'Video text','en','[]')",[work.id,work.claim_token]),/force_failure/);
 assert.deepEqual((await db.query('select status,transcript_text from video_transcripts')).rows,[{status:'processing',transcript_text:null}]);
});

test('existing ready transcripts backfill safely; drafts need an explicit resource UUID',async t=>{
 const db=await setup(t,false);await db.exec("update learning_resources set status='draft'");await transcribe(db);
 await db.exec(migrations[5]);await db.exec(migrations[6]);
 assert.equal((await db.query('select enqueue_ready_resource_analysis() n')).rows[0].n,0);
 await assert.rejects(db.query('select enqueue_ready_resource_analysis(null,true)'),/Invalid analysis backfill/);
 assert.equal((await db.query('select enqueue_ready_resource_analysis($1,true) n',[resource])).rows[0].n,1);
 assert.equal((await db.query('select enqueue_ready_resource_analysis($1,true) n',[resource])).rows[0].n,0);
 const job=await claim(db);assert.equal(job.allow_draft,true);await finish(db,job);
 assert.equal((await db.query('select count(*)::int n from resource_index')).rows[0].n,1);
});

test('replacement creates a new job; old work cannot overwrite the current index',async t=>{
 const db=await setup(t);await transcribe(db);const old=await claim(db);
 await transcribe(db,'v2');const current=await claim(db);assert.notEqual(old.id,current.id);
 const saved=await finish(db,current);
 await assert.rejects(finish(db,old),/Video changed/);
 assert.deepEqual((await db.query('select to_jsonb(i) saved from resource_index i')).rows[0].saved,saved);
 assert.equal((await db.query('select status from resource_analysis_jobs where id=$1',[old.id])).rows[0].status,'processing');
});

test('analysis failure preserves valid index and retries analysis up to three attempts',async t=>{
 const db=await setup(t);await transcribe(db);await finish(db,await claim(db));
 const original=(await db.query('select to_jsonb(i) saved from resource_index i')).rows[0].saved;
 await transcribe(db,'v2');
 for(let attempt=1;attempt<=3;attempt++){
  const job=await claim(db);assert.equal(job.attempt_count,attempt);assert.equal(await fail(db,job),true);
  assert.equal(await claim(db),null);
  if(attempt<3)await db.exec("update resource_analysis_jobs set next_attempt_at=now()-interval '1 second' where status='pending'");
 }
 assert.equal((await db.query("select status from resource_analysis_jobs where source_version='v2'")).rows[0].status,'failed');
 assert.equal((await db.query('select enqueue_ready_resource_analysis() n')).rows[0].n,0);
 assert.equal(await claim(db),null);
 assert.deepEqual((await db.query('select to_jsonb(i) saved from resource_index i')).rows[0].saved,original);
 assert.equal((await db.query("select status from video_transcripts where source_version='v2'")).rows[0].status,'ready');
});

test('expired leases recover, stale workers cannot finish, and final expired attempts terminate',async t=>{
 const db=await setup(t);await transcribe(db);
 const claims=await Promise.all([claim(db),claim(db)]);assert.equal(claims.filter(Boolean).length,1);const old=claims.find(Boolean);
 await db.exec("update resource_analysis_jobs set lease_expires_at=now()-interval '1 second'");
 const next=await claim(db);assert.notEqual(next.claim_token,old.claim_token);
 await assert.rejects(finish(db,old),/claim lost/);assert.equal(await fail(db,old),false);
 await db.exec("update resource_analysis_jobs set lease_expires_at=now()-interval '1 second',attempt_count=3");
 assert.equal(await claim(db),null);
 assert.equal((await db.query('select status from resource_analysis_jobs')).rows[0].status,'failed');
});

test('hidden/archive and draft transitions cannot save; clients cannot use queue RPCs',async t=>{
 const db=await setup(t);await transcribe(db);const job=await claim(db);
 for(const change of ["moderation_hidden=true","status='archived'","status='draft'"]){
  await db.exec(`update learning_resources set ${change}`);await assert.rejects(finish(db,job),/Resource ineligible/);
  await db.exec("update learning_resources set moderation_hidden=false,status='published'");
 }
 for(const role of ['anon','authenticated']){
  await db.exec(`set role ${role}`);await assert.rejects(claim(db),/permission denied/);
  await assert.rejects(db.query('select enqueue_ready_resource_analysis($1,true)',[resource]),/permission denied/);
  await db.exec('reset role');
 }
 assert.equal((await db.query('select count(*)::int n from resource_index')).rows[0].n,0);
});

test('scheduler SQL uses dedicated Vault secrets and bounded HTTP timeout (extension stubs)',async t=>{
 const db=await setup(t);
 await db.exec(`create schema vault;create schema net;create schema cron;
 create table vault.decrypted_secrets(name text,decrypted_secret text);
 create table public.http_calls(url text,headers jsonb,body jsonb,timeout integer);
 create function net.http_post(url text,headers jsonb,body jsonb,timeout_milliseconds integer) returns bigint language plpgsql as $$begin insert into public.http_calls values(url,headers,body,timeout_milliseconds);return 1;end$$;
 create table public.schedules(name text,expression text,command text);
 create function cron.schedule(name text,expression text,command text) returns bigint language plpgsql as $$begin insert into public.schedules values(name,expression,command);return 1;end$$;`);
 await db.exec(scheduler.replace(/^create extension[^;]+;/gm,''));
 await db.query('select invoke_resource_analysis_queue()');assert.equal((await db.query('select count(*)::int n from http_calls')).rows[0].n,0);
 await db.exec("insert into vault.decrypted_secrets values('resource_analysis_url','https://example.supabase.co'),('resource_analysis_cron_secret',repeat('x',40))");
 await db.query('select invoke_resource_analysis_queue()');
 const call=(await db.query('select * from http_calls')).rows[0];assert.equal(call.timeout,75000);assert.deepEqual(call.body,{});assert.ok(call.url.endsWith('/resource-analysis-queue'));assert.equal(call.headers['x-resource-analysis-secret'],'x'.repeat(40));
 assert.equal((await db.query('select expression from schedules')).rows[0].expression,'* * * * *');
});


test('index save rolls back if queue completion fails; retry saves once and stale completion is rejected',async t=>{
 const db=await setup(t);await transcribe(db);const job=await claim(db);
 await db.exec("alter table resource_analysis_jobs add constraint reject_ready check(status<>'ready')");
 await assert.rejects(finish(db,job),/reject_ready/);
 assert.equal((await db.query('select count(*)::int n from resource_index')).rows[0].n,0);
 assert.equal((await db.query('select status from resource_analysis_jobs')).rows[0].status,'processing');
 await db.exec('alter table resource_analysis_jobs drop constraint reject_ready');
 const saved=await finish(db,job);
 await assert.rejects(finish(db,job),/claim lost/);
 assert.equal(await claim(db),null);
 assert.deepEqual((await db.query('select to_jsonb(i) saved from resource_index i')).rows[0].saved,saved);
});


test('published text queues on save; timestamps and duplicate backfill do not repeat work',async t=>{
 const db=await setup(t);
 await db.exec("update learning_resources set kind='Article',external_url=null");
 let jobs=(await db.query('select * from resource_analysis_jobs')).rows;
 assert.equal(jobs.length,1);assert.equal(jobs[0].transcript_id,null);
 await finish(db,await claim(db));
 await db.exec('update learning_resources set updated_at=clock_timestamp()');
 assert.equal((await db.query('select enqueue_ready_resource_analysis() n')).rows[0].n,0);
 assert.equal((await db.query('select count(*)::int n from resource_analysis_jobs')).rows[0].n,1);
 await db.exec("update learning_resources set body='A new lesson about TypeScript'");
 jobs=(await db.query('select * from resource_analysis_jobs')).rows;
 assert.equal(jobs.length,2);assert.notEqual(jobs[0].content_version,jobs[1].content_version);
 await finish(db,await claim(db));
 assert.equal((await db.query('select count(*)::int n from resource_index')).rows[0].n,1);
 // Reverting to an older content version must refresh an index saved for B.
 await db.exec("update learning_resources set body='Body'");
 const reverted=await claim(db);assert.ok(reverted);await finish(db,reverted);
 assert.equal((await db.query('select enqueue_ready_resource_analysis() n')).rows[0].n,0);
});

test('text drafts, hidden resources and missing extracted body are not scanned',async t=>{
 const db=await setup(t);
 await db.exec("update learning_resources set kind='PDF',body=null");
 assert.equal(await claim(db),null);
 await db.exec("update learning_resources set kind='Article',body='Saved text',status='draft'");
 assert.equal((await db.query('select enqueue_ready_resource_analysis() n')).rows[0].n,0);
 await db.query('select enqueue_ready_resource_analysis($1,true)',[resource]);
 const draft=await claim(db);assert.equal(draft.allow_draft,true);await finish(db,draft);
 await db.exec("update learning_resources set moderation_hidden=true,body='Hidden changes',status='published'");
 assert.equal((await db.query('select enqueue_ready_resource_analysis() n')).rows[0].n,0);
 await db.exec('update learning_resources set moderation_hidden=false');
 assert.ok(await claim(db));
});

test('metadata edits reject stale text and video work, preserving the saved result',async t=>{
 const db=await setup(t);await transcribe(db);const old=await claim(db);
 const snapshot=(await db.query('select to_jsonb(r) source from learning_resources r')).rows[0].source;
 const transcript=(await db.query('select to_jsonb(t) source from video_transcripts t')).rows[0].source;
 await db.exec("update learning_resources set title='New title'");
 await assert.rejects(db.query("select complete_resource_analysis_job($1,$2,$3,$4,array['old'],array['old'])",[old.id,old.claim_token,snapshot,transcript]),/Resource changed/);
 const current=await claim(db);await finish(db,current);
 assert.equal((await db.query('select keywords from resource_index')).rows[0].keywords[0],'dart');
 await assert.rejects(finish(db,old),/Analysis source changed/);
});

test('replacement URL never queues the old path and encoded paths match the current file',async t=>{
 const db=await setup(t);await transcribe(db);await finish(db,await claim(db));
 await db.exec("update learning_resources set external_url='https://example.supabase.co/storage/v1/object/public/videos/new%20lesson.mp4'");
 assert.equal(await claim(db),null);
 await db.exec("insert into storage.objects(id,bucket_id,name,version,metadata) values('30000000-0000-0000-0000-000000000002','videos','new lesson.mp4','v2','{}')");
 await db.query("select enqueue_video_transcription($1,'30000000-0000-0000-0000-000000000002','v2','videos','new lesson.mp4')",[resource]);
 const work=(await db.query('select claim_video_transcript() work')).rows[0].work;
 await db.query("select complete_video_transcript($1,$2,'New video','en','[]')",[work.id,work.claim_token]);
 const job=await claim(db);assert.equal(job.transcript_id,work.id);await finish(db,job);
});

test('migration preserves legacy jobs and index; backfill queues current content once',async t=>{
 const db=await setup(t,false);await db.exec(migrations[5]);await transcribe(db);
 const job=await claim(db);await finish(db,job);
 const saved=(await db.query('select to_jsonb(i) data from resource_index i')).rows[0].data;
 await db.exec(migrations[6]);
 assert.equal((await db.query('select count(*)::int n from resource_analysis_jobs')).rows[0].n,1);
 assert.deepEqual((await db.query('select to_jsonb(i) data from resource_index i')).rows[0].data,saved);
 assert.equal((await db.query('select enqueue_ready_resource_analysis() n')).rows[0].n,1);
 assert.equal((await db.query('select enqueue_ready_resource_analysis() n')).rows[0].n,0);
 assert.ok((await claim(db)).content_version.length===64);
});

test('resource trigger works through author RLS without granting clients queue access',async t=>{
 const db=await setup(t);
 await db.exec(`grant select,update on learning_resources to authenticated;
 create policy author_update on learning_resources for all to authenticated using(author_id='${owner}') with check(author_id='${owner}');
 set role authenticated;`);
 await db.exec("update learning_resources set kind='Article'");
 await assert.rejects(db.query('select enqueue_resource_analysis($1,true)',[resource]),/permission denied/);
 await assert.rejects(db.query('select * from resource_analysis_jobs'),/permission denied/);
 await db.exec('reset role');assert.ok(await claim(db));
});


test('published inserts queue atomically and a failed enqueue rolls back the resource insert',async t=>{
 const db=await setup(t);
 const insert=`insert into learning_resources(id,author_id,title,body,kind,status,moderation_hidden)
 values($1,$2,'A lesson','Dart widgets','Article','published',false)`;
 const id='10000000-0000-0000-0000-000000000002';
 await db.query(insert,[id,owner]);
 const job=await claim(db);assert.equal(job.resource_id,id);assert.equal(job.transcript_id,null);
 await db.exec("alter table resource_analysis_jobs add constraint reject_new_text check(resource_id<>'10000000-0000-0000-0000-000000000003')");
 await assert.rejects(db.query(insert,['10000000-0000-0000-0000-000000000003',owner]),/reject_new_text/);
 assert.equal((await db.query("select count(*)::int n from learning_resources where id='10000000-0000-0000-0000-000000000003'")).rows[0].n,0);
});

test('unfinished legacy work is retained and a separate current content job can complete',async t=>{
 const db=await setup(t,false);await db.exec(migrations[5]);await transcribe(db);
 const old=await claim(db);await db.exec(migrations[6]);
 const preserved=(await db.query('select * from resource_analysis_jobs where id=$1',[old.id])).rows[0];
 assert.equal(preserved.status,'processing');assert.equal(preserved.claim_token,old.claim_token);assert.equal(preserved.attempt_count,1);
 await db.query('select enqueue_ready_resource_analysis()');
 const current=await claim(db);assert.notEqual(current.id,old.id);await finish(db,current);
 await assert.rejects(finish(db,old),/Analysis source changed/);
});
