import assert from 'node:assert/strict';
import test from 'node:test';
import {readFile} from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';
test('category migration expands writes and preserves deployed and unknown historical values',async()=>{
 const db=new PGlite();try{
 const dart=await readFile(new URL('../../lib/core/constants/content_options.dart',import.meta.url),'utf8');
 const categories=[...dart.split('const contentLevels')[0].matchAll(/  '([^']+)',/g)].map(m=>m[1]);
 assert.equal(categories.length,17);
 await db.exec(`create table learning_resources(id integer primary key,category text not null,constraint learning_resources_category_check check(category in ('Programming','Design','Business','Languages','Music','Lifestyle','Other','Custom Legacy')));
 insert into learning_resources values(1,'Custom Legacy'),(2,'Design');`);
 const before=(await db.query('select * from learning_resources order by id')).rows;
 const migration=await readFile(new URL('../migrations/021_expand_resource_categories.sql',import.meta.url),'utf8');
 for(const name of ['Design','Business','Languages','Music','Lifestyle','Other'])assert.equal(migration.includes("'"+name+"'"),false);
 await db.exec(migration);
 assert.deepEqual((await db.query('select * from learning_resources order by id')).rows,before);
 for(let i=0;i<categories.length;i++){
   await db.query('insert into learning_resources values($1,$2)',[i+10,categories[i]]);
   assert.equal((await db.query('select count(*)::int n from learning_resources where category=$1',[categories[i]])).rows[0].n>=1,true);
 }
 await db.exec("insert into learning_resources values(3,'Custom Legacy');update learning_resources set category='Custom Legacy' where id=1;");
 await assert.rejects(db.exec("insert into learning_resources values(4,'INVALID');"),/check constraint/);
 // Safe to rerun without removing any accepted values.
 await db.exec(migration);
 await db.exec("insert into learning_resources values(5,'Web Development');");
 }finally{await db.close();}
});
