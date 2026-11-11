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
async function source(db,id=relevant,title='Flutter row layout',keywords=['flutter','row']){
 await db.query(`insert into learning_resources(id,author_id,title,summary,category,body,tags,kind,external_url,status,moderation_hidden)
 values($1,$2,$3,'Learn layouts','Mobile development','Flutter Row widgets',array['flutter'],'Article','','published',false)`,[id,owner,title]);
 await analyse(db,id,keywords);
}
async function analyse(db,id=relevant,keywords=['flutter','row']){
 const job=(await db.query('select claim_resource_analysis_job($1) job',[id])).rows[0].job;
 assert.ok(job);
 const resource=(await db.query('select to_jsonb(r) data from learning_resources r where id=$1',[id])).rows[0].data;
 await db.query("select complete_resource_analysis_job($1,$2,$3,null,$4,array['mobile development'])",[job.id,job.claim_token,resource,keywords]);
}
async function claim(db){return (await db.query('select claim_resource_embedding() job')).rows[0].job;}
async function save(db,job,cosine=1){
 return (await db.query("select complete_resource_embedding($1,$2,$3,$4,$5,$6,array['mobile'],array['flutter']) ok",[job.resource_id,job.claim_token,job.source.source_version,vec(cosine),job.source.keywords,job.source.topic_tags])).rows[0].ok;
}
async function match(db,ids=[relevant,unrelated],user=owner){
 const context=(await db.query('select * from recommendation_load_owned_task($1,$2)',[task,owner])).rows[0];
 return (await db.query("select * from match_resource_embeddings($1,$2,$3,$4,$5,'gte-small','skilltrack-v1-chunk400-mean-l2',array['flutter','row'],array['mobile development'],array['flutter'],array['mobile'])",[task,user,context?.source_version ?? '',ids,vec()])).rows;
}

