import assert from 'node:assert/strict';
import test from 'node:test';
import {readFile} from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';
const id=n=>`00000000-0000-4000-8000-${String(n).padStart(12,'0')}`;
test('mentor previews expose only metadata while full-row paid RLS stays enforced',async()=>{
 const db=new PGlite();try{
 await db.exec(`create role authenticated;create role anon;create schema auth;
 create function auth.uid() returns uuid language sql as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;
 create table auth.users(id uuid primary key,email_confirmed_at timestamptz);
 create table profiles(id uuid primary key,role text);
 create table content_publishers(user_id uuid);
 create table tutor_profiles(user_id uuid,is_listed boolean);
 create table mentor_payments(mentor_id uuid,learner_id uuid,status text,purchase_kind text);
 create table learning_resources(id uuid primary key,author_id uuid,author_name text,title text,summary text,category text,difficulty text,kind text,status text,moderation_hidden boolean,created_at timestamptz default now(),body text default 'SECRET',external_url text default 'PRIVATE',attachment_path text default 'PRIVATE');
 grant usage on schema auth to authenticated,anon;
 grant select on learning_resources to authenticated;
 alter table learning_resources enable row level security;`);
 const schema=await readFile(new URL('../marketplace_history/combined_schema_marketplace_profiles_v2.sql',import.meta.url),'utf8');
 for(const name of ['is_verified_account','can_author_content','is_student_account','is_content_publisher','has_mentor_library_access','can_read_mentor_resource']){
   const match=schema.match(new RegExp(`CREATE OR REPLACE FUNCTION "public"\\."${name}"[\\s\\S]*?\\$\\$;`));
  assert.ok(match,name);await db.exec(match[0]);
 }
 await db.exec(`create policy resources on learning_resources for select to authenticated using(can_read_mentor_resource(author_id,status,moderation_hidden));
 insert into auth.users values('${id(1)}',now()),('${id(2)}',now()),('${id(3)}',null);
 insert into profiles values('${id(1)}','mentor'),('${id(2)}','student'),('${id(3)}','student');
 insert into content_publishers values('${id(1)}');insert into tutor_profiles values('${id(1)}',true);
 insert into learning_resources(id,author_id,author_name,title,summary,category,difficulty,kind,status,moderation_hidden) values
 ('${id(10)}','${id(1)}','Mentor','Published','Preview','Coding','Beginner','Reading','published',false),
 ('${id(11)}','${id(1)}','Mentor','Hidden','Hidden','Coding','Beginner','Video','published',true),
 ('${id(12)}','${id(1)}','Mentor','Draft','Draft','Coding','Beginner','Reading','draft',false);`);
 await db.exec(await readFile(new URL('../migrations/020_mentor_resource_previews.sql',import.meta.url),'utf8'));
 const run=async(user,query,role='authenticated')=>{
  await db.exec(`set role ${role};select set_config('request.jwt.claim.sub','${user}',false)`);
  try{return await db.query(query);}finally{await db.exec('reset role');}
 };
 const preview=`select * from mentor_resource_previews('${id(1)}',0)`;
 const rows=(await run(id(2),preview)).rows;
 assert.equal(rows.length,1);assert.equal(rows[0].title,'Published');
 for(const key of ['body','external_url','attachment_path'])assert.equal(key in rows[0],false);
 assert.equal((await run(id(2),'select * from learning_resources')).rows.length,0);
 await assert.rejects(run(id(3),preview),/Verified account/);
 await assert.rejects(run(id(2),preview,'anon'),/permission denied/);
 await assert.rejects(run(id(2),`select * from mentor_resource_previews('${id(1)}',-1)`),/Invalid offset/);
 await db.exec(`insert into mentor_payments values('${id(1)}','${id(2)}','paid','materials')`);
 assert.equal((await run(id(2),'select * from learning_resources')).rows.length,1);
 await db.exec(`update mentor_payments set status='cancelled'`);
 assert.equal((await run(id(2),'select * from learning_resources')).rows.length,0);
 await db.exec(`update tutor_profiles set is_listed=false`);
 assert.equal((await run(id(2),preview)).rows.length,0);
 assert.equal((await run(id(1),preview)).rows.length,1);
 }finally{await db.close();}
});