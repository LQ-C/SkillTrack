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

const upgrade=await readFile(new URL('../migrations/013_resource_extractions.sql',import.meta.url),'utf8');
const file='60000000-0000-0000-0000-000000000001';
const url='https://example.supabase.co/storage/v1/object/authenticated/videos/a.mp4';
async function video(db){
 await db.query(`insert into learning_resources(id,author_id,title,body,kind,external_url,status,moderation_hidden)
 values($1,$2,'Video','Authored body','Video',$3,'published',false)`,[relevant,owner,url]);
 await db.query("insert into storage.objects values($1,'videos','a.mp4','v1','{}',now())",[file]);
 await db.query("select enqueue_discovered_video($1,$2,'videos','a.mp4')",[relevant,url]);
 return (await db.query('select claim_video_transcript() work')).rows[0].work;
}
async function finishAnalysis(db,id){
 const job=(await db.query('select claim_resource_analysis_job($1) job',[id])).rows[0].job;
 assert.ok(job);
 const r=(await db.query('select to_jsonb(r) data from learning_resources r where id=$1',[id])).rows[0].data;
 const e=(await db.query('select to_jsonb(e) data from resource_extractions e where id=$1',[job.transcript_id])).rows[0]?.data ?? null;
 await db.query("select complete_resource_analysis_job($1,$2,$3,$4,array['flutter'],array['mobile'])",[job.id,job.claim_token,r,e]);
 return job;
}
test('upgrade preserves ready data, legacy IDs, in-flight claims and old callers',async t=>{
 const db=await setup(t);const work=await video(db);
 await db.query("select complete_video_transcript($1,$2,'Existing text','en','[]')",[work.id,work.claim_token]);
 const before=(await db.query('select * from video_transcripts')).rows[0];
 const hash=(await db.query('select content_version from resource_analysis_jobs')).rows[0].content_version;
 await db.exec(upgrade);
 const after=(await db.query('select * from resource_extractions where id=$1',[work.id])).rows[0];
 assert.equal(after.extracted_text,before.transcript_text);assert.equal(after.resource_id,before.resource_id);
 assert.equal(after.extraction_type,'video_transcript');assert.equal(after.claim_token,before.claim_token);
 assert.equal((await db.query('select content_version from resource_analysis_candidates(null,false)')).rows[0].content_version,hash);
 await finishAnalysis(db,relevant);
 assert.equal((await db.query('select count(*)::int n from resource_embeddings')).rows[0].n,1);
 assert.equal((await db.query('select transcript_text from read_ready_video_transcript($1,$2,$3,$4)',[relevant,url,'videos','a.mp4'])).rows[0].transcript_text,'Existing text');
 await db.query("update storage.objects set version='v2'");
 assert.equal((await db.query('select * from recommendation_index_sources')).rows.length,0);
 await db.query("select enqueue_discovered_video($1,$2,'videos','a.mp4')",[relevant,url]);
 const next=(await db.query('select claim_video_transcript() work')).rows[0].work;
 assert.ok(next);assert.equal(next.extraction_type,'video_transcript');
 assert.equal((await db.query("select complete_video_transcript($1,$2,'New video','en','[]') ok",[next.id,next.claim_token])).rows[0].ok,true);
});
test('fresh chain: private PDF ready -> analysis -> embedding, replacement and body compatibility',async t=>{
 const db=await setup(t);await db.exec(upgrade);
 const pdfUrl='https://example.supabase.co/storage/v1/object/authenticated/marketplace-documents/lesson.pdf';
 await db.query(`insert into learning_resources(id,author_id,title,body,kind,external_url,status,moderation_hidden)
 values($1,$2,'PDF','Keep authored body','Reading',$3,'published',false)`,[relevant,owner,pdfUrl]);
 assert.equal((await db.query('select * from resource_analysis_jobs')).rows.length,0);
 assert.equal((await db.query("select enqueue_discovered_extraction($1,$2,'marketplace-documents','lesson.pdf') id",[relevant,pdfUrl])).rows[0].id,null);
 await db.query("insert into storage.objects values($1,'marketplace-documents','lesson.pdf','p1','{}',now())",[file]);
 const enqueue=()=>db.query("select enqueue_discovered_extraction($1,$2,'marketplace-documents','lesson.pdf') id",[relevant,pdfUrl]);
 const id=(await enqueue()).rows[0].id;assert.equal((await enqueue()).rows[0].id,id);
 await db.exec('set role service_role');
 assert.equal((await db.query('select claim_video_transcript() work')).rows[0].work,null);
 const work=(await db.query('select claim_resource_extraction() work')).rows[0].work;
 assert.equal(work.extraction_type,'pdf_text');
 assert.equal((await db.query('select claim_resource_extraction() work')).rows[0].work,null);
 await db.query("select complete_resource_extraction($1,$2,'Extracted PDF text',null,'[]')",[id,work.claim_token]);
 await db.query("select complete_resource_extraction($1,$2,'Ignored duplicate',null,'[]')",[id,work.claim_token]);
 await finishAnalysis(db,relevant);
 const source=(await db.query('select * from recommendation_index_sources')).rows[0];
 assert.equal(source.pdf_text,'Extracted PDF text');assert.equal(source.transcript,'');
 const embedding=(await db.query('select claim_resource_embedding() job')).rows[0].job;
 assert.ok(embedding);
 const vector=JSON.stringify([1,...Array(383).fill(0)]); // fixture, not model inference
 assert.equal((await db.query("select complete_resource_embedding($1,$2,$3,$4,array['flutter'],array['mobile'],array['mobile'],array['flutter']) ok",
 [relevant,embedding.claim_token,embedding.source.source_version,vector])).rows[0].ok,true);
 assert.equal((await db.query('select body from learning_resources')).rows[0].body,'Keep authored body');
 assert.equal((await db.query('select count(*)::int n from resource_analysis_jobs')).rows[0].n,1);
 await db.query("update storage.objects set version='p2'");
 assert.equal((await db.query('select * from recommendation_index_sources')).rows.length,0);
 await enqueue();const stale=(await db.query('select claim_resource_extraction() work')).rows[0].work;
 await db.query("update storage.objects set version='p3'");
 assert.equal((await db.query("select complete_resource_extraction($1,$2,'Old PDF',null,'[]') ok",[stale.id,stale.claim_token])).rows[0].ok,false);
 await db.exec('reset role');
 await db.query(`insert into learning_resources(id,author_id,title,body,kind,external_url,status,moderation_hidden)
 values($1,$2,'External reading','Saved authored text','Reading','https://example.org/article','published',false)`,[unrelated,owner]);
 await finishAnalysis(db,unrelated);
 assert.equal((await db.query('select pdf_text from recommendation_index_sources where resource_id=$1',[unrelated])).rows[0].pdf_text,'Saved authored text');
 await db.exec('set role authenticated');
 await assert.rejects(db.query('select * from resource_extractions'),/permission denied/);
 await assert.rejects(db.query('select claim_resource_extraction()'),/permission denied/);
 await db.exec('reset role');
});