test('real analysis completion queues embeddings; duplicate discovery and lost-response completion do not duplicate vectors',async t=>{
 const db=await setup(t);await source(db);
 assert.equal((await db.query('select count(*)::int n from resource_embeddings')).rows[0].n,1);
 assert.equal((await db.query('select backfill_resource_embeddings() n')).rows[0].n,0);
 const job=await claim(db);assert.ok(await save(db,job));assert.equal(await save(db,job),false);
 assert.equal(await claim(db),null);assert.equal((await db.query('select backfill_resource_embeddings() n')).rows[0].n,0);
 assert.equal((await db.query('select attempt_count from resource_embeddings')).rows[0].attempt_count,1);
});
test('one relevant and one unrelated vector: hiding relevant removes it; user visibility applies before limit',async t=>{
 const db=await setup(t);await source(db);await source(db,unrelated,'Unrelated lesson',['cooking']);
 let job=await claim(db);await save(db,job,job.resource_id===relevant?1:0);
 job=await claim(db);await save(db,job,job.resource_id===relevant?1:0);
 assert.deepEqual((await match(db)).map(r=>r.resource_id),[relevant]);
 assert.deepEqual(await match(db,[unrelated]),[]);
 await db.exec(`update learning_resources set moderation_hidden=true where id='${relevant}'`);
 assert.deepEqual(await match(db),[]);
});
test('current RLS denies resources until a real read policy exists; clients cannot read vectors or call backend RPCs',async t=>{
 const db=await setup(t);await source(db);await save(db,await claim(db));
 await db.exec('set role authenticated');assert.equal((await db.query('select id from learning_resources')).rows.length,0);
 await assert.rejects(db.query('select * from resource_embeddings'),/permission denied/);
 await assert.rejects(db.query('select claim_resource_embedding()'),/permission denied/);
 await db.exec(`reset role;create policy fixture_reader on learning_resources for select to authenticated using(status='published' and not moderation_hidden);set role authenticated`);
 const ids=(await db.query('select id from learning_resources')).rows.map(x=>x.id);
 await db.exec('reset role');assert.equal((await match(db,ids)).length,1);
});
test('task ownership, stalled state and archived project/board/task are rechecked by SQL',async t=>{
 const db=await setup(t);await source(db);await save(db,await claim(db));
 assert.deepEqual((await db.query('select * from recommendation_load_owned_task($1,$2)',[task,stranger])).rows,[]);
 assert.deepEqual(await match(db,[relevant],stranger),[]);
 for(const [table,change,reset] of [['kanban_tasks','is_stalled=false','is_stalled=true'],['kanban_tasks',"status='completed'","status='in_progress'"],['kanban_tasks','is_archived=true','is_archived=false'],['kanban_boards','is_archived=true','is_archived=false'],['projects',"status='archived'","status='active'"]]){
  await db.exec(`update ${table} set ${change}`);assert.deepEqual(await match(db),[]);await db.exec(`update ${table} set ${reset}`);
 }
});
test('metadata changes immediately exclude stale vectors until new analysis/indexing completes',async t=>{
 const db=await setup(t);await source(db);await save(db,await claim(db));
 await db.exec(`update learning_resources set body='Flutter Row and Column new lesson' where id='${relevant}'`);
 assert.deepEqual(await match(db),[]);
 assert.equal((await db.query('select backfill_resource_embeddings() n')).rows[0].n,0);
 await analyse(db);const changed=await claim(db);assert.ok(changed);await save(db,changed);
 assert.equal((await match(db)).length,1);
});
test('draft and archived resources never match, even with a previously ready vector',async t=>{
 const db=await setup(t);await source(db);await save(db,await claim(db));
 for(const state of ['draft','archived']){await db.query('update learning_resources set status=$1',[state]);assert.deepEqual(await match(db),[]);}
});
test('leases, duplicate claims, stale completion and three-attempt retries remain safe',async t=>{
 const db=await setup(t);await source(db);
 const old=await claim(db);assert.equal(await claim(db),null);
 await db.exec("update resource_embeddings set lease_expires_at=now()-interval '1 second'");
 const newer=await claim(db);assert.notEqual(old.claim_token,newer.claim_token);assert.equal(await save(db,old),false);
 await db.query("select fail_resource_embedding($1,$2,'embedding_unavailable')",[newer.resource_id,newer.claim_token]);
 assert.equal(await claim(db),null);
 await db.exec("update resource_embeddings set next_attempt_at=now()-interval '1 second'");const final=await claim(db);
 await db.query("select fail_resource_embedding($1,$2,'embedding_unavailable')",[final.resource_id,final.claim_token]);
 assert.equal((await db.query('select status from resource_embeddings')).rows[0].status,'failed');
 assert.equal((await db.query('select backfill_resource_embeddings() n')).rows[0].n,0);
 assert.equal(await claim(db),null);
});
test('source change during embedding rejects old claim and preserves current analysis',async t=>{
 const db=await setup(t);await source(db);const old=await claim(db);
 await db.exec("update learning_resources set body='Changed lesson'");await analyse(db);
 assert.equal(await save(db,old),false);await save(db,await claim(db));
 assert.equal((await db.query('select count(*)::int n from resource_index')).rows[0].n,1);
});
test('index save failure rolls back vector and ready state together',async t=>{
 const db=await setup(t);await source(db);const job=await claim(db);
 await db.exec("alter table resource_embeddings add constraint no_ready check(status<>'ready')");
 await assert.rejects(save(db,job),/no_ready/);
 assert.deepEqual((await db.query('select status,embedding from resource_embeddings')).rows,[{status:'processing',embedding:null}]);
});
test('existing analysed resources backfill without retranscription or reanalysis',async t=>{
 const db=await setup(t);await db.exec('drop trigger resource_analysis_ready_embedding on resource_analysis_jobs');await source(db);
 assert.equal(await claim(db),null);assert.equal((await db.query('select backfill_resource_embeddings() n')).rows[0].n,1);
 await save(db,await claim(db));assert.equal((await match(db)).length,1);
});


