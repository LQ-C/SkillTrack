// Test-only PostgreSQL runtime; no live Supabase connection or app dependency.
// PGLITE_MODULE can be a file URL to a temporary installation's dist/index.js.
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {test} from 'node:test';
const {PGlite} = await import(process.env.PGLITE_MODULE || '@electric-sql/pglite');
const user = '10000000-0000-0000-0000-000000000001';
const otherUser = '10000000-0000-0000-0000-000000000002';
const project = '20000000-0000-0000-0000-000000000001';
const otherProject = '20000000-0000-0000-0000-000000000002';
const foreignProject = '20000000-0000-0000-0000-000000000003';
const board = '30000000-0000-0000-0000-000000000001';
const milestone = (localId, existingMilestoneId = null) => ({localId, existingMilestoneId, title: 'Build', position: 0});
const task = (title, group = null) => ({title, description: 'Implement and verify', priority: 'medium',
  deadline: '2026-12-01', checklist: ['Implement', 'Verify'], ...(group ? {milestone: group} : {})});

test('milestone migration, atomic writes and ownership in local PostgreSQL', async t => {
  const db = new PGlite();
  try {
    await db.exec(`
      create role authenticated; create role anon; create schema auth;
      create table auth.users(id uuid primary key);
      create function auth.uid() returns uuid language sql stable as
        $auth$ select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $auth$;
      grant usage on schema auth, public to authenticated;
      grant execute on function auth.uid() to authenticated;
      create table projects(id uuid primary key, owner_id uuid references auth.users, status text default 'active');
      create table kanban_boards(id uuid primary key, project_id uuid references projects on delete cascade, is_archived boolean default false);
      create table kanban_tasks(id uuid primary key default gen_random_uuid(), board_id uuid references kanban_boards on delete cascade,
        title text, description text, priority text, status text default 'todo', deadline date, sort_order bigint default 0,
        is_archived boolean default false, created_at timestamptz default now(), updated_at timestamptz default now(),
        elapsed_seconds bigint default 0, tracking_started_at timestamptz);
      create table task_checklist_items(id uuid primary key default gen_random_uuid(), task_id uuid references kanban_tasks on delete cascade,
        title text, position integer, is_completed boolean);
      create table task_activity_logs(id uuid primary key default gen_random_uuid(), task_id uuid references kanban_tasks on delete cascade,
        action text, old_values jsonb, new_values jsonb);
      create table task_attachments(id uuid primary key default gen_random_uuid(), task_id uuid references kanban_tasks on delete cascade,
        file_name text, storage_path text, mime_type text, file_size_bytes bigint);
      insert into auth.users values ('${user}'), ('${otherUser}');
      insert into projects(id, owner_id) values ('${project}', '${user}'), ('${otherProject}', '${user}'), ('${foreignProject}', '${otherUser}');
      insert into kanban_boards(id, project_id) values ('${board}', '${project}');
      alter table projects enable row level security;
      create policy owner on projects for all to authenticated using(owner_id = auth.uid()) with check(owner_id = auth.uid());
      alter table kanban_boards enable row level security;
      create policy owner on kanban_boards for all to authenticated using(exists(select 1 from projects p where p.id = project_id and p.owner_id = auth.uid()));
      alter table kanban_tasks enable row level security;
      create policy owner on kanban_tasks for all to authenticated using(exists(select 1 from kanban_boards b where b.id = board_id));
      grant select, insert, update, delete on projects, kanban_boards, kanban_tasks, task_checklist_items, task_activity_logs to authenticated;
    `);
    const old = await readFile(new URL('../migrations/atomic_kanban_writes.sql', import.meta.url), 'utf8');
    const milestonesSql = await readFile(new URL('../migrations/project_milestones.sql', import.meta.url), 'utf8');
    await t.test('missing prerequisites fail clearly before creating milestone objects', async () => {
      await assert.rejects(db.exec(milestonesSql), /atomic_kanban_writes.sql setup/);
      await db.exec('rollback');
      assert.equal((await db.query("select to_regclass('public.project_milestones') as relation")).rows[0].relation,null);
    });
    await t.test('complete prerequisite setup is rerunnable and preserves installed function definitions', async () => {
      await db.exec(old);
      await db.exec("alter function public.assert_owned_kanban_board(uuid) set statement_timeout = '30s'");
      const installed = (await db.query("select pg_get_functiondef('public.assert_owned_kanban_board(uuid)'::regprocedure) as definition")).rows[0].definition;
      await db.exec(old);
      assert.equal((await db.query("select pg_get_functiondef('public.assert_owned_kanban_board(uuid)'::regprocedure) as definition")).rows[0].definition,installed);
      // Reproduce the reported partial setup: functions exist, receipt table is missing.
      await db.exec('drop table public.kanban_write_requests cascade');
      await db.exec(old);
      assert.ok((await db.query("select to_regclass('public.kanban_write_requests') as relation")).rows[0].relation);
      assert.equal((await db.query("select pg_get_functiondef('public.assert_owned_kanban_board(uuid)'::regprocedure) as definition")).rows[0].definition,installed);
    });
    // Supabase may grant broad default privileges to API roles on newly created tables.
    await db.exec('alter default privileges in schema public grant all on tables to anon, authenticated');
    await db.exec(milestonesSql);
    const own = await db.query(`insert into project_milestones(project_id,title,position) values ($1,'Existing',0) returning id`, [project]);
    const existingId = own.rows[0].id;
    const bad = await db.query(`insert into project_milestones(project_id,title,position) values ($1,'Other owned project',0),($2,'Other user',0) returning id`, [otherProject, foreignProject]);
    await db.exec(`set role authenticated; set request.jwt.claim.sub = '${user}';`);
    const save = (id, tasks, legacy = false) => db.query(`select ${legacy ? 'save_generated_tasks' : 'save_generated_tasks_with_milestones'}($1,$2,$3::jsonb) as count`, [board, id, JSON.stringify(tasks)]);
    const counts = async () => (await db.query(`select
      (select count(*) from project_milestones) as milestones,
      (select count(*) from kanban_tasks) as tasks,
      (select count(*) from task_checklist_items) as checklist,
      (select count(*) from task_activity_logs) as activity,
      (select count(*) from kanban_write_requests) as receipts`)).rows[0];

    await t.test('legacy flat callers save ungrouped tasks', async () => {
      assert.equal((await save('legacy-request-000001', [task('Legacy')], true)).rows[0].count, 1);
      assert.equal((await db.query(`select milestone_id from kanban_tasks where title='Legacy'`)).rows[0].milestone_id, null);
    });
    const batch = [task('Plan UI', milestone('new-plan')), task('Test UI', milestone('new-plan')),
      task('Append to saved', milestone('saved-existing', existingId)), task('Independent')];
    await t.test('new and existing milestones, tasks, checklists and activity commit together', async () => {
      assert.equal((await save('milestone-request-001', batch)).rows[0].count, 4);
      const rows = (await db.query(`select title, milestone_id, sort_order from kanban_tasks order by sort_order`)).rows;
      assert.equal(rows[1].milestone_id, rows[2].milestone_id);
      assert.notEqual(rows[1].milestone_id, existingId);
      assert.equal(rows[3].milestone_id, existingId);
      assert.equal(rows[4].milestone_id, null);
      assert.deepEqual(rows.map(r => Number(r.sort_order)), [1000,2000,3000,4000,5000]);
      assert.equal(Number((await counts()).checklist), 10);
    });
    await t.test('successful retries are idempotent and mismatched payloads rejected', async () => {
      const before = await counts();
      assert.equal((await save('milestone-request-001', batch)).rows[0].count, 4);
      assert.deepEqual(await counts(), before);
      await assert.rejects(save('milestone-request-001', [task('Different')]), /already used/);
      await assert.rejects(save('milestone-request-001', batch, true), /already used/);
      assert.deepEqual(await counts(), before);
    });
    await t.test('rerunning setup and milestone migration preserves saved rows and request receipts', async () => {
      const before = await counts();
      await db.exec('reset role');
      await db.exec(old);
      await db.exec(milestonesSql);
      await db.exec('set role authenticated');
      assert.deepEqual(await counts(),before);
      assert.equal((await save('milestone-request-001', batch)).rows[0].count,4);
      assert.deepEqual(await counts(),before);
    });
    await t.test('invalid final task rolls back earlier groups, tasks, activity and receipt', async () => {
      const before = await counts();
      await assert.rejects(save('rollback-request-0001', [task('Rollback first', milestone('rollback')), {...task('Invalid checklist'), checklist: ['duplicate','duplicate']}]), /checklist/);
      assert.deepEqual(await counts(), before);
    });
    await t.test('duplicate-only batches create no empty milestone', async () => {
      const before = await counts();
      assert.equal((await save('duplicate-request-001', [task('Plan UI', milestone('unneeded'))])).rows[0].count, 0);
      assert.equal((await counts()).milestones, before.milestones);
    });
    await t.test('cross-project, cross-user and nonexistent references rejected even for duplicates', async () => {
      const before = await counts();
      for (const id of [...bad.rows.map(r => r.id), '99999999-0000-0000-0000-000000000000']) {
        await assert.rejects(save('foreign-request-'+id, [task('Plan UI', milestone('foreign', id))]), /Milestone unavailable/);
        await assert.rejects(db.query(`update kanban_tasks set milestone_id=$1 where title='Legacy'`,[id]), /Milestone unavailable/);
        await assert.rejects(db.query(`insert into kanban_tasks(board_id,title,milestone_id) values ($1,'Bad direct insert',$2)`,[board,id]), /Milestone unavailable/);
      }
      assert.deepEqual(await counts(), before);
    });
    await t.test('RLS prevents access and mutation across users', async () => {
      assert.equal((await db.query("select has_table_privilege(current_user, 'project_milestones', 'TRUNCATE') as allowed")).rows[0].allowed,false);
      for (const title of ['   ', 'x'.repeat(151), ' '+ 'x'.repeat(150) +' ']) {
        await assert.rejects(db.query('insert into project_milestones(project_id,title,position) values ($1,$2,0)',[project,title]), /check constraint/);
      }
      await assert.rejects(db.query('insert into project_milestones(project_id,title,position) values ($1,$2,-1)',[project,'Invalid position']), /check constraint/);
      assert.equal((await db.query(`select id from project_milestones where project_id=$1`,[foreignProject])).rows.length,0);
      await assert.rejects(db.query(`insert into project_milestones(project_id,title,position) values ($1,'Bad',0)`,[foreignProject]), /row-level security/);
      assert.equal((await db.query(`update project_milestones set title='Bad' where project_id=$1 returning id`,[foreignProject])).rows.length,0);
    });
    await t.test('membership survives ordinary status/archive/order/timer changes', async () => {
      await db.exec(`update kanban_tasks set status='in_progress', tracking_started_at=now(), sort_order=9000, is_archived=true where title='Append to saved';`);
      const row = (await db.query(`select milestone_id, tracking_started_at from kanban_tasks where title='Append to saved'`)).rows[0];
      assert.equal(row.milestone_id,existingId); assert.ok(row.tracking_started_at);
      await db.exec(`update kanban_tasks set is_archived=false where title='Append to saved'`);
    });
    await t.test('project reassignment cannot invalidate membership', async () => {
      await assert.rejects(db.query(`update project_milestones set project_id=$1 where id=$2`,[otherProject,existingId]), /cannot be transferred/);
      await assert.rejects(db.query(`update kanban_boards set project_id=$1 where id=$2`,[otherProject,board]), /cannot be transferred/);
    });
    await t.test('milestone deletion nulls membership and project deletion cascades', async () => {
      await db.query(`delete from project_milestones where id=$1`,[existingId]);
      assert.equal((await db.query(`select milestone_id from kanban_tasks where title='Append to saved'`)).rows[0].milestone_id,null);
      await db.query(`delete from projects where id=$1`,[project]);
      assert.equal((await db.query(`select id from project_milestones where project_id=$1`,[project])).rows.length,0);
      assert.equal((await db.query(`select id from kanban_tasks`)).rows.length,0);
    });
  } finally { await db.close(); }
});
