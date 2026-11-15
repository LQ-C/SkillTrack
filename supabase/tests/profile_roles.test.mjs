import assert from 'node:assert/strict';
import test from 'node:test';
import {readFile} from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';
const id=n=>`00000000-0000-4000-8000-${String(n).padStart(12,'0')}`;

test('existing integrated role triggers preserve open mentoring, ownership, payments and user data', async()=>{
 const db=new PGlite();
 try {
  await db.exec(`create role authenticated; create schema auth;
   create function auth.uid() returns uuid language sql as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;
   create table auth.users(id uuid primary key,email_confirmed_at timestamptz);
   create table profiles(id uuid primary key,role text check(role in ('student','mentor')),full_name text);
   create table tutor_profiles(user_id uuid primary key,verification_status text,review_note text default '',reviewed_at timestamptz,headline text default '');
   create table content_publishers(user_id uuid primary key);
   create table learning_resources(id uuid primary key,author_id uuid,status text,moderation_hidden boolean default false,body text);
   create table mentor_payments(id uuid primary key,mentor_id uuid,learner_id uuid,status text,purchase_kind text);
   create table projects(id uuid primary key,owner_id uuid,name text);
   create table mentorship_requests(id uuid primary key,learner_id uuid,mentor_id uuid,status text);
   grant usage on schema auth to authenticated;
   grant select,update on profiles to authenticated;
   grant select,insert,update on learning_resources to authenticated;
   alter table profiles enable row level security;
   alter table learning_resources enable row level security;`);
  const schema=await readFile(new URL('../marketplace_history/combined_schema_marketplace_profiles_v2.sql',import.meta.url),'utf8');
  const original=await readFile(new URL('../marketplace_history/202611080001_open_mentor_roles.sql',import.meta.url),'utf8');
  for(const name of ['is_verified_account','can_author_content','can_publish_content','is_student_account','is_content_publisher','has_mentor_library_access','can_read_mentor_resource','require_tutor_qualification','sync_open_mentor_role','sync_tutor_publisher']) {
   const sql=schema.match(new RegExp(String.raw`CREATE OR REPLACE FUNCTION "public"\."${name}"[\s\S]*?\$\$;`))?.[0];
   assert.ok(sql,name);
   await db.exec(sql);
   if(['require_tutor_qualification','sync_open_mentor_role','sync_tutor_publisher'].includes(name)) {
    const body=sql.match(/begin[\s\S]*?end;/i)?.[0];
    assert.ok(original.includes(body),`${name} must match teammate open-role rules`);
   }
  }
  for(const name of ['on_open_mentor_role','require_qualification','tutor_publisher_sync']) {
   const sql=schema.match(new RegExp(`CREATE OR REPLACE TRIGGER "${name}"[^;]*;`))?.[0];
   assert.ok(sql,name); await db.exec(sql);
  }
  for(const name of ['Read own profile','Update own profile','Read visible or own resources','Mentors create own resources','Mentors edit own resources']) {
   const sql=schema.match(new RegExp(`CREATE POLICY "${name}"[^;]*;`))?.[0];
   assert.ok(sql,name); await db.exec(sql);
  }
  await db.exec(`insert into auth.users values('${id(1)}',now()),('${id(2)}',now()),('${id(3)}',null);
   insert into profiles values('${id(1)}','student','Switching user'),('${id(2)}','mentor','Other mentor'),('${id(3)}','student','Unverified');
   insert into projects values('${id(10)}','${id(1)}','Keep project');
   insert into mentorship_requests values('${id(11)}','${id(1)}','${id(2)}','accepted');
   insert into mentor_payments values('${id(12)}','${id(2)}','${id(1)}','pending','materials');
   insert into learning_resources values('${id(20)}','${id(2)}','published',false,'Protected'),('${id(21)}','${id(2)}','published',true,'Hidden');`);
  const run=async(user,sql)=>{
   await db.exec(`set role authenticated; select set_config('request.jwt.claim.sub','${user}',false);`);
   try { return (await db.query(sql)).rows; } finally { await db.exec('reset role'); }
  };
  const role=async(value)=>run(id(1),`update profiles set role='${value}' where id='${id(1)}' returning role`);
  const author=async(user=id(1))=>(await run(user,'select can_author_content() as author,can_publish_content() as publisher'))[0];
  const visible=()=>run(id(1),`select id from learning_resources where author_id='${id(2)}'`);
  assert.deepEqual(await author(),{author:false,publisher:false});
  assert.equal((await visible()).length,0);
  assert.deepEqual(await role('mentor'),[{role:'mentor'}]);
  assert.deepEqual(await author(),{author:true,publisher:true});
  assert.deepEqual((await db.query(`select verification_status from tutor_profiles where user_id='${id(1)}'`)).rows,[{verification_status:'approved'}]);
  await db.exec(`update tutor_profiles set headline='Retained mentor details' where user_id='${id(1)}'`);
  await run(id(1),`insert into learning_resources values('${id(22)}','${id(1)}','published',false,'My existing resource')`);
  await assert.rejects(run(id(1),`insert into learning_resources values('${id(23)}','${id(2)}','published',false,'Foreign author')`),/row-level security/);
  const snapshot=async()=>{
   const rows={};
   for(const table of ['projects','learning_resources','mentor_payments','mentorship_requests']) rows[table]=(await db.query(`select * from ${table} order by id`)).rows;
   return rows;
  };
  const before=await snapshot();
  await role('student');
  assert.deepEqual(await author(),{author:false,publisher:false});
  assert.equal((await db.query(`select 1 from content_publishers where user_id='${id(1)}'`)).rows.length,0);
  assert.equal((await db.query(`select headline from tutor_profiles where user_id='${id(1)}'`)).rows[0].headline,'Retained mentor details');
  assert.deepEqual(await snapshot(),before);
  assert.equal((await visible()).length,0,'switching roles is not a purchase');
  await assert.rejects(run(id(1),`insert into learning_resources values('${id(24)}','${id(1)}','published',false,'Student upload')`),/row-level security/);
  await role('mentor');
  assert.deepEqual(await author(),{author:true,publisher:true});
  assert.equal((await db.query(`select headline from tutor_profiles where user_id='${id(1)}'`)).rows[0].headline,'Retained mentor details');
  assert.deepEqual(await snapshot(),before);
  await role('student');
  await db.exec(`update mentor_payments set status='paid' where id='${id(12)}'`);
  assert.deepEqual(await visible(),[{id:id(20)}],'paid access still excludes hidden resources');
  await role('mentor'); assert.equal((await visible()).length,0,'existing student-only access rules remain enforced');
  await role('student'); assert.deepEqual(await visible(),[{id:id(20)}],'purchase survives role switches');
  assert.deepEqual(await run(id(1),`update profiles set role='student' where id='${id(2)}' returning id`),[],'cannot switch another account');
  assert.deepEqual(await run(id(3),`update profiles set role='mentor' where id='${id(3)}' returning id`),[],'unverified users cannot switch');
  assert.deepEqual(await author(id(3)),{author:false,publisher:false});
 } finally { await db.close(); }
});
