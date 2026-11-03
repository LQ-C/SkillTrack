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
      create role authenticated; create role anon; create role service_role bypassrls; create schema auth;
      create table profiles(id uuid primary key);
      create table auth.users(id uuid primary key);
      create function auth.uid() returns uuid language sql stable as
        $auth$ select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $auth$;
      grant usage on schema auth, public to authenticated;
      grant execute on function auth.uid() to authenticated;
      create table projects(id uuid primary key, owner_id uuid references auth.users, status text default 'active');
      create table kanban_boards(id uuid primary key, project_id uuid references projects on delete cascade, is_archived boolean default false);
      create table kanban_tasks(id uuid primary key default gen_random_uuid(), board_id uuid references kanban_boards on delete cascade,
        title text, description text, priority text, status text default 'todo', deadline timestamptz, sort_order bigint default 0,
        is_archived boolean default false, created_at timestamptz default now(), updated_at timestamptz default now(),
        elapsed_seconds bigint default 0, tracking_started_at timestamptz);
      create table task_checklist_items(id uuid primary key default gen_random_uuid(), task_id uuid references kanban_tasks on delete cascade,
        title text, position integer, is_completed boolean);
      create table task_activity_logs(id uuid primary key default gen_random_uuid(), task_id uuid references kanban_tasks on delete cascade,
        action text, old_values jsonb, new_values jsonb, created_at timestamptz default now());
      create table task_attachments(id uuid primary key default gen_random_uuid(), task_id uuid references kanban_tasks on delete cascade,
        file_name text, storage_path text, mime_type text, file_size_bytes bigint);
      insert into auth.users values ('${user}'), ('${otherUser}');
      insert into profiles values ('${user}'), ('${otherUser}');
      grant usage on schema public to service_role;
      grant select on profiles,projects,kanban_boards,kanban_tasks,task_activity_logs to service_role;
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
    const generatedDeadlineSql = await readFile(new URL('../migrations/task_generated_deadline_malaysia.sql', import.meta.url), 'utf8');
    const timezoneSql = await readFile(new URL('../migrations/task_deadline_timezone.sql', import.meta.url), 'utf8');
    const manualSql = await readFile(new URL('../migrations/manual_project_milestones.sql', import.meta.url), 'utf8');
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
    await db.exec(timezoneSql);
    await t.test('upgrade preserves historical deadlines, receipts, function contracts and grants', async () => {
      // Seed saves using the previous definitions to reproduce completed requests.
      const cases = [
        {fn:'save_generated_tasks', id:'pre-upgrade-flat-001', draft:task('Before flat')},
        {fn:'save_generated_tasks_with_milestones', id:'pre-upgrade-group01', draft:task('Before grouped',milestone('before'))},
      ];
      await db.exec(`grant execute on function save_generated_tasks(uuid,text,jsonb), save_generated_tasks_with_milestones(uuid,text,jsonb) to service_role;
        set role authenticated; set request.jwt.claim.sub='${user}';`);
      for (const item of cases) {
        item.draft.deadline='2026-11-10';
        const result=await db.query(`select ${item.fn}($1,$2,$3::jsonb) as count`,[board,item.id,JSON.stringify([item.draft])]);
        assert.equal(result.rows[0].count,1);
      }
      // Include a legacy 08:00 Malaysia deadline plus both types of manual deadline.
      await db.query(`insert into kanban_tasks(board_id,title,deadline,deadline_has_time) values
        ($1,'Historical midnight UTC','2026-11-10T00:00:00Z',null),
        ($1,'Manual explicit time','2026-11-10T06:30:00Z',true),
        ($1,'Manual date only','2026-11-10T15:59:59.999Z',false)`,[board]);
      const snapshot=async()=>({
        tasks:(await db.query('select * from kanban_tasks order by id')).rows,
        receipts:(await db.query('select * from kanban_write_requests order by request_id')).rows,
        milestones:(await db.query('select * from project_milestones order by id')).rows,
        checklist:(await db.query('select * from task_checklist_items order by id')).rows,
        activity:(await db.query('select * from task_activity_logs order by id')).rows,
      });
      const contracts=async()=>(await db.query(`select oid,proname,proowner,proacl::text,
        prosecdef,proconfig,pg_get_function_result(oid) as result,prosrc
        from pg_proc where oid in ('public.save_generated_tasks(uuid,text,jsonb)'::regprocedure,
          'public.save_generated_tasks_with_milestones(uuid,text,jsonb)'::regprocedure)
        order by proname`)).rows;
      const before=await snapshot();
      const beforeContracts=await contracts();
      await db.exec('reset role');
      await db.exec(generatedDeadlineSql);
      await db.exec(generatedDeadlineSql);
      assert.deepEqual(await snapshot(),before);
      const afterContracts=await contracts();
      for (let index=0;index<beforeContracts.length;index++) {
        const {prosrc:oldBody,...oldContract}=beforeContracts[index];
        const {prosrc:newBody,...newContract}=afterContracts[index];
        assert.deepEqual(newContract,oldContract);
        assert.equal(newBody.replace(/\r\n/g,'\n'),oldBody.replace(/\r\n/g,'\n').replace(
          "(((draft->>'deadline')::date + 1)::timestamp at time zone 'Asia/Kuala_Lumpur') - interval '1 millisecond'",
          "(((draft->>'deadline')::date + time '23:59:00') at time zone 'Asia/Kuala_Lumpur')"));
      }
      await db.exec('set role authenticated');
      for (const zone of ['UTC','America/Los_Angeles']) {
        await db.query("select set_config('TimeZone',$1,false)",[zone]);
        for (const item of cases) {
          assert.equal((await db.query(`select ${item.fn}($1,$2,$3::jsonb) as count`,[board,item.id,JSON.stringify([item.draft])])).rows[0].count,1);
        }
        assert.deepEqual(await snapshot(),before);
      }
      await db.exec("reset role; set timezone='UTC'; delete from kanban_tasks; delete from project_milestones; delete from kanban_write_requests;");
    });
    await db.exec(generatedDeadlineSql);
    await db.exec(manualSql);
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


    const manual = (request, title, boardId = board) => db.query(
      'select * from create_project_milestone($1,$2,$3)', [boardId,request,title]);
    await t.test('manual create trims names, allocates server order and retries the same row', async () => {
      await db.exec('begin');
      try {
        const before = await counts();
        const created = (await manual('manual-request-0001', '  Manual group  ')).rows[0];
        assert.equal(created.project_id,project);
        assert.equal(created.title,'Manual group');
        assert.equal(created.position,1);
        assert.deepEqual((await manual('manual-request-0001','Manual group')).rows[0],created);
        assert.equal(Number((await counts()).milestones),Number(before.milestones)+1);
        assert.equal(Number((await counts()).receipts),Number(before.receipts)+1);
        assert.equal((await manual('manual-request-0002','Next')).rows[0].position,2);
        assert.equal((await counts()).tasks,before.tasks);
      } finally { await db.exec('rollback'); }
    });
    await t.test('manual input boundaries and RPC permissions are enforced', async () => {
      for (const title of [null,'','   ','\t\n','x'.repeat(151)]) {
        const before = await counts();
        await assert.rejects(manual('manual-invalid-0001',title),/Invalid milestone request/);
        assert.deepEqual(await counts(),before);
      }
      for (const request of [null,'short','x'.repeat(129)]) {
        await assert.rejects(manual(request,'Valid'),/Invalid milestone request/);
      }
      await db.exec('begin');
      try {
        assert.equal((await manual('manual-boundary-001',' '+ 'x'.repeat(150)+' ')).rows[0].title.length,150);
        assert.equal((await manual('manual-unicode-0001','😀'.repeat(150))).rows[0].title.length,300);
        const signature='public.create_project_milestone(uuid,text,text)';
        assert.equal((await db.query('select prosecdef from pg_proc where oid=$1::regprocedure',[signature])).rows[0].prosecdef,false);
        for (const role of ['anon','public']) {
          assert.equal((await db.query("select has_function_privilege($1,$2,'EXECUTE') as allowed",[role,signature])).rows[0].allowed,false);
        }
      } finally { await db.exec('rollback'); }
    });
    await t.test('manual retries reject changed payloads and cross-operation ID reuse', async () => {
      await db.exec('begin');
      try {
        await manual('manual-payload-0001','Original');
        const before = await counts();
        // Each rejection is its own transaction so the outer setup is preserved.
        for (const attempt of [
          () => manual('manual-payload-0001','Changed'),
          () => save('manual-payload-0001',[task('AI')]),
        ]) {
          await db.exec('savepoint attempt');
          await assert.rejects(attempt(),/already used/);
          await db.exec('rollback to savepoint attempt');
        }
        assert.deepEqual(await counts(),before);
        await save('ai-payload-0000001',[task('AI')]);
        await db.exec('savepoint attempt');
        await assert.rejects(manual('ai-payload-0000001','Manual'),/already used/);
        await db.exec('rollback to savepoint attempt');
      } finally { await db.exec('rollback'); }
    });
    await t.test('manual creates reject archived boards/projects, missing boards and foreign ownership', async () => {
      await assert.rejects(manual('missing-board-00001','Valid','99999999-0000-0000-0000-000000000000'),/unavailable/);
      for (const update of [
        `update kanban_boards set is_archived=true where id='${board}'`,
        `update projects set status='archived' where id='${project}'`,
      ]) {
        await db.exec('begin');
        await db.exec(update);
        await db.exec('savepoint attempt');
        await assert.rejects(manual('archived-request-01','Valid'),/unavailable/);
        await db.exec('rollback');
      }
      await db.exec('begin');
      try {
        await db.exec(`set request.jwt.claim.sub='${otherUser}'`);
        await db.exec('savepoint attempt');
        await assert.rejects(manual('foreign-request-001','Valid'),/unavailable/);
        await db.exec('rollback to savepoint attempt');
        await db.exec(`set request.jwt.claim.sub=''`);
        await db.exec('savepoint attempt');
        await assert.rejects(manual('signedout-request-1','Valid'),/Sign in/);
      } finally { await db.exec('rollback'); }
    });
    await t.test('manual and AI saves share project ordering across boards; receipts are per user', async () => {
      await db.exec('begin');
      try {
        const secondBoard='30000000-0000-0000-0000-000000000002';
        const foreignBoard='30000000-0000-0000-0000-000000000003';
        await db.exec('reset role');
        await db.query('insert into kanban_boards(id,project_id) values($1,$2),($3,$4)',[secondBoard,project,foreignBoard,foreignProject]);
        await db.exec('set role authenticated');
        const a=(await manual('shared-request-0001','Manual A')).rows[0];
        const b=(await manual('shared-request-0002','Manual B',secondBoard)).rows[0];
        assert.equal(b.position,a.position+1);
        await db.exec('savepoint attempt');
        await assert.rejects(manual('shared-request-0001','Manual A',secondBoard),/already used/);
        await db.exec('rollback to savepoint attempt');
        await save('ordered-ai-request01',[task('AI group',milestone('ordered-ai'))]);
        const ai=(await db.query("select position from project_milestones where title='Build' and project_id=$1",[project])).rows[0];
        assert.equal(ai.position,b.position+1);
        const c=(await manual('shared-request-0003','Manual C')).rows[0];
        assert.equal(c.position,ai.position+1);
        await db.exec(`set request.jwt.claim.sub='${otherUser}'`);
        const foreign=(await manual('shared-request-0001','Other user',foreignBoard)).rows[0];
        assert.equal(foreign.project_id,foreignProject);
        assert.notEqual(foreign.id,a.id);
      } finally { await db.exec('rollback'); }
    });
    await t.test('receipt failure rolls back the milestone and permits successful retry', async () => {
      await db.exec('begin');
      try {
        await db.exec('reset role');
        await db.exec('revoke insert on kanban_write_requests from authenticated');
        await db.exec('set role authenticated');
        await db.exec('savepoint attempt');
        const before = await counts();
        await assert.rejects(manual('receipt-retry-00001','Retry me'),/permission denied/);
        await db.exec('rollback to savepoint attempt');
        assert.deepEqual(await counts(),before);
        await db.exec('reset role');
        await db.exec('grant insert on kanban_write_requests to authenticated');
        await db.exec('set role authenticated');
        const result=await manual('receipt-retry-00001','Retry me');
        assert.equal(result.rows.length,1);
        assert.equal(Number((await counts()).milestones),Number(before.milestones)+1);
      } finally { await db.exec('rollback'); }
    });
    await t.test('manual migration reruns preserve data and existing AI function definitions', async () => {
      const created=(await manual('rerun-manual-00001','Retained')).rows[0];
      const before=await counts();
      const definition=(await db.query("select pg_get_functiondef('public.save_generated_tasks_with_milestones(uuid,text,jsonb)'::regprocedure) as body")).rows[0].body;
      await db.exec('reset role');
      await db.exec(manualSql);
      assert.equal((await db.query("select pg_get_functiondef('public.save_generated_tasks_with_milestones(uuid,text,jsonb)'::regprocedure) as body")).rows[0].body,definition);
      await db.exec('set role authenticated');
      assert.deepEqual(await counts(),before);
      assert.equal((await manual('rerun-manual-00001','Retained')).rows[0].id,created.id);
      // Keep the pre-existing regression fixtures unchanged for subsequent tests.
      await db.exec('reset role');
      await db.query('delete from kanban_write_requests where request_id=$1',['rerun-manual-00001']);
      await db.query('delete from project_milestones where id=$1',[created.id]);
      await db.exec('set role authenticated');
    });

    for (const legacy of [true,false]) {
      for (const zone of ['UTC','Asia/Kuala_Lumpur','America/Los_Angeles']) {
        for (const date of ['2026-11-10','2026-11-30','2026-12-31','2028-02-29']) {
          await t.test(`${legacy ? 'flat' : 'milestone'} deadline ${date} is 23:59 Malaysia in ${zone}`,async()=>{
            await db.exec('begin');
            try {
              await db.query("select set_config('TimeZone',$1,true)",[zone]);
              const input={...task('Confirmed draft',legacy ? null : milestone('date-matrix')),deadline:date};
              const request=`date-matrix-${legacy}-${zone}-${date}`;
              assert.equal((await save(request,[input],legacy)).rows[0].count,1);
              const row=(await db.query(`select deadline,deadline_has_time,milestone_id,
                to_char(deadline at time zone 'Asia/Kuala_Lumpur','YYYY-MM-DD HH24:MI:SS.US') as malaysia
                from kanban_tasks where title=$1`,[input.title])).rows[0];
              assert.equal(row.deadline.toISOString(),`${date}T15:59:00.000Z`);
              assert.equal(row.malaysia,`${date} 23:59:00.000000`);
              assert.equal(row.deadline_has_time,false);
              assert.equal(row.milestone_id===null,legacy);
              if (!legacy) {
                const savedMilestone=(await db.query('select project_id from project_milestones where id=$1',[row.milestone_id])).rows[0];
                assert.equal(savedMilestone.project_id,project);
              }
              assert.equal(Number((await db.query('select count(*) as n from task_checklist_items')).rows[0].n),2);
              assert.equal((await db.query('select action from task_activity_logs')).rows[0].action,'created');
              const before=await counts();
              assert.equal((await save(request,[input],legacy)).rows[0].count,1);
              assert.deepEqual(await counts(),before);
              assert.equal((await db.query('select deadline from kanban_tasks')).rows[0].deadline.toISOString(),`${date}T15:59:00.000Z`);
            } finally { await db.exec('rollback'); }
          });
        }
      }
    }
    await t.test('both latest RPCs reject times and invalid dates atomically', async()=>{
      for (const legacy of [true,false]) {
        for (const deadline of ['2026-02-30','2026-11-10T23:59:00+08:00']) {
          const before=await counts();
          const valid=task('Must roll back',legacy ? null : milestone('invalid-rollback'));
          const invalid={...task('Invalid deadline'),deadline};
          await assert.rejects(save(`invalid-date-${legacy}-${deadline}`,[valid,invalid],legacy),
            /Invalid generated task|date\/time field value out of range/);
          assert.deepEqual(await counts(),before);
        }
      }
    });

    await t.test('date-only RPCs use Malaysia day end under multiple session timezones', async () => {
      for (const zone of ['UTC', 'Asia/Kuala_Lumpur', 'America/Los_Angeles']) {
        await db.exec('begin');
        try {
          await db.exec(`set local timezone='${zone}'`);
          for (const legacy of [true,false]) {
            const title=`Timezone ${zone} ${legacy}`;
            const input=task(title,legacy ? null : milestone('tz-group'));
            assert.equal((await save(`timezone-request-${zone}-${legacy}`,[input],legacy)).rows[0].count,1);
            const row=(await db.query('select deadline,deadline_has_time,milestone_id from kanban_tasks where title=$1',[title])).rows[0];
            assert.equal(row.deadline.toISOString(),'2026-12-01T15:59:00.000Z');
            assert.equal(row.deadline_has_time,false);
            assert.equal(row.milestone_id===null,legacy);
            const before=await counts();
            assert.equal((await save(`timezone-request-${zone}-${legacy}`,[input],legacy)).rows[0].count,1);
            assert.deepEqual(await counts(),before);
          }
          await db.exec('set local role service_role');
          const rows=(await db.query('select * from notification_task_candidates(0,100)')).rows;
          assert.equal(rows.length,2);
          assert.ok(rows.every(row=>row.deadline_has_time===false && row.task_created_at));
        } finally { await db.exec('rollback'); }
      }
    });
    await t.test('migration rerun leaves historical timestamps and unknown intent unchanged', async () => {
      const id=(await db.query(`insert into kanban_tasks(board_id,title,deadline) values($1,'Historical','2026-11-02T00:30:00Z') returning id`,[board])).rows[0].id;
      const before=(await db.query('select * from kanban_tasks where id=$1',[id])).rows[0];
      assert.equal(before.deadline_has_time,null);
      await db.exec('reset role');
      await db.exec(timezoneSql);
      await db.exec(generatedDeadlineSql);
      await db.exec('set role authenticated');
      assert.deepEqual((await db.query('select * from kanban_tasks where id=$1',[id])).rows[0],before);
      await db.query('delete from kanban_tasks where id=$1',[id]);
    });
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
      await db.exec(timezoneSql);
      await db.exec(generatedDeadlineSql);
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
