import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {test} from 'node:test';
const {PGlite}=await import(process.env.PGLITE_MODULE || '@electric-sql/pglite');
const {vector}=await import(process.env.PGVECTOR_MODULE || '@electric-sql/pglite-pgvector');
const names=['001_video_transcription','002_video_transcription_discovery','003_consolidate_video_transcripts','004_simplify_video_transcripts','005_save_resource_analysis','006_resource_analysis_queue','008_automatic_resource_analysis','009_semantic_resource_recommendations','010_manual_task_recommendations'];
const migrations=await Promise.all(names.map(name=>readFile(new URL(`../migrations/${name}.sql`,import.meta.url),'utf8')));
const owner='10000000-0000-0000-0000-000000000001', stranger='10000000-0000-0000-0000-000000000002';
const task='20000000-0000-0000-0000-000000000001', project='30000000-0000-0000-0000-000000000001', board='40000000-0000-0000-0000-000000000001';
const relevant='50000000-0000-0000-0000-000000000001',unrelated='50000000-0000-0000-0000-000000000002';
const vec=(cosine=1)=>JSON.stringify([cosine,Math.sqrt(1-cosine*cosine),...Array(382).fill(0)]);
async function setup(t){
 const db=new PGlite({extensions:{vector}});t.after(()=>db.close());
 await db.exec(`create role anon;create role authenticated;create role service_role bypassrls;create schema storage;
 create table storage.objects(id uuid primary key,bucket_id text,name text,version text,metadata jsonb,updated_at timestamptz default now());
 create table learning_resources(id uuid primary key,author_id uuid,title text,summary text,category text,body text,tags text[],kind text,external_url text,status text,moderation_hidden boolean,created_at timestamptz default now(),updated_at timestamptz default now());
 create table resource_index(resource_id uuid primary key references learning_resources(id),keywords text[] not null,topic_tags text[] not null,analysed_at timestamptz not null);
 create table projects(id uuid primary key,owner_id uuid,status text);
 create table kanban_boards(id uuid primary key,project_id uuid references projects(id),is_archived boolean default false);
 create table kanban_tasks(id uuid primary key,board_id uuid references kanban_boards(id),title text,description text,is_stalled boolean,status text,is_archived boolean default false);
 alter table learning_resources enable row level security;alter table resource_index enable row level security;
 grant usage on schema public,storage to service_role;grant select,insert,update on all tables in schema public,storage to service_role;
 grant select on learning_resources to authenticated;
 insert into projects values('${project}','${owner}','active');insert into kanban_boards(id,project_id) values('${board}','${project}');
 insert into kanban_tasks(id,board_id,title,description,is_stalled,status) values('${task}','${board}','Flutter row layout','Use Flutter Row widgets',true,'in_progress');`);
 for(const sql of migrations)await db.exec(sql);
 return db;
}

const upgrade=(await Promise.all(['013_resource_extractions','014_resource_image_analysis'].map(name=>readFile(new URL(`../migrations/${name}.sql`,import.meta.url),'utf8')))).join('\n');
const file='60000000-0000-0000-0000-000000000001';
const base='https://example.supabase.co',bucket='marketplace-documents';
const url=base+'/storage/v1/object/authenticated/'+bucket+'/diagram.png';
async function image(db,{status='published',hidden=false,storage=true}={}){
 await db.exec(upgrade);
 await db.query(`insert into learning_resources(id,author_id,title,body,kind,external_url,status,moderation_hidden)
 values($1,$2,'Flutter diagram','Authored content','Reading',$3,$4,$5)`,[relevant,owner,url,status,hidden]);
 if(storage)await db.query("insert into storage.objects values($1,$2,'diagram.png','v1','{\"mimetype\":\"image/png\"}',now())",[file,bucket]);
}
async function claim(db,draft=null){return (await db.query('select claim_resource_image($1,$2,$3) work',[base,bucket,draft])).rows[0].work;}
async function complete(db,work,description='Flutter widget hierarchy',keywords=['flutter']){
 return (await db.query('select complete_resource_image($1,$2,$3,$4,$5,$6) ok',
 [work.id,work.claim_token,work.resource,description,keywords,['mobile development']])).rows[0].ok;
}