test('video replacement excludes old embedding until current transcript and analysis are ready',async t=>{
 const db=await setup(t);
 const object='60000000-0000-0000-0000-000000000001';
 await db.query(`insert into learning_resources(id,author_id,title,summary,category,body,tags,kind,external_url,status,moderation_hidden)
 values($1,$2,'Flutter Row','Layouts','Mobile','','{}','Video','https://example.supabase.co/storage/v1/object/public/videos/a.mp4','published',false)`,[relevant,owner]);
 await db.query("insert into storage.objects(id,bucket_id,name,version,metadata) values($1,'videos','a.mp4','v1','{}')",[object]);
 async function transcribeAndAnalyse(version){
  await db.query('update storage.objects set version=$1',[version]);
  await db.query("select enqueue_video_transcription($1,$2,$3,'videos','a.mp4')",[relevant,object,version]);
  const work=(await db.query('select claim_video_transcript() job')).rows[0].job;
  await db.query("select complete_video_transcript($1,$2,'Flutter Row layouts','en','[]')",[work.id,work.claim_token]);
  const job=(await db.query('select claim_resource_analysis_job($1) job',[relevant])).rows[0].job;
  const resource=(await db.query('select to_jsonb(r) data from learning_resources r')).rows[0].data;
  const transcript=(await db.query('select to_jsonb(t) data from video_transcripts t where id=$1',[work.id])).rows[0].data;
  await db.query("select complete_resource_analysis_job($1,$2,$3,$4,array['flutter','row'],array['mobile development'])",[job.id,job.claim_token,resource,transcript]);
 }
 await transcribeAndAnalyse('v1');await save(db,await claim(db));assert.equal((await match(db)).length,1);
 await db.exec("update storage.objects set version='v2'");assert.deepEqual(await match(db),[]);
 await transcribeAndAnalyse('v2');await save(db,await claim(db));assert.equal((await match(db)).length,1);
 assert.equal((await db.query('select count(*)::int n from resource_embeddings')).rows[0].n,1);
});
test('top-three limit and cosine/hybrid scores follow prototype weights',async t=>{
 const db=await setup(t);const ids=[];
 for(let i=1;i<=4;i++){
  const id=`50000000-0000-0000-0000-${String(i).padStart(12,'0')}`;ids.push(id);
  await source(db,id);await save(db,await claim(db),1-(i-1)*.05);
 }
 const rows=await match(db,ids);assert.equal(rows.length,3);assert.deepEqual(rows.map(r=>r.resource_id),ids.slice(0,3));
 assert.ok(Math.abs(rows[0].score-1)<1e-6);assert.ok(Math.abs(rows[1].score-(.75*.95+.25))<1e-5);
});


test('manual mode accepts active non-stalled tasks without changing task state; legacy stays stalled-only',async t=>{
 const db=await setup(t);await source(db);await save(db,await claim(db));
 await db.exec('update kanban_tasks set is_stalled=false');
 const before=(await db.query('select * from kanban_tasks')).rows;
 const context=(await db.query("select * from recommendation_load_owned_task($1,$2,'manual')",[task,owner])).rows[0];
 assert.equal(context.title,'Flutter row layout');assert.equal(context.is_stalled,false);
 const args=[task,owner,context.source_version,[relevant],vec()];
 const sql="select * from match_resource_embeddings($1,$2,'manual',$3,$4,$5,'gte-small','skilltrack-v1-chunk400-mean-l2',array['flutter','row'],array['mobile development'],array['flutter'],array['mobile'])";
 assert.equal((await db.query(sql,args)).rows.length,1);
 assert.deepEqual(await match(db),[]);
 assert.deepEqual((await db.query('select * from kanban_tasks')).rows,before);
 args[1]=stranger;assert.deepEqual((await db.query(sql,args)).rows,[]);args[1]=owner;
 args[2]='stale';assert.deepEqual((await db.query(sql,args)).rows,[]);args[2]=context.source_version;
 args[3]=[];assert.deepEqual((await db.query(sql,args)).rows,[]);args[3]=[relevant];
 for(const [table,change,reset] of [['kanban_tasks',"status='completed'","status='in_progress'"],['kanban_tasks','is_archived=true','is_archived=false'],['kanban_boards','is_archived=true','is_archived=false'],['projects',"status='archived'","status='active'"]]){
  await db.exec(`update ${table} set ${change}`);
  assert.deepEqual((await db.query("select * from recommendation_load_owned_task($1,$2,'manual')",[task,owner])).rows,[]);
  assert.deepEqual((await db.query(sql,args)).rows,[]);
  await db.exec(`update ${table} set ${reset}`);
 }
 await db.exec('update learning_resources set moderation_hidden=true');
 assert.deepEqual((await db.query(sql,args)).rows,[]);
});
test('manual RPC overloads reject invalid mode and remain backend only',async t=>{
 const db=await setup(t);
 await assert.rejects(db.query("select * from recommendation_load_owned_task($1,$2,'unknown')",[task,owner]),/Invalid recommendation mode/);
 assert.deepEqual((await db.query("select * from recommendation_load_owned_task($1,$2,'manual')",[task,stranger])).rows,[]);
 await db.exec('set role authenticated');
 await assert.rejects(db.query("select * from recommendation_load_owned_task($1,$2,'manual')",[task,owner]),/permission denied/);
 await db.exec('reset role');
 const permissions=(await db.query("select has_function_privilege('authenticated',p.oid,'EXECUTE') allowed from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname in ('recommendation_load_owned_task','match_resource_embeddings')")).rows;
 assert.equal(permissions.length,4);assert.ok(permissions.every(p=>!p.allowed));
});


