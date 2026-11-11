import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { test } from 'node:test';
const { PGlite } = await import(process.env.PGLITE_MODULE || '@electric-sql/pglite');
const owner = '10000000-0000-0000-0000-000000000001';
const other = '10000000-0000-0000-0000-000000000002';
const tag = '20000000-0000-0000-0000-000000000001';
// Canonical base schema unavailable: deliberately use a NON-cascading FK.
test('atomic tag deletion with ownership and response-loss retries', async t => {
  const db = new PGlite();
  try {
    await db.exec(`
      create role authenticated; create role anon; create schema auth;
      create function auth.uid() returns uuid language sql stable as
        $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;
      create table task_tags(id uuid primary key, owner_id uuid not null);
      create table task_tag_links(task_id uuid,tag_id uuid references task_tags,primary key(task_id,tag_id));
      alter table task_tags enable row level security;
      alter table task_tag_links enable row level security;
      create policy owner_only on task_tags to authenticated using(owner_id=auth.uid());
      insert into task_tags values ('${tag}','${owner}');
      insert into task_tag_links values ('${owner}','${tag}'),('${other}','${tag}');
    `);
    await db.exec(await readFile(new URL('../migrations/atomic_task_tag_deletion.sql', import.meta.url),'utf8'));
    const call = async user => {
      await db.exec(`set role authenticated; select set_config('request.jwt.claim.sub','${user}',false)`);
      try { await db.query('select public.delete_owned_task_tag($1)',[tag]); }
      finally { await db.exec('reset role'); }
    };
    const counts = async () => (await db.query(`select
      (select count(*)::int from task_tags) tags,
      (select count(*)::int from task_tag_links) links`)).rows[0];
    await t.test('unauthorized existing tag and anonymous caller change nothing', async () => {
      await assert.rejects(call(other), /Tag access denied/);
      await assert.rejects(call(''), /Authentication required/);
      assert.deepEqual(await counts(), {tags:1,links:2});
    });
    await t.test('late failure rolls back deleted links and parent', async () => {
      await db.exec(`create function fail_tag_delete() returns trigger language plpgsql as
        $$begin raise exception 'forced late failure'; end$$;
        create trigger fail_delete before delete on task_tags for each row execute function fail_tag_delete()`);
      await assert.rejects(call(owner), /forced late failure/);
      assert.deepEqual(await counts(), {tags:1,links:2});
      await db.exec('drop trigger fail_delete on task_tags');
    });
    await t.test('success removes both and lost-response retry is harmless', async () => {
      await call(owner); // Discard response, then retry exactly the same tag ID.
      assert.deepEqual(await counts(), {tags:0,links:0});
      await call(owner);
      assert.deepEqual(await counts(), {tags:0,links:0});
    });
  } finally { await db.close(); }
});