test('image discovery waits for upload, deduplicates; atomic completion indexes description exactly once',async t=>{
 const db=await setup(t);await image(db,{storage:false});
 assert.equal(await claim(db),null);assert.equal((await db.query('select * from resource_analysis_jobs')).rows.length,0);
 await db.query("insert into storage.objects values($1,$2,'diagram.png','v1','{\"mimetype\":\"image/png\"}',now())",[file,bucket]);
 await db.exec('set role service_role');
 const work=await claim(db);assert.ok(work);assert.equal(work.extraction_type,'image_description');
 assert.equal(await claim(db),null); // active lease prevents a second claim
 assert.equal((await db.query('select claim_resource_extraction() work')).rows[0].work,null); // never Python
 assert.equal(await complete(db,work),true);
 assert.equal(await complete(db,work,'Must not replace saved result'),true); // lost response
 assert.equal(await claim(db),null);
 assert.equal((await db.query('select count(*)::int n from resource_extractions')).rows[0].n,1);
 assert.equal((await db.query('select status from resource_analysis_jobs')).rows[0].status,'ready');
 const index=(await db.query('select * from recommendation_index_sources')).rows[0];
 assert.match(index.description,/Flutter widget hierarchy/);
 assert.equal((await db.query('select body from learning_resources')).rows[0].body,'Authored content');
 assert.equal((await db.query('select status from resource_embeddings')).rows[0].status,'pending');
 const embedding=(await db.query('select claim_resource_embedding() job')).rows[0].job;
 assert.match(embedding.source.description,/Flutter widget hierarchy/);
 assert.equal((await db.query("select complete_resource_embedding($1,$2,$3,$4,array['flutter'],array['mobile development'],array['mobile'],array['flutter']) ok",
 [relevant,embedding.claim_token,embedding.source.source_version,vec()])).rows[0].ok,true);
 const context=(await db.query('select * from recommendation_load_owned_task($1,$2)',[task,owner])).rows[0];
 const matching=()=>db.query("select * from match_resource_embeddings($1,$2,$3,$4,$5,'gte-small','skilltrack-v1-chunk400-mean-l2',array['flutter'],array['mobile development'],array['flutter'],array['mobile'])",
 [task,owner,context.source_version,[relevant],vec()]);
 assert.equal((await matching()).rows.length,1);
 await db.query('update learning_resources set moderation_hidden=true where id=$1',[relevant]);
 assert.equal((await matching()).rows.length,0);
});

test('replacement during Gemini rejects completion; previous valid index is retained but excluded from matching',async t=>{
 const db=await setup(t);await image(db);const first=await claim(db);await complete(db,first);
 await db.query("update storage.objects set version='v2'");
 assert.equal((await db.query('select * from recommendation_index_sources')).rows.length,0);
 const second=await claim(db);assert.notEqual(first.id,second.id);
 await db.query("update storage.objects set version='v3'");
 await assert.rejects(complete(db,second),/source changed/i);
 assert.equal((await db.query('select status from resource_extractions where id=$1',[second.id])).rows[0].status,'processing');
 assert.deepEqual((await db.query('select keywords from resource_index')).rows[0].keywords,['flutter']);
 await db.query("select fail_resource_image($1,$2,'source_replaced')",[second.id,second.claim_token]);
 const third=await claim(db);assert.equal(third.source_version,'v3');
 await complete(db,third,'Updated diagram',['dart']);
 assert.deepEqual((await db.query('select keywords from resource_index')).rows[0].keywords,['dart']);
});