test('upgrade retains opaque text IDs and active leases; retry and visibility guards survive',async t=>{
 const db=await setup(t);const work=await video(db);
 await db.query(`insert into video_transcripts(resource_id,source_file_id,source_version,storage_bucket,storage_path,status,transcript_text)
 values('legacy-non-uuid','legacy-file','legacy-version','videos','legacy.mp4','ready','Preserve legacy text')`);
 await db.exec(upgrade);
 assert.equal((await db.query("select extracted_text from resource_extractions where resource_id='legacy-non-uuid'")).rows[0].extracted_text,'Preserve legacy text');
 assert.equal((await db.query('select claim_token from resource_extractions where id=$1',[work.id])).rows[0].claim_token,work.claim_token);
 await db.query("update learning_resources set moderation_hidden=true");
 assert.equal((await db.query("select complete_resource_extraction($1,$2,'hidden',null,'[]') ok",[work.id,work.claim_token])).rows[0].ok,false);
 assert.equal((await db.query('select * from resource_extraction_candidates()')).rows.length,0);
 await db.query("update learning_resources set moderation_hidden=false,status='draft'");
 assert.equal((await db.query('select * from resource_extraction_candidates()')).rows.length,0);
 assert.equal((await db.query('select * from resource_extraction_candidates(25,null,$1)',[relevant])).rows.length,1);
 await db.query("update resource_extractions set lease_expires_at=now()-interval '1 second' where id=$1",[work.id]);
 const second=(await db.query('select claim_resource_extraction() work')).rows[0].work;
 assert.notEqual(second.claim_token,work.claim_token);
 assert.equal((await db.query("select complete_resource_extraction($1,$2,'stale',null,'[]') ok",[work.id,work.claim_token])).rows[0].ok,false);
 assert.equal((await db.query("select fail_resource_extraction($1,$2,'pdf_empty') ok",[second.id,second.claim_token])).rows[0].ok,true);
 await db.query('update resource_extractions set next_attempt_at=now() where id=$1',[work.id]);
 const third=(await db.query('select claim_resource_extraction() work')).rows[0].work;
 await db.query("select fail_resource_extraction($1,$2,'download_failed')",[third.id,third.claim_token]);
 assert.equal((await db.query('select status from resource_extractions where id=$1',[work.id])).rows[0].status,'failed');
 assert.equal((await db.query('select claim_resource_extraction() work')).rows[0].work,null);
});
