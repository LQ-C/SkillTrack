import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { test } from 'node:test';

const { PGlite } = await import(process.env.PGLITE_MODULE || '@electric-sql/pglite');
const owner = '10000000-0000-0000-0000-000000000001';
const other = '10000000-0000-0000-0000-000000000002';
const tag = '20000000-0000-0000-0000-000000000001';
const foreignTag = '20000000-0000-0000-0000-000000000002';
const group = { localId: 'build', title: 'Build', position: 0 };
const plan = ['Set up', 'Implement'].map(title => ({
  title, description: 'Build the app', priority: 'medium', deadline: '2027-02-08',
  checklist: ['Test it'], milestone: group,
}));
const fields = {
  title: 'Manual', description: '', status: 'in_progress', priority: 'medium',
  deadline: '2027-02-08T09:00:00Z', deadline_has_time: true, tag_ids: [tag], checklist: ['Check it'],
};

// The application baseline is unavailable. This fixture uses real PostgreSQL
// constraints and owner policies plus the checked-in migration implementations.
test('atomic project and task actions against local PostgreSQL', async t => {
  const db = new PGlite();
  try {
    await db.exec(`
      create role authenticated; create role anon; create role service_role bypassrls;
      create schema auth;
      create table auth.users(id uuid primary key);
      create function auth.uid() returns uuid language sql stable as
        $$select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid$$;
      grant usage on schema auth to authenticated;
      create table profiles(id uuid primary key);
      create table projects(id uuid primary key default gen_random_uuid(),
        owner_id uuid not null references auth.users, name text not null,
        description text, constraints_text text, status text not null, start_date date, end_date date);
      create table kanban_boards(id uuid primary key default gen_random_uuid(),
        project_id uuid not null references projects on delete cascade, name text not null,
        is_archived boolean not null default false);
      create table kanban_tasks(id uuid primary key default gen_random_uuid(),
        board_id uuid not null references kanban_boards on delete cascade,
        title text not null, description text, priority text, status text not null,
        deadline timestamptz, sort_order bigint not null, is_archived boolean not null default false,
        created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
        completed_at timestamptz);
      create table task_tags(id uuid primary key, owner_id uuid not null references auth.users);
      create table task_tag_links(task_id uuid references kanban_tasks on delete cascade,
        tag_id uuid references task_tags, primary key(task_id,tag_id));
      create table task_checklist_items(id uuid primary key default gen_random_uuid(),
        task_id uuid not null references kanban_tasks on delete cascade,
        title text not null, position integer not null, is_completed boolean not null,
        completed_at timestamptz, unique(task_id,position));
      create table task_activity_logs(id uuid primary key default gen_random_uuid(),
        task_id uuid references kanban_tasks on delete cascade, action text not null
        check(action in ('created','updated','tag_added','tag_removed','checklist_updated',
          'moved','completed','reopened','archived','restored','resumed','attachment_removed')),
        old_values jsonb not null, new_values jsonb not null, created_at timestamptz not null default now());
      create table task_attachments(id uuid primary key default gen_random_uuid(),
        task_id uuid references kanban_tasks on delete cascade, file_name text, storage_path text);
      grant select, insert, update, delete on all tables in schema public to authenticated;
      alter table projects enable row level security;
      create policy own on projects to authenticated using(owner_id=auth.uid()) with check(owner_id=auth.uid());
      alter table kanban_boards enable row level security;
      create policy own on kanban_boards to authenticated using(exists(select 1 from projects where id=project_id));
      alter table kanban_tasks enable row level security;
      create policy own on kanban_tasks to authenticated using(exists(select 1 from kanban_boards where id=board_id));
      alter table task_tags enable row level security;
      create policy own on task_tags to authenticated using(owner_id=auth.uid());
      alter table task_tag_links enable row level security;
      create policy own on task_tag_links to authenticated using(exists(select 1 from kanban_tasks where id=task_id)
        and exists(select 1 from task_tags where id=tag_id));
      alter table task_checklist_items enable row level security;
      create policy own on task_checklist_items to authenticated using(exists(select 1 from kanban_tasks where id=task_id));
      alter table task_activity_logs enable row level security;
      create policy own on task_activity_logs to authenticated using(exists(select 1 from kanban_tasks where id=task_id));
      insert into auth.users values ('${owner}'),('${other}');
      insert into profiles values ('${owner}'),('${other}');
      insert into task_tags values ('${tag}','${owner}'),('${foreignTag}','${other}');
      create function force_write_failure() returns trigger language plpgsql as $$
      begin
        if current_setting('test.fail_write',true) =
          (case tg_table_name when 'task_activity_logs' then to_jsonb(new)->>'action' else tg_table_name end) then
          raise exception 'forced late write failure';
        end if;
        return new;
      end $$;
      create trigger force_failure before insert on kanban_boards for each row execute function force_write_failure();
      create trigger force_failure before insert on task_checklist_items for each row execute function force_write_failure();
      create trigger force_failure before insert on task_activity_logs for each row execute function force_write_failure();
    `);
    for (const migration of [
      'atomic_kanban_writes', 'project_milestones', 'manual_project_milestones',
      'project_notification_stagnation', 'task_deadline_timezone', 'task_generated_deadline_malaysia',
      'task_time_tracking', 'task_meaningful_progress', 'task_write_consistency', 'atomic_project_and_task_actions',
    ]) {
      await db.exec(await readFile(new URL(`../migrations/${migration}.sql`, import.meta.url), 'utf8'));
    }
    const asUser = id => db.exec(`set role authenticated; set request.jwt.claim.sub='${id}'`);
    await asUser(owner);
    const query = async (sql, params) => (await db.query(sql, params)).rows;
    const snapshot = async () => Object.fromEntries(await Promise.all([
      'projects','kanban_boards','project_milestones','kanban_tasks','task_tag_links',
      'task_checklist_items','task_activity_logs','kanban_write_requests',
    ].map(async name => [name, await query(`select * from ${name} x order by to_jsonb(x)::text`)])));
    const fail = value => db.exec(`set test.fail_write='${value}'`);
    const checkRollback = async (point, write) => {
      const before = await snapshot();
      await fail(point);
      await assert.rejects(write(), /forced late write failure/);
      await fail('');
      assert.deepEqual(await snapshot(), before);
    };
    const save = async (request, name, tasks = null) => (await query(
      "select save_new_skilltrack_project($1,$2,'Build it','  Rules  ','2027-02-01','2027-02-28',$3::jsonb) result",
      [request, name, tasks == null ? null : JSON.stringify(tasks)]
    ))[0].result;
    const act = async (board, operation, id, payload) => (await query(
      'select save_skilltrack_task_action($1,$2,$3,$4::jsonb) result',
      [board, operation, id, JSON.stringify(payload)]
    ))[0].result.task;
    const version = task => ({ task_id: task.id, expected_updated_at: task.updated_at });

    let board, created;
    const shared = 'shared-operation-id-001';
    await t.test('empty project rolls back a late board error and replays its original IDs', async () => {
      const submit = () => save(shared, 'Empty');
      await checkRollback('kanban_boards', submit);
      // The JS callers overlap. PGlite executes their queries on one connection.
      const [first, duplicate] = await Promise.all([submit(), submit()]);
      assert.deepEqual(duplicate, first);
      assert.equal(first.project.owner_id, owner);
      assert.equal(first.project.constraints_text, 'Rules');
      assert.equal(first.total_task_count, 0);
      assert.equal((await query('select * from projects')).length, 1);
      assert.equal((await query('select * from kanban_boards')).length, 1);
      const before = await snapshot();
      assert.deepEqual(await submit(), first);
      await assert.rejects(save(shared, 'Changed'), {code:'22023'});
      assert.deepEqual(await snapshot(), before);
      board = first.board_id;
    });

    await t.test('initial AI confirmation rolls back its project and grouped batch together', async () => {
      const submit = () => save(shared, 'AI plan', plan);
      await checkRollback('task_checklist_items', submit);
      const first = await submit();
      const after = await snapshot();
      assert.deepEqual(await submit(), first);
      assert.deepEqual(await snapshot(), after);
      assert.equal(first.total_task_count, 2);
      assert.equal(after.projects.length, 2);
      assert.equal(after.kanban_boards.length, 2);
      assert.equal(after.project_milestones.length, 1);
      assert.equal(after.kanban_tasks.length, 2);
      assert.equal(after.task_checklist_items.length, 2);
      assert.ok(after.kanban_tasks.every(task => task.board_id === first.board_id &&
        task.milestone_id === after.project_milestones[0].id &&
        task.deadline.toISOString() === '2027-02-08T15:59:00.000Z'));
      await assert.rejects(save(shared, 'AI plan', [...plan, plan[0]]), {code:'22023'});
    });

    await t.test('manual task keeps timer, tags, checklist and activities in a single transaction', async () => {
      const submit = () => act(board, 'create_task', shared, fields);
      await checkRollback('task_checklist_items', submit);
      await assert.rejects(act(board, 'create_task', shared, {...fields, tag_ids:[foreignTag]}), {code:'42501'});
      created = await submit();
      assert.ok(created.tracking_started_at);
      assert.equal(created.status, 'in_progress');
      assert.equal(created.deadline_has_time, true);
      assert.equal(created.deadline, '2027-02-08T09:00:00+00:00');
      const after = await snapshot();
      assert.deepEqual(await submit(), created);
      assert.deepEqual(await snapshot(), after);
      assert.equal(after.task_tag_links.filter(link => link.task_id === created.id).length, 1);
      assert.equal(after.task_checklist_items.filter(item => item.task_id === created.id).length, 1);
      assert.deepEqual(after.task_activity_logs.filter(log => log.task_id === created.id)
        .map(log => log.action).sort(), ['checklist_updated','created','tag_added']);
      await assert.rejects(act(board, 'create_task', shared, {...fields, title:'Different'}), {code:'22023'});
    });

    await t.test('moving with normalization and completing are rollback-safe and replayable', async () => {
      await query(`insert into kanban_tasks(board_id,title,status,sort_order,priority)
        values ($1,'Left','completed',1000,'low'),($1,'Right','completed',1001,'low')`,[board]);
      const payload = {...version(created), status:'completed', expected_sort_order:created.sort_order, new_index:1};
      const submit = () => act(board,'move',shared,payload);
      await checkRollback('completed', submit);
      const moved = await submit();
      const after = await snapshot();
      assert.equal(moved.sort_order, 2000);
      assert.ok(moved.completed_at);
      assert.equal(moved.tracking_started_at, null);
      assert.deepEqual(after.kanban_tasks.filter(task => task.board_id === board)
        .map(task => task.sort_order).sort((a,b) => a-b), [1000,2000,3000]);
      assert.deepEqual(await submit(), moved);
      assert.deepEqual(await snapshot(), after);
      await assert.rejects(act(board,'move',shared,{...payload,new_index:0}), {code:'22023'});
      await assert.rejects(act(board,'move','new-stale-request-01',payload), {code:'40001'});
      const reopen = () => act(board,'move','reopen-request-0001',
        {...version(moved), status:'in_progress', expected_sort_order:moved.sort_order, new_index:0});
      await checkRollback('reopened', reopen);
      created = await reopen();
      assert.ok(created.tracking_started_at);
      assert.equal(created.completed_at, null);
      const reopened = await snapshot();
      assert.deepEqual(await reopen(), created);
      assert.deepEqual(await snapshot(), reopened);
    });

    await t.test('archive, restore and stalled resume each roll back and replay once', async () => {
      for (const [operation, action] of [['archive','archived'], ['restore','restored'], ['resume','resumed']]) {
        if (operation === 'resume') {
          await query("update kanban_tasks set is_stalled=true, stagnation_score=90, stalled_at=now() where id=$1",[created.id]);
        }
        const before = created;
        const submit = () => act(board,operation,shared,version(before));
        await checkRollback(action, submit);
        created = await submit();
        const after = await snapshot();
        assert.deepEqual(await submit(), created);
        await assert.rejects(act(board,operation,shared,version(created)), {code:'22023'});
        assert.deepEqual(await snapshot(), after);
        assert.equal(after.task_activity_logs.filter(log => log.task_id === created.id && log.action === action).length, 1);
        assert.equal(created.tracking_started_at, null);
        assert.equal(created.is_archived, operation === 'archive');
        if (operation === 'resume') {
          assert.equal(created.is_stalled,false);
          assert.equal(created.stagnation_score,0);
          assert.equal(created.stalled_at,null);
        }
      }
    });

    await t.test('users are isolated and an old receipt cannot recreate a deleted board', async () => {
      await asUser(other);
      assert.deepEqual(await query('select * from kanban_write_requests'), []);
      assert.equal((await query("select to_regclass('public.skilltrack_write_receipts') as table_name"))[0].table_name, null);
      await assert.rejects(act(board,'create_task',shared,fields), {code:'42501'});
      const otherProject = await save(shared,'Other user');
      assert.equal(otherProject.project.owner_id, other);
      assert.notEqual(otherProject.board_id, board);
      await asUser(owner);
      await query(`insert into kanban_write_requests(user_id,request_id,board_id,payload,saved_count)
        values ($1,$2,$3,'[]'::jsonb,0)`, [owner,shared,board]);
      assert.equal((await query('select board_id from kanban_write_requests where request_id=$1',[shared]))[0].board_id,board);
      await query("insert into task_attachments(task_id,file_name,storage_path) values ($1,'file.txt',$2)",
        [created.id,`${owner}/file.txt`]);
      await query('delete from kanban_boards where id=$1',[board]);
      assert.deepEqual(await query('select storage_path from task_attachment_cleanup'), [{storage_path:`${owner}/file.txt`}]);
      assert.deepEqual(await query('delete from task_attachment_cleanup returning storage_path'),
        [{storage_path:`${owner}/file.txt`}]);
      assert.deepEqual(await query('select request_id from kanban_write_requests where request_id=$1',[shared]), []);
      assert.equal((await query(
        "select board_id from kanban_write_requests where request_id=skilltrack_receipt_key('create_project',$1)", [shared]
      ))[0].board_id,null);
      await assert.rejects(save(shared,'Empty'), {code:'42501'});
    });
    await t.test('a prior draft receipt is reused without dropping its table', async () => {
      await db.exec(`reset role;
        create table skilltrack_write_receipts(
          user_id uuid, operation text, request_id text, board_id uuid, payload jsonb, result jsonb,
          primary key(user_id,operation,request_id));
      `);
      const [project] = await query(`insert into projects(owner_id,name,description,constraints_text,status,start_date,end_date)
        values ($1,'Earlier','Build it','Rules','active','2027-02-01','2027-02-28') returning to_jsonb(projects) as data`, [owner]);
      const [oldBoard] = await query("insert into kanban_boards(project_id,name) values ($1,'Kanban Board') returning id",
        [project.data.id]);
      const id = 'previous-draft-request-001';
      const payload = {name:'Earlier', description:'Build it', constraints:'  Rules  ',
        start_date:'2027-02-01', end_date:'2027-02-28', tasks:null};
      const result = {project:project.data, board_id:oldBoard.id, total_task_count:0};
      await query(`insert into skilltrack_write_receipts values ($1,'create_project',$2,$3,$4::jsonb,$5::jsonb)`,
        [owner,id,oldBoard.id,JSON.stringify(payload),JSON.stringify(result)]);
      const revised = await readFile(new URL('../migrations/atomic_project_and_task_actions.sql', import.meta.url), 'utf8');
      await db.exec(revised);
      await db.exec(revised);
      assert.equal((await query('select * from skilltrack_write_receipts')).length,1);
      await asUser(owner);
      const before = await snapshot();
      assert.deepEqual(await save(id,'Earlier'),result);
      assert.deepEqual(await snapshot(),before);
    });

    await t.test('replacement archives active tasks atomically and rejects stale or foreign confirmation', async () => {
      await db.exec('reset role');
      await db.exec(await readFile(new URL('../migrations/016_replace_generated_task_list.sql',import.meta.url),'utf8'));
      await asUser(owner);
      const fresh=await save('replacement-project-001','Replace me',plan);
      const target=fresh.board_id;
      const manual=await act(target,'create_task','replacement-manual-001',fields);
      const old=(await query('select * from kanban_tasks where board_id=$1',[target]));
      await act(target,'archive','replacement-archive-001',version(old[0]));
      await act(target,'move','replacement-complete-001',{...version(old[1]),expected_sort_order:old[1].sort_order,status:'completed'});
      const ctx=async()=> (await query('select task_list_replacement_context($1) result',[target]))[0].result;
      const baseline=await ctx();assert.equal(baseline.count,2);
      const submit=(id='replacement-confirm-001',v=baseline.version)=>query('select replace_generated_task_list($1,$2,$3,$4::jsonb) n',[target,id,v,JSON.stringify(plan)]);
      await checkRollback('archived',submit);
      await checkRollback('task_checklist_items',submit);
      await asUser(other);await assert.rejects(submit(),/access denied/);await asUser(owner);
      await query("update task_checklist_items set title=title||' changed' where task_id=$1",[manual.id]);
      await assert.rejects(submit(),/Board changed/);
      const current=await ctx();
      const [first,second]=await Promise.all([submit('replacement-confirm-002',current.version),submit('replacement-confirm-002',current.version)]);
      assert.equal(first[0].n,2);assert.deepEqual(first,second);
      const tasks=await query('select * from kanban_tasks where board_id=$1',[target]);
      assert.equal(tasks.filter(x=>!x.is_archived).length,2);
      assert.equal(tasks.filter(x=>x.is_archived).length,3);
      const archivedManual=tasks.find(x=>x.id===manual.id);assert.equal(archivedManual.tracking_started_at,null);
      assert.ok(archivedManual.elapsed_seconds>=manual.elapsed_seconds);
      assert.ok((await query('select * from task_checklist_items where task_id=$1',[manual.id])).length);
      assert.equal((await query("select * from task_activity_logs where task_id=$1 and action='archived'",[manual.id])).length,1);
      assert.equal((await query('select * from project_milestones where project_id=$1',[fresh.project.id])).length,1);
      await assert.rejects(submit('replacement-confirm-002','different-version'),/already used/);
    });
  } finally {
    await db.close();
  }
});
