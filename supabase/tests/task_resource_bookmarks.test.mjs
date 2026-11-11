import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {test} from 'node:test';
const {PGlite}=await import(process.env.PGLITE_MODULE || '@electric-sql/pglite');
const id=n=>`00000000-0000-0000-0000-${String(n).padStart(12,'0')}`;
test('task bookmarks preserve ownership, current access and retry safety',async t=>{
 const db=new PGlite();
 try {
 await db.exec(`create role authenticated; create role anon; create schema auth;
 create function auth.uid() returns uuid language sql as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;
 grant usage on schema auth to authenticated;
 create table projects(id uuid primary key,owner_id uuid,status text);
 create table kanban_boards(id uuid primary key,project_id uuid references projects,is_archived boolean default false);
 create table kanban_tasks(id uuid primary key,board_id uuid references kanban_boards,is_archived boolean default false,status text default 'todo');
 create table learning_resources(id uuid primary key,title text,summary text,kind text,status text,moderation_hidden boolean,allowed boolean default true);
 alter table learning_resources enable row level security;
 create policy access on learning_resources for select to authenticated using(allowed);
 grant select on learning_resources to authenticated;
 insert into projects values('${id(1)}','${id(10)}','active');
 insert into kanban_boards(id,project_id) values('${id(2)}','${id(1)}');
 insert into kanban_tasks(id,board_id) values('${id(3)}','${id(2)}'),('${id(4)}','${id(2)}');
 insert into learning_resources values('${id(5)}','Current title','Summary','Video','published',false,true);`);
 await db.exec(await readFile(new URL('../migrations/012_task_resource_bookmarks.sql',import.meta.url),'utf8'));
 const run=async(sql,args=[],owner=id(10))=>{
 await db.exec(`set role authenticated; select set_config('request.jwt.claim.sub','${owner}',false)`);
 try{return await db.query(sql,args);}finally{await db.exec('reset role');}
 };
 const save=(task=id(3),value=true,user=id(10))=>run('select set_task_resource_bookmark($1,$2,$3)',[task,id(5),value],user);
 const list=()=>run('select * from task_saved_resources($1)',[id(3)]);
 await t.test('save, lost-response retry and same resource on two tasks',async()=>{
 await save();await save();await save(id(4));
 assert.equal((await db.query('select * from task_resource_bookmarks')).rows.length,2);
 assert.equal((await list()).rows[0].title,'Current title');
 });
 await t.test('foreign owner cannot read or remove',async()=>{
 await assert.rejects(save(id(3),false,id(11)),/access denied/);
 await assert.rejects(run('select * from task_saved_resources($1)',[id(3)],id(11)),/access denied/);
 });
 await t.test('hidden and inaccessible details withheld; removal and retries allowed',async()=>{
 for(const change of ['moderation_hidden=true','moderation_hidden=false,allowed=false',"allowed=true,status='archived'"]){
 await db.exec(`update learning_resources set ${change}`);
 assert.equal((await list()).rows[0].title,'Resource unavailable');
 }
 await save(id(3),false);await save(id(3),false);
 await assert.rejects(save(),/row-level security/);
 await db.exec("update learning_resources set status='published',allowed=true,moderation_hidden=false");
 await save();
 });
 await t.test('new saves reject hidden, draft and inaccessible resources',async()=>{
 await save(id(3),false);
 for(const change of ['moderation_hidden=true',"moderation_hidden=false,status='draft'","status='published',allowed=false"]){
 await db.exec(`update learning_resources set ${change}`);
 await assert.rejects(save(),/row-level security/);
 assert.equal((await list()).rows.length,0);
 }
 await db.exec("update learning_resources set allowed=true,status='published',moderation_hidden=false");
 await save();
 });
 await t.test('completed and archived tasks retain links but cannot add new ones',async()=>{
 await db.exec("update kanban_tasks set status='completed',is_archived=true");
 assert.equal((await list()).rows.length,1);
 await save();await save(id(3),false);
 await assert.rejects(save(),/row-level security/);
 await db.exec("update kanban_tasks set status='in_progress',is_archived=false");
 await save();
 });
 await t.test('resource and task deletes cascade',async()=>{
 await db.exec(`delete from kanban_tasks where id='${id(4)}'`);
 assert.equal((await db.query('select * from task_resource_bookmarks')).rows.length,1);
 await db.exec('delete from learning_resources');
 assert.equal((await list()).rows.length,0);
 });
 } finally {await db.close();}
});
