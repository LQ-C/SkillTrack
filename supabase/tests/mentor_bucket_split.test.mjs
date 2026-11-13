import assert from 'node:assert/strict';
import test from 'node:test';
import {readFile} from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';
const id=n=>`00000000-0000-4000-8000-${String(n).padStart(12,'0')}`;
const owner=id(1),paid=id(2),unpaid=id(3),other=id(4);
const file=(n,ext)=>`${owner}/${String(n).padStart(32,'0')}.${ext}`;
const url=(bucket,path)=>`https://fixture.supabase.co/storage/v1/object/authenticated/${bucket}/${path}`;

test('split buckets preserve existing files and exact private entitlements',async t=>{
 const db=new PGlite();
 try {
 await db.exec(`create role authenticated;create role anon;create role service_role bypassrls;
 create schema auth;create schema storage;
 create function auth.uid() returns uuid language sql as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;
 create table auth.users(id uuid primary key,email_confirmed_at timestamptz);
 create table public.profiles(id uuid primary key,role text);
 create table public.content_publishers(user_id uuid);
 create table public.mentor_payments(mentor_id uuid,learner_id uuid,status text,purchase_kind text);
 create table storage.buckets(id text primary key,name text,public boolean,file_size_limit bigint,allowed_mime_types text[]);
 create table storage.objects(id uuid primary key default gen_random_uuid(),bucket_id text references storage.buckets(id),name text,unique(bucket_id,name));
 create table learning_resources(id uuid primary key,author_id uuid,kind text,body text default '',external_url text default '',attachment_path text,status text default 'published',moderation_hidden boolean default false,constraint resource_link check(true));
 create function public.resource_analysis_storage_key(text) returns text language sql immutable as $$select substring($1 from '^https://[^/]+/storage/v1/object/(?:public|authenticated)/([^?#]+)$')$$;
 create function public.valid_resource_link(text) returns boolean language sql immutable as $$select $1 ~ '^https://'$$;
 grant usage on schema auth,storage to authenticated,anon,service_role;
 grant select,insert,update,delete on storage.objects to authenticated,anon,service_role;
 grant select on learning_resources to authenticated,anon,service_role;
 alter table storage.objects enable row level security;
 alter table learning_resources enable row level security;
 insert into storage.buckets values('mentor-reading-files','mentor-reading-files',false,52428800,array['application/pdf','image/png','image/jpeg']),('mentor-video-files','mentor-video-files',false,52428800,array['video/mp4']);`);
 // Exercise the real canonical payment/profile functions, not a permissive stub.
 const schema=await readFile(new URL('../marketplace_history/combined_schema_marketplace_profiles_v2.sql',import.meta.url),'utf8');
 for(const name of ['is_verified_account','can_author_content','is_student_account','is_content_publisher','has_mentor_library_access','can_read_mentor_resource']) {
   const match=schema.match(new RegExp(`CREATE OR REPLACE FUNCTION "public"\\."${name}"[\\s\\S]*?\\$\\$;`));
   assert.ok(match,name);await db.exec(match[0]);
 }
 await db.exec(`create policy resources on learning_resources for select to authenticated using(can_read_mentor_resource(author_id,status,moderation_hidden));
 -- Deliberately broad unrelated policies verify the new restrictive boundaries.
 create policy broad_read on storage.objects for select to authenticated,anon using(bucket_id in ('mentor-reading-files','mentor-video-files'));
 create policy broad_insert on storage.objects for insert to authenticated,anon with check(bucket_id in ('mentor-reading-files','mentor-video-files'));
 create policy broad_update on storage.objects for update to authenticated using(true) with check(true);
 insert into auth.users values('${owner}',now()),('${paid}',now()),('${unpaid}',now()),('${other}',now());
 insert into profiles values('${owner}','mentor'),('${paid}','student'),('${unpaid}','student'),('${other}','mentor');
 insert into content_publishers values('${owner}');
 insert into mentor_payments values('${owner}','${paid}','paid','materials');`);
 for(const [n,kind,bucket,ext,empty] of [[11,'Video','mentor-video-files','mp4',false],[12,'Video','mentor-reading-files','mp4',true],[13,'Reading','mentor-reading-files','pdf',false]]) {
   await db.query('insert into learning_resources(id,author_id,kind,external_url,attachment_path) values($1,$2,$3,$4,$5)',[id(n),owner,kind,empty?'':url(bucket,file(n,ext)),file(n,ext)]);
   await db.query('insert into storage.objects(bucket_id,name) values($1,$2)',[bucket,file(n,ext)]);
 }
 await db.query('insert into storage.objects(bucket_id,name) values($1,$2)',['mentor-reading-files',file(11,'mp4')]);
 const before=(await db.query('select id,bucket_id,name from storage.objects order by id')).rows;
 await db.exec(await readFile(new URL('../migrations/018_split_mentor_resource_buckets.sql',import.meta.url),'utf8'));
 // Match the deployed backend-only parser ACL (the old fixture defaulted PUBLIC).
 await db.exec('revoke execute on function public.resource_analysis_storage_key(text) from public,anon,authenticated');
 await db.exec(await readFile(new URL('../migrations/019_resource_storage_policy_helper_permission.sql',import.meta.url),'utf8'));
 const run=async(user,sql,args=[],role='authenticated')=>{
   await db.exec(`set role ${role}; select set_config('request.jwt.claim.sub','${user??''}',false)`);
   try{return await db.query(sql,args);}finally{await db.exec('reset role');}
 };
 await t.test('policy URL helper is callable by authenticated users without granting anonymous access',async()=>{
   assert.equal((await db.query("select has_function_privilege('authenticated','public.resource_analysis_storage_key(text)','EXECUTE') allowed")).rows[0].allowed,true);
   assert.equal((await db.query("select has_function_privilege('anon','public.resource_analysis_storage_key(text)','EXECUTE') allowed")).rows[0].allowed,false);
   assert.equal((await run(paid,'select public.resource_analysis_storage_key($1) value',[url('mentor-video-files',file(11,'mp4'))])).rows[0].value,'mentor-video-files/'+file(11,'mp4'));
 });
 await t.test('existing buckets and object identities retained; both privacy flags and MIME limits enforced',async()=>{
   assert.deepEqual((await db.query('select id,bucket_id,name from storage.objects order by id')).rows,before);
   const buckets=(await db.query('select * from storage.buckets order by id')).rows;
   assert.equal(buckets.length,2);assert.ok(buckets.every(b=>b.public===false));
   assert.deepEqual(buckets[0].allowed_mime_types,['application/pdf','image/png','image/jpeg']);
   assert.deepEqual(buckets[1].allowed_mime_types,['video/mp4']);
   assert.equal(Number(buckets[1].file_size_limit),50*1024*1024);
 });
 await t.test('owner and paid learner read new video, old video and PDF; same path in wrong bucket denied',async()=>{
   for(const user of [owner,paid]) assert.equal((await run(user,'select * from storage.objects')).rows.length,3);
   assert.equal((await run(paid,"select * from storage.objects where bucket_id='mentor-reading-files' and name=$1",[file(11,'mp4')])).rows.length,0);
 });
 await t.test('unpaid, other mentor, anonymous, unverified, refunded and session-only payments cannot read',async()=>{
   for(const user of [unpaid,other]) assert.equal((await run(user,'select * from storage.objects')).rows.length,0);
   assert.equal((await run(null,'select * from storage.objects',[],'anon')).rows.length,0);
   await db.query('update auth.users set email_confirmed_at=null where id=$1',[paid]);
   assert.equal((await run(paid,'select * from storage.objects')).rows.length,0);
   await db.query('update auth.users set email_confirmed_at=now() where id=$1',[paid]);
   await db.exec("update mentor_payments set status='refunded'");
   assert.equal((await run(paid,'select * from storage.objects')).rows.length,0);
   await db.exec("update mentor_payments set status='paid',purchase_kind='session'");
   assert.equal((await run(paid,'select * from storage.objects')).rows.length,0);
   await db.exec("update mentor_payments set purchase_kind='materials'");
 });
 await t.test('moderated/draft resources remain denied to learners but available to author',async()=>{
   await db.exec("update learning_resources set moderation_hidden=true");
   assert.equal((await run(paid,'select * from storage.objects')).rows.length,0);
   assert.equal((await run(owner,'select * from storage.objects')).rows.length,3);
   await db.exec("update learning_resources set moderation_hidden=false,status='draft'");
   assert.equal((await run(paid,'select * from storage.objects')).rows.length,0);
   await db.exec("update learning_resources set status='published'");
 });
 await t.test('new MP4 only goes to video bucket, PDF/images only to reading, with author-owned paths',async()=>{
   for(const [n,ext,bucket] of [[21,'mp4','mentor-video-files'],[22,'pdf','mentor-reading-files'],[23,'png','mentor-reading-files'],[24,'jpg','mentor-reading-files'],[25,'jpeg','mentor-reading-files']]) {
     await run(owner,'insert into storage.objects(bucket_id,name) values($1,$2)',[bucket,file(n,ext)]);
   }
   for(const [bucket,path] of [['mentor-reading-files',file(31,'mp4')],['mentor-video-files',file(32,'pdf')],['mentor-video-files',`${unpaid}/${'0'.repeat(32)}.mp4`],['mentor-reading-files',file(33,'exe')]]) {
     await assert.rejects(run(owner,'insert into storage.objects(bucket_id,name) values($1,$2)',[bucket,path]),/row-level security/);
   }
   await assert.rejects(run(unpaid,'insert into storage.objects(bucket_id,name) values($1,$2)',['mentor-video-files',`${unpaid}/${'0'.repeat(32)}.mp4`]),/row-level security/);
   await assert.rejects(run(null,'insert into storage.objects(bucket_id,name) values($1,$2)',['mentor-video-files',file(34,'mp4')],'anon'),/row-level security/);
 });
 await t.test('attachment reference constraints reject wrong bucket/kind/path; legacy rows unchanged',async()=>{
   await assert.rejects(db.query('update learning_resources set external_url=$1 where id=$2',[url('mentor-video-files',file(13,'pdf')),id(13)]),/resource_link/);
   await assert.rejects(db.query('update learning_resources set external_url=$1 where id=$2',[url('task-attachments',file(11,'mp4')),id(11)]),/resource_link/);
   assert.equal((await db.query('select external_url from learning_resources where id=$1',[id(12)])).rows[0].external_url,'');
   const result=await run(owner,"update storage.objects set name=$1 where bucket_id='mentor-reading-files'",[file(90,'mp4')]);
   assert.equal(result.affectedRows,0);
 });
 await t.test('unrelated task attachment policies retain their owner boundary',async()=>{
   await db.exec(`insert into storage.buckets(id,name,public) values('task-attachments','task-attachments',false);
     create policy task_read on storage.objects for select to authenticated
       using(bucket_id='task-attachments' and split_part(name,'/',1)=auth.uid()::text);
     create policy task_upload on storage.objects for insert to authenticated
       with check(bucket_id='task-attachments' and split_part(name,'/',1)=auth.uid()::text);`);
   await run(paid,'insert into storage.objects(bucket_id,name) values($1,$2)',['task-attachments',`${paid}/task/file.pdf`]);
   assert.equal((await run(paid,"select * from storage.objects where bucket_id='task-attachments'")).rows.length,1);
   assert.equal((await run(unpaid,"select * from storage.objects where bucket_id='task-attachments'")).rows.length,0);
   await assert.rejects(run(unpaid,'insert into storage.objects(bucket_id,name) values($1,$2)',
     ['task-attachments',`${paid}/task/other.pdf`]),/row-level security/);
 });
 }finally{await db.close();}
});
