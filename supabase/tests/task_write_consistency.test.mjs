import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { test } from 'node:test';

const { PGlite } = await import(process.env.PGLITE_MODULE || '@electric-sql/pglite');
const owner = '10000000-0000-0000-0000-000000000001';
const other = '10000000-0000-0000-0000-000000000002';
const project = '20000000-0000-0000-0000-000000000001';
const board = '30000000-0000-0000-0000-000000000001';
const task = '40000000-0000-0000-0000-000000000001';
const destination = '40000000-0000-0000-0000-000000000002';
const oldTag = '50000000-0000-0000-0000-000000000001';
const newTag = '50000000-0000-0000-0000-000000000002';
const unrelatedTag = '50000000-0000-0000-0000-000000000004';
const foreignTag = '50000000-0000-0000-0000-000000000003';
const attachment = '60000000-0000-0000-0000-000000000001';
const cascadeAttachment = '60000000-0000-0000-0000-000000000002';
const timestamp = '2026-11-05T12:00:00Z';
const edit = {
  title: ' Edited ', description: 'Details', status: 'completed', priority: 'high',
  deadline: '2026-11-10T15:59:00Z', deadline_has_time: false, milestone_id: null,
};

test('atomic task edits and durable attachment deletion', async (t) => {
  const db = new PGlite();
  try {
    await db.exec(`
      create role authenticated; create role anon; create schema auth;
      create table auth.users(id uuid primary key);
      create function auth.uid() returns uuid language sql stable as
        $$select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid$$;
      grant usage on schema auth to authenticated;
      create table projects(id uuid primary key, owner_id uuid not null, status text not null);
      create table kanban_boards(id uuid primary key, project_id uuid references projects, is_archived boolean default false);
      create table kanban_tasks(
        id uuid primary key, board_id uuid references kanban_boards,
        title text, description text, priority text, status text, sort_order bigint,
        deadline timestamptz, deadline_has_time boolean, milestone_id uuid,
        is_archived boolean default false, completed_at timestamptz, updated_at timestamptz
      );
      create table task_tags(id uuid primary key, owner_id uuid not null);
      create table task_tag_links(
        task_id uuid references kanban_tasks on delete cascade,
        tag_id uuid references task_tags, primary key(task_id, tag_id)
      );
      create table task_checklist_items(
        id uuid primary key, task_id uuid references kanban_tasks on delete cascade, position integer
      );
      create table task_attachments(
        id uuid primary key, task_id uuid references kanban_tasks on delete cascade,
        file_name text, storage_path text
      );
      create table task_activity_logs(
        task_id uuid references kanban_tasks on delete cascade,
        action text, old_values jsonb, new_values jsonb
      );
      grant select, insert, update, delete on all tables in schema public to authenticated;
      alter table kanban_tasks enable row level security;
      create policy own_task on kanban_tasks to authenticated using(exists(
        select 1 from kanban_boards b join projects p on p.id=b.project_id
        where b.id=board_id and p.owner_id=auth.uid()));
      alter table task_attachments enable row level security;
      create policy own_attachment on task_attachments to authenticated using(exists(
        select 1 from kanban_tasks t where t.id=task_id));
      insert into auth.users values ('${owner}'), ('${other}');
      insert into projects values ('${project}', '${owner}', 'active');
      insert into kanban_boards(id,project_id) values ('${board}','${project}');
      insert into kanban_tasks(id,board_id,title,priority,status,sort_order,updated_at) values
        ('${task}','${board}','Original','medium','in_progress',1000,'${timestamp}'),
        ('${destination}','${board}','Done','medium','completed',2000,'${timestamp}');
      insert into task_tags values ('${oldTag}','${owner}'), ('${newTag}','${owner}'), ('${foreignTag}','${other}'), ('${unrelatedTag}','${owner}');
      insert into task_tag_links values ('${task}','${oldTag}'), ('${task}','${unrelatedTag}');
      insert into task_attachments values
        ('${attachment}','${task}','notes.txt','${owner}/notes'),
        ('${cascadeAttachment}','${destination}','other.txt','${owner}/other');
      insert into task_checklist_items values (gen_random_uuid(), '${task}', 0);
      create function fail_test_write() returns trigger language plpgsql as $$
      begin
        if new.action=current_setting('test.fail_action', true) then
          raise exception 'forced activity failure';
        end if;
        return new;
      end $$;
      create trigger fail_test_write before insert on task_activity_logs
        for each row execute function fail_test_write();
    `);
    for (const migration of ['atomic_kanban_writes', 'task_time_tracking', 'task_write_consistency']) {
      await db.exec(await readFile(new URL(`../migrations/${migration}.sql`, import.meta.url), 'utf8'));
    }
    await db.exec(`
      update kanban_tasks set elapsed_seconds=90, tracking_started_at=clock_timestamp()-interval '15 seconds' where id='${task}';
      set role authenticated; set request.jwt.claim.sub='${owner}';
    `);
    const first = async (sql, params) => (await db.query(sql, params)).rows[0];
    const save = async ({
      request = 'test-atomic-task-edit-001', changes = edit, tags = [newTag], expected = timestamp,
    } = {}) => (await first(
      'select save_kanban_task_edit($1,$2,$3,$4::jsonb,$5::uuid[],$6::uuid[]) as result',
      [task, expected, request, JSON.stringify(changes), tags, [oldTag]],
    )).result;
    const snapshot = async () => ({
      task: await first('select * from kanban_tasks where id=$1', [task]),
      links: (await db.query('select * from task_tag_links order by tag_id')).rows,
      activity: (await db.query('select * from task_activity_logs order by action')).rows,
      receipts: (await db.query('select * from kanban_write_requests order by request_id')).rows,
    });

    await t.test('a late activity failure rolls back fields, tracking, tags and receipt', async () => {
      const before = await snapshot();
      await db.exec("set test.fail_action='tag_added'");
      await assert.rejects(save(), /forced activity failure/);
      assert.deepEqual(await snapshot(), before);
      await db.exec("set test.fail_action=''");
    });

    await t.test('edit returns committed data and retries without repeating effects', async () => {
      const saved = await save();
      assert.equal(saved.task.title, 'Edited');
      assert.equal(saved.task.status, 'completed');
      assert.equal(saved.task.sort_order, 3000);
      assert.ok(saved.task.elapsed_seconds >= 105);
      assert.equal(saved.task.tracking_started_at, null);
      assert.ok(saved.task.completed_at);
      assert.equal(saved.task.deadline, '2026-11-10T15:59:00+00:00');
      assert.equal(saved.task.deadline_has_time, false);
      assert.deepEqual(saved.tags.map(tag => tag.id), [newTag, unrelatedTag]);
      assert.equal(saved.checklist.length, 1);
      assert.equal(saved.attachments.length, 1);
      const after = await snapshot();
      assert.deepEqual(after.activity.map(log => log.action), ['completed','tag_added','tag_removed','updated']);
      assert.equal(after.receipts.length, 1);
      await db.exec("set timezone='Asia/Kuala_Lumpur'");
      assert.deepEqual(await save(), saved);
      assert.deepEqual(await snapshot(), after);
      await assert.rejects(save({changes: {...edit,title:'Other'}}), /already used/);
      await assert.rejects(save({request:'test-atomic-task-edit-002'}), {code:'40001'});
      await assert.rejects(save({request:'test-atomic-task-edit-003',tags:[foreignTag],
        expected:saved.task.updated_at}), {code:'42501'});
      assert.deepEqual(await snapshot(), after);
    });

    await t.test('attachment history and queue roll back together, then retry safely', async () => {
      assert.equal((await first(
        "select relkind from pg_class where oid = 'public.task_attachment_cleanup'::regclass"
      )).relkind, 'v');
      const remove = () => db.query('select delete_kanban_task_attachment($1)', [attachment]);
      const queued = async () => (await db.query('select storage_path from task_attachment_cleanup order by storage_path')).rows.map(row => row.storage_path);
      await db.exec("set test.fail_action='attachment_removed'");
      await assert.rejects(remove(), /forced activity failure/);
      assert.equal((await first('select id from task_attachments where id=$1', [attachment])).id, attachment);
      assert.deepEqual(await queued(), []);
      await db.exec("set test.fail_action=''");
      await remove();
      await remove();
      assert.equal(await first('select id from task_attachments where id=$1', [attachment]), undefined);
      assert.deepEqual(await queued(), [`${owner}/notes`]);
      assert.equal((await first("select count(*) as count from task_activity_logs where action='attachment_removed'")).count, 1);
      await db.query('delete from kanban_tasks where id=$1', [destination]);
      assert.deepEqual(await queued(), [`${owner}/notes`, `${owner}/other`]);
      await db.exec(`set request.jwt.claim.sub='${other}'`);
      assert.deepEqual(await queued(), []);
      await db.query('delete from task_attachment_cleanup where user_id=$1', [owner]);
      await assert.rejects(save(), {code:'42501'});
      await db.exec(`set request.jwt.claim.sub='${owner}'`);
      assert.deepEqual(await queued(), [`${owner}/notes`, `${owner}/other`]);
      const acknowledged = await first(
        'delete from task_attachment_cleanup where user_id=$1 and storage_path=$2 returning storage_path',
        [owner, `${owner}/notes`],
      );
      assert.equal(acknowledged.storage_path, `${owner}/notes`);
      assert.deepEqual(await queued(), [`${owner}/other`]);
      assert.equal(await first(
        'delete from kanban_write_requests where request_id=$1 returning request_id',
        ['test-atomic-task-edit-001'],
      ), undefined);
      assert.equal((await first(
        'select request_id from kanban_write_requests where request_id=$1',
        ['test-atomic-task-edit-001'],
      )).request_id, 'test-atomic-task-edit-001');
      await assert.rejects(db.query(`insert into kanban_write_requests
        (user_id,request_id,board_id,payload,saved_count)
        values ($1,'skilltrack:v1:attachment_cleanup:forged',null,
          jsonb_build_object('storage_path',$2::text),0)`, [owner, `${other}/foreign`]), {code:'42501'});
    });
  } finally {
    await db.close();
  }
});
