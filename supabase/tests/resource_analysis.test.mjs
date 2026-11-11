import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {test} from 'node:test';
const {PGlite}=await import(process.env.PGLITE_MODULE || '@electric-sql/pglite');
const migration=await readFile(new URL('../migrations/005_save_resource_analysis.sql',import.meta.url),'utf8');
const consolidation=await readFile(new URL('../migrations/003_consolidate_video_transcripts.sql',import.meta.url),'utf8');
const start=consolidation.indexOf('create function public.read_ready_video_transcript(');
const reader=consolidation.slice(start,consolidation.indexOf('alter table public.video_transcripts enable row level security;',start));
const owner='20000000-0000-0000-0000-000000000001';
const resource='10000000-0000-0000-0000-000000000001';
const object='30000000-0000-0000-0000-000000000001';
const transcript='40000000-0000-0000-0000-000000000001';
async function setup(t){
 const db=new PGlite();t.after(()=>db.close());
 await db.exec(`create role anon;create role authenticated;create role service_role bypassrls;
 create schema storage;
 create table storage.objects(id uuid primary key,bucket_id text,name text,version text,metadata jsonb,updated_at timestamptz default now());
 create table learning_resources(id uuid primary key,author_id uuid,title text,summary text,category text,body text,tags text[],
 kind text,external_url text,status text,moderation_hidden boolean,created_at timestamptz default now(),updated_at timestamptz default now());
 create table resource_index(resource_id uuid primary key references learning_resources(id),keywords text[] not null,topic_tags text[] not null,analysed_at timestamptz not null);
 create table video_transcripts(id uuid primary key,resource_id text,source_file_id text,source_version text,storage_bucket text,storage_path text,status text,transcript_text text);
 alter table learning_resources enable row level security;alter table resource_index enable row level security;alter table video_transcripts enable row level security;
 grant usage on schema public,storage to service_role;
 grant select,insert,update on all tables in schema public,storage to service_role;
 insert into learning_resources(id,author_id,title,summary,category,body,tags,kind,external_url,status,moderation_hidden)
 values('${resource}','${owner}','Title','Summary','Category','Body',array['Dart'],'Article','','draft',false);`);
 await db.exec(reader);await db.exec(migration);return db;
}
async function snapshot(db){return (await db.query('select to_jsonb(r) source from learning_resources r')).rows[0].source;}
async function save(db,source,video=null,user=owner,words=['dart']){
 return (await db.query('select save_resource_analysis($1,$2,$3,$4,$5) saved',[user,source,video,words,['mobile development']])).rows[0].saved;
}
test('atomic upsert updates one row; failed stale/invalid requests preserve previous result',async t=>{
 const db=await setup(t);const source=await snapshot(db);await db.exec('set role service_role');
 const first=await save(db,source);const second=await save(db,source,null,owner,['flutter']);
 assert.equal(first.resource_id,resource);assert.deepEqual(second.keywords,['flutter']);
 assert.equal((await db.query('select count(*)::int n from resource_index')).rows[0].n,1);
 await db.exec("update learning_resources set body='changed'");
 await assert.rejects(save(db,source),/Resource changed/);
 const current=await snapshot(db);
 await assert.rejects(save(db,current,null,owner,[null]),/Invalid resource analysis/);
 assert.deepEqual((await db.query('select to_jsonb(i) saved from resource_index i')).rows[0].saved,second);
});
test('ownership, moderation and client RPC access are enforced',async t=>{
 const db=await setup(t);const source=await snapshot(db);
 await assert.rejects(save(db,source,null,'20000000-0000-0000-0000-000000000002'),/forbidden/);
 await db.exec('update learning_resources set moderation_hidden=true');
 await assert.rejects(save(db,await snapshot(db)),/forbidden/);
 for(const role of ['anon','authenticated']){await db.exec(`set role ${role}`);await assert.rejects(save(db,source),/permission denied/);await db.exec('reset role');}
 assert.equal((await db.query('select count(*)::int n from resource_index')).rows[0].n,0);
});
test('only current ready transcript can be saved; replacement or changed text keeps prior index intact',async t=>{
 const db=await setup(t);
 await db.exec(`update learning_resources set kind='Video',external_url='https://example.supabase.co/storage/v1/object/public/videos/a.mp4';
 insert into storage.objects(id,bucket_id,name,version,metadata) values('${object}','videos','a.mp4','v1','{}');
 insert into video_transcripts values('${transcript}','${resource}','${object}','v1','videos','a.mp4','ready','Current video text');`);
 const source=await snapshot(db);const video=(await db.query('select to_jsonb(t) source from video_transcripts t')).rows[0].source;
 const saved=await save(db,source,video);
 await db.exec("update storage.objects set version='v2'");
 await assert.rejects(save(db,source,video),/Video changed/);
 await db.exec("update storage.objects set version='v1';update video_transcripts set transcript_text='Changed text'");
 await assert.rejects(save(db,source,video),/Video changed/);
 await db.exec("update video_transcripts set transcript_text=null,status='pending'");
 await assert.rejects(save(db,source,video),/Video changed/);
 await assert.rejects(save(db,source,null),/Current transcript required/);
 assert.deepEqual((await db.query('select to_jsonb(i) saved from resource_index i')).rows[0].saved,saved);
});
