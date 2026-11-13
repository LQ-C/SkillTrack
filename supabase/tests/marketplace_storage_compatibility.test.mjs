import assert from 'node:assert/strict';
import test from 'node:test';
import {readFile} from 'node:fs/promises';
const {PGlite}=await import(process.env.PGLITE_MODULE || '@electric-sql/pglite');
test('marketplace compatibility preserves file ownership and extraction provenance',async()=>{
 const db=new PGlite();
 try {
 await db.exec(`create schema storage;
 create function public.can_read_mentor_resource(uuid,text,boolean) returns boolean language sql as $$select false$$;
 create function public.valid_resource_link(text) returns boolean language sql as $$select $1 ~ '^https://'$$;
 create function public.resource_analysis_storage_key(text) returns text language sql as $$select substring($1 from '^https://[^/]+/storage/v1/object/(?:public|authenticated)/(.+)$')$$;
 create function public.is_image_resource(jsonb) returns boolean language sql as $$select coalesce($1->>'external_url' ~ '\\.(png|jpg|jpeg)$',false)$$;
 create table learning_resources(id uuid primary key,author_id uuid,kind text,body text default '',external_url text,attachment_path text,status text default 'published',moderation_hidden boolean default false, constraint resource_link check(true));
 create table storage.objects(id uuid primary key,bucket_id text,name text,version text,metadata jsonb,updated_at timestamptz);
 create table resource_extractions(id uuid primary key default gen_random_uuid(),resource_id text,source_file_id text,source_version text,storage_bucket text,storage_path text,extraction_type text,unique(resource_id,source_file_id,source_version));`);
 await db.exec(await readFile(new URL('../migrations/017_marketplace_storage_compatibility.sql',import.meta.url),'utf8'));
 const owner='00000000-0000-4000-8000-000000000001';
 const rid='00000000-0000-4000-8000-000000000002';
 const path=owner+'/0123456789abcdef0123456789abcdef.pdf';
 const url='https://fixture.supabase.co/storage/v1/object/authenticated/mentor-reading-files/'+path;
 await db.query('insert into learning_resources(id,author_id,kind,external_url,attachment_path) values($1,$2,$3,$4,$5)',[rid,owner,'Reading',url,path]);
 assert.equal((await db.query('select is_pdf_resource(to_jsonb(r)) result from learning_resources r')).rows[0].result,true);
 await assert.rejects(db.query('update learning_resources set external_url=$1',['https://fixture.supabase.co/storage/v1/object/authenticated/task-attachments/'+path]),/resource_link/);
 await assert.rejects(db.query('update learning_resources set attachment_path=$1',['another-user/file.pdf']),/resource_link/);
 assert.equal((await db.query('select enqueue_discovered_extraction($1,$2,$3,$4) id',[rid,url,'mentor-reading-files',path])).rows[0].id,null);
 await db.query('insert into storage.objects values(gen_random_uuid(),$1,$2,$3,$4,now())',['mentor-reading-files',path,'version-1',{}]);
 const args=[rid,url,'mentor-reading-files',path];
 const first=(await db.query('select enqueue_discovered_extraction($1,$2,$3,$4) id',args)).rows[0].id;
 assert.ok(first);
 assert.equal((await db.query('select enqueue_discovered_extraction($1,$2,$3,$4) id',args)).rows[0].id,first);
 assert.equal((await db.query('select extraction_type from resource_extractions')).rows[0].extraction_type,'pdf_text');
 assert.equal((await db.query('select enqueue_discovered_extraction($1,$2,$3,$4) id',[rid,url,'task-attachments',path])).rows[0].id,null);
 await db.exec("update learning_resources set moderation_hidden=true");
 assert.equal((await db.query('select enqueue_discovered_extraction($1,$2,$3,$4) id',args)).rows[0].id,null);
 } finally {await db.close();}
});