test('a late save failure rolls back description, index and analysis receipt; retry recovers',async t=>{
 const db=await setup(t);await image(db);const first=await claim(db);await complete(db,first);
 await db.query("update storage.objects set version='v2'");const second=await claim(db);
 await assert.rejects(complete(db,second,'New text',[null]),/Invalid resource analysis/);
 assert.equal((await db.query('select extracted_text from resource_extractions where id=$1',[second.id])).rows[0].extracted_text,null);
 assert.equal((await db.query('select count(*)::int n from resource_analysis_jobs')).rows[0].n,1);
 assert.deepEqual((await db.query('select keywords from resource_index')).rows[0].keywords,['flutter']);
 await db.query("select fail_resource_image($1,$2,'gemini_response_invalid')",[second.id,second.claim_token]);
 assert.equal(await claim(db),null); // backoff
 await db.query('update resource_extractions set next_attempt_at=now() where id=$1',[second.id]);
 const retry=await claim(db);assert.equal(retry.id,second.id);assert.notEqual(retry.claim_token,second.claim_token);
 assert.equal(await complete(db,second),false);assert.equal(await complete(db,retry),true);
});

test('hidden/archived/draft, foreign project, bucket and client permissions enforce eligibility',async t=>{
 const db=await setup(t);await image(db,{status:'draft'});
 assert.equal(await claim(db),null);const draft=await claim(db,relevant);assert.ok(draft);await complete(db,draft);
 await db.query("update storage.objects set version='v2'");
 await db.query("update learning_resources set moderation_hidden=true");assert.equal(await claim(db,relevant),null);
 await db.query("update learning_resources set moderation_hidden=false,status='archived'");assert.equal(await claim(db),null);
 await db.query("update learning_resources set status='published',external_url=replace(external_url,'example.supabase.co','other.supabase.co')");
 assert.equal(await claim(db),null);
 await db.query('update learning_resources set external_url=$1',[url]);
 assert.equal((await db.query("select claim_resource_image($1,'other-bucket') work",[base])).rows[0].work,null);
 await db.exec('set role authenticated');
 for(const sql of ["select claim_resource_image('https://example.supabase.co','marketplace-documents')",
   'select * from resource_extractions',"select complete_resource_image(null,null,null,'text',array[]::text[],array[]::text[])",
   "select fail_resource_image(null,null,'analysis_failed')"]){await assert.rejects(db.query(sql),/permission denied/);}
 await db.exec('reset role');
});

test('expired leases, stale workers and terminal attempts remain bounded',async t=>{
 const db=await setup(t);await image(db);const first=await claim(db);
 await db.query("update resource_extractions set lease_expires_at=now()-interval '1 second'");
 const second=await claim(db);assert.equal(second.id,first.id);assert.notEqual(second.claim_token,first.claim_token);
 assert.equal(await complete(db,first),false);
 await db.query("select fail_resource_image($1,$2,'gemini_rate_limited',3600)",[second.id,second.claim_token]);
 assert.equal(await claim(db),null);
 await db.query("update resource_extractions set next_attempt_at=now()");
 const third=await claim(db);assert.equal(third.attempt_count,3);
 await db.query("select fail_resource_image($1,$2,'gemini_unavailable')",[third.id,third.claim_token]);
 assert.equal(await claim(db),null);assert.equal((await db.query('select status from resource_extractions')).rows[0].status,'failed');
});

test('metadata MIME discovers extensionless images; metadata changes invalidate save',async t=>{
 const db=await setup(t);await image(db);
 await db.query("update storage.objects set name='diagram',metadata='{\"mimetype\":\"image/jpeg\"}'");
 await db.query("update learning_resources set external_url=replace(external_url,'diagram.png','diagram')");
 const work=await claim(db);assert.equal(work.mime_type,'image/jpeg');
 await db.query("update learning_resources set title='Edited during Gemini'");
 await assert.rejects(complete(db,work),{ code: '40001' });
 assert.equal((await db.query('select count(*)::int n from resource_index')).rows[0].n,0);
});
