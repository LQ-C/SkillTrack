import assert from 'node:assert/strict';
import {clearOwnedFolder, resourceCleanupBuckets, type OwnedStorage} from './storage_cleanup.ts';
const owner='00000000-0000-4000-8000-000000000001';
Deno.test('account cleanup traverses own task folders and preserves other owners',async()=>{
 const paths=new Set([`${owner}/task/a.pdf`,`${owner}/lesson.mp4`,'another-user/private.pdf']);
 const removed:string[]=[];
 const store:OwnedStorage={
   async list(prefix){
     const children=new Map<string,{name:string;id:string|null}>();
     for(const path of paths){if(!path.startsWith(prefix+'/'))continue;
       const remaining=path.slice(prefix.length+1), name=remaining.split('/')[0];
       children.set(name,{name,id:remaining.includes('/')?null:'object'});}
     return {data:[...children.values()],error:null};
   },
   async remove(items){for(const path of items){paths.delete(path);removed.push(path);}
     return {error:null};}
 };
 await clearOwnedFolder(store,owner);
 assert.equal(removed.length,2);assert.deepEqual([...paths],['another-user/private.pdf']);
 await assert.rejects(()=>clearOwnedFolder(store,owner,'another-user'),/Invalid cleanup path/);
});
Deno.test('cleanup fails closed on list/delete failure and invalid names',async()=>{
 const fail:OwnedStorage={async list(){return {data:null,error:{statusCode:403}};},
   async remove(){throw new Error('must not delete');}};
 await assert.rejects(()=>clearOwnedFolder(fail,owner),/unavailable/);
 const traversal:OwnedStorage={...fail,async list(){return {data:[{name:'..',id:'bad'}],error:null};}};
 await assert.rejects(()=>clearOwnedFolder(traversal,owner),/Invalid cleanup object/);
 const missing:OwnedStorage={...fail,async list(){return {data:null,error:{statusCode:404}};}};
 await clearOwnedFolder(missing,owner);
});

Deno.test('account cleanup covers both resource buckets and leaves other owners intact',async()=>{
 assert.ok(resourceCleanupBuckets.includes('mentor-video-files'));
 const removed = new Map<string,string[]>();
 for(const bucket of resourceCleanupBuckets) {
   const paths=new Set([`${owner}/file.mp4`, 'another-owner/file.mp4']);
   const store:OwnedStorage={
     async list(prefix){return {data:[...paths].filter(p=>p.startsWith(prefix+'/')).map(p=>({name:p.slice(prefix.length+1),id:'file'})),error:null};},
     async remove(items){for(const path of items)paths.delete(path);removed.set(bucket,items);return {error:null};}
   };
   await clearOwnedFolder(store,owner);
   assert.deepEqual([...paths],['another-owner/file.mp4']);
 }
 assert.equal(removed.size,3);
});