async function notificationSetup(t) {
 const db=await setup(t);
 await db.exec(`create schema auth;
 create table auth.users(id uuid primary key,email text,raw_app_meta_data jsonb,raw_user_meta_data jsonb);
 create table profiles(id uuid primary key);
 create function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
 grant usage on schema auth,public to authenticated,service_role;
 insert into auth.users values('${owner}','owner@example.test','{}','{}'),('${stranger}','other@example.test','{}','{}');
 insert into profiles values('${owner}'),('${stranger}');
 alter table kanban_tasks add column stalled_at timestamptz default now(), add column stagnation_score integer default 70;`);
 await db.exec(await readFile(new URL('../migrations/in_app_notifications.sql',import.meta.url),'utf8'));
 const generator=await readFile(new URL('../migrations/project_notification_generator.sql',import.meta.url),'utf8');
 await db.exec(generator.slice(generator.indexOf('create or replace function public.enqueue_app_notification('),generator.indexOf('revoke all on function public.notification_project_candidates')));
 await db.exec(await readFile(new URL('../migrations/011_stalled_resource_notifications.sql',import.meta.url),'utf8'));
 await source(db);await save(db,await claim(db));
 const episode=(await db.query('select stalled_at from kanban_tasks')).rows[0].stalled_at;
 const ctx=(await db.query('select * from recommendation_load_owned_task($1,$2)',[task,owner])).rows[0];
 const version=(await db.query('select source_version from resource_embeddings')).rows[0].source_version;
 const commit=(resource=relevant,user=owner,period=episode)=>db.query('select enqueue_stalled_period_alert($1,$2,$3,$4,$5,$6) ok',[task,user,period,resource,version,ctx.source_version]);
 return {db,episode,commit,version,ctx};
}
async function readerPolicy(db){await db.exec(`create policy fixture_owner_read on learning_resources for select to authenticated using(author_id=auth.uid());`);}
test('scheduled visibility executes actual recipient RLS, restores claims and cannot be spoofed by clients',async t=>{
 const {db}=await notificationSetup(t);
 assert.deepEqual((await db.query('select * from recommendation_resources_for_recipient($1)',[owner])).rows,[]);
 await readerPolicy(db);
 assert.equal((await db.query('select * from recommendation_resources_for_recipient($1)',[owner])).rows.length,1);
 assert.deepEqual((await db.query('select * from recommendation_resources_for_recipient($1)',[stranger])).rows,[]);
 await db.query("select set_config('request.jwt.claim.sub',$1,false)",[stranger]);
 await db.query('select * from recommendation_resources_for_recipient($1)',[owner]);
 assert.equal((await db.query("select current_setting('request.jwt.claim.sub') id")).rows[0].id,stranger);
 await db.exec('set role authenticated');
 await assert.rejects(db.query('select * from recommendation_resources_for_recipient($1)',[owner]),/permission denied/);
 assert.deepEqual((await db.query('select * from recommendation_rls_resources()')).rows,[]);
 await assert.rejects(db.query('select enqueue_stalled_period_alert($1,$2,now())',[task,owner]),/permission denied/);
});
test('recommendation enqueue is atomic, retry-safe, per recipient/episode, and suppresses the generic fallback',async t=>{
 const {db,episode,commit}=await notificationSetup(t);await readerPolicy(db);
 const [one,two]=await Promise.all([commit(),commit()]);
 assert.equal([one,two].filter(x=>x.rows[0].ok).length,1);
 assert.equal((await commit(null)).rows[0].ok,false);
 const rows=(await db.query('select * from notifications')).rows;
 assert.equal(rows.length,1);assert.equal(rows[0].type,'LEARNING_RESOURCE_RECOMMENDATION');
 assert.equal(rows[0].context_type,'RECOMMENDATION');assert.equal(rows[0].user_id,owner);
 assert.equal(rows[0].action_data.section,'learning_resources');assert.equal(rows[0].action_data.resource_id,relevant);
 assert.ok(rows[0].message.includes('Flutter row layout'));assert.ok(!JSON.stringify(rows[0].action_data).includes('storage'));
 assert.equal((await commit(relevant,stranger)).rows[0].ok,false);
 await db.exec('update kanban_tasks set is_stalled=false,stalled_at=null');
 assert.equal((await commit()).rows[0].ok,false);
 await db.exec('update kanban_tasks set is_stalled=true,stalled_at=clock_timestamp()');
 const later=(await db.query('select stalled_at from kanban_tasks')).rows[0].stalled_at;
 assert.notEqual(later,episode);assert.equal((await commit(relevant,owner,later)).rows[0].ok,true);
 assert.equal((await db.query('select count(*)::int n from notifications')).rows[0].n,2);
});
test('preferences are independent; hidden/stale resources fall back and ineligible tasks never enqueue',async t=>{
 const {db,commit,episode}=await notificationSetup(t);await readerPolicy(db);
 await db.query('insert into notification_preferences(user_id,stalled_task_enabled,recommendation_enabled) values($1,false,true)',[owner]);
 assert.equal((await commit()).rows[0].ok,true);
 await db.exec('delete from notifications;update notification_preferences set stalled_task_enabled=true,recommendation_enabled=false');
 assert.equal((await commit()).rows[0].ok,true);
 assert.equal((await db.query('select type from notifications')).rows[0].type,'STALLED_TASK');
 await db.exec('delete from notifications;update notification_preferences set recommendation_enabled=true;update learning_resources set moderation_hidden=true');
 assert.equal((await commit()).rows[0].ok,true);
 assert.equal((await db.query('select type from notifications')).rows[0].type,'STALLED_TASK');
 await db.exec("delete from notifications;update learning_resources set moderation_hidden=false;update resource_embeddings set status='pending'");
 assert.equal((await commit()).rows[0].ok,true);
 assert.equal((await db.query('select type from notifications')).rows[0].type,'STALLED_TASK');
 await db.exec('delete from notifications;update notification_preferences set stalled_task_enabled=false,recommendation_enabled=false');
 assert.equal((await commit()).rows[0].ok,false);
 await db.exec('update notification_preferences set stalled_task_enabled=true,recommendation_enabled=true');
 for(const [table,change,reset] of [['kanban_tasks',"status='completed'","status='in_progress'"],['kanban_tasks','is_archived=true','is_archived=false'],['kanban_boards','is_archived=true','is_archived=false'],['projects',"status='archived'","status='active'"]]){
  await db.exec(`update ${table} set ${change}`);assert.equal((await commit()).rows[0].ok,false);await db.exec(`update ${table} set ${reset}`);
 }
 await db.exec('delete from kanban_tasks');assert.equal((await commit()).rows[0].ok,false);
});


test('failed notification insert rolls back and the same episode retries once; changed task text uses fallback',async t=>{
 const {db,commit}=await notificationSetup(t);await readerPolicy(db);
 await db.exec("alter table notifications add constraint force_late_failure check(type<>'LEARNING_RESOURCE_RECOMMENDATION')");
 await assert.rejects(commit(),/force_late_failure/);
 assert.equal((await db.query('select count(*)::int n from notifications')).rows[0].n,0);
 await db.exec('alter table notifications drop constraint force_late_failure');
 assert.equal((await commit()).rows[0].ok,true);assert.equal((await commit()).rows[0].ok,false);
 await db.exec("delete from notifications;update kanban_tasks set title='Changed after matching'");
 assert.equal((await commit()).rows[0].ok,true);
 const row=(await db.query('select type,message from notifications')).rows[0];
 assert.equal(row.type,'STALLED_TASK');assert.ok(row.message.includes('Changed after matching'));
});
