// Runs in isolated embedded PostgreSQL; never connects to live Supabase.
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { test } from "node:test";
import { generateNotifications } from "../functions/project-notification-generator/generator.ts";
const { PGlite } = await import(
  process.env.PGLITE_MODULE || "@electric-sql/pglite"
);
const migration = await readFile(
  new URL("../migrations/task_meaningful_progress.sql", import.meta.url),
  "utf8",
);
const oldTimezone = await readFile(
  new URL("../migrations/task_deadline_timezone.sql", import.meta.url),
  "utf8",
);
const candidate = oldTimezone.slice(
  oldTimezone.indexOf("create function public.notification_task_candidates("),
  oldTimezone.indexOf(
    "\n$$;",
    oldTimezone.indexOf("create function public.notification_task_candidates("),
  ) + 4,
);
const original = await readFile(
  new URL("../migrations/project_notification_generator.sql", import.meta.url),
  "utf8",
);
const enqueue = original.slice(
  original.indexOf(
    "create or replace function public.enqueue_app_notification(",
  ),
  original.indexOf(
    "revoke all on function public.notification_project_candidates",
  ),
);
const user = "10000000-0000-0000-0000-000000000001",
  otherUser = "10000000-0000-0000-0000-000000000002";
const project = "20000000-0000-0000-0000-000000000001",
  otherProject = "20000000-0000-0000-0000-000000000002";
const board = "30000000-0000-0000-0000-000000000001",
  otherBoard = "30000000-0000-0000-0000-000000000002";
const task = "40000000-0000-0000-0000-000000000001",
  otherTask = "40000000-0000-0000-0000-000000000002";
const item = "50000000-0000-0000-0000-000000000001";
for (const type of ["smallint", "integer"]) {
  test(`meaningful progress with preserved ${type} monitoring contract`, async (t) => {
    const db = new PGlite();
    const q = async (sql, args = []) => (await db.query(sql, args)).rows;
    const baseline = async () =>
      (await q("select task_progress_at($1) as at", [task]))[0].at
        .toISOString();
    const state = async () =>
      (await q("select * from kanban_tasks where id=$1", [task]))[0];
    const monitor = async (score = 70, at = "2026-10-10T12:00:00Z") =>
      (await q("select * from update_task_stagnation($1,$2,$3)", [
        task,
        score,
        at,
      ]))[0];
    const auth = () =>
      db.exec(
        `set local role authenticated; set local request.jwt.claim.sub='${user}'`,
      );
    const log = (action, old = {}, next = {}, at = null) =>
      q(
        `insert into task_activity_logs(task_id,action,old_values,new_values,created_at)
    values($1,$2,$3::jsonb,$4::jsonb,coalesce($5::timestamptz,clock_timestamp())) returning *`,
        [task, action, JSON.stringify(old), JSON.stringify(next), at],
      );
    const progress = (
      text = "Implemented the API",
      request = "progress-request-0001",
      id = task,
    ) =>
      q("select * from add_task_progress_update($1,$2,$3)", [
        id,
        request,
        text,
      ]);
    const checklist = (completed, title = "Read docs") =>
      q("select * from update_task_checklist_item($1,$2,0,$3)", [
        item,
        title,
        completed,
      ]);
    const tx = async (name, fn) =>
      t.test(name, async () => {
        await db.exec("begin");
        try {
          await fn();
        } finally {
          await db.exec("rollback");
        }
      });
    try {
      await db.exec(`
      create role anon;create role authenticated;create role service_role bypassrls;create schema auth;
      create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;
      grant usage on schema auth,public to authenticated,service_role,anon;
      create table profiles(id uuid primary key);
      create table projects(id uuid primary key,owner_id uuid,name text,status text,end_date date);
      create table kanban_boards(id uuid primary key,project_id uuid references projects,is_archived boolean default false);
      create table kanban_tasks(id uuid primary key,board_id uuid references kanban_boards,title text,status text,priority text,
        description text,sort_order bigint default 0,milestone_id uuid,deadline timestamptz,deadline_has_time boolean,
        created_at timestamptz not null,updated_at timestamptz not null,is_archived boolean default false,
        stagnation_score ${type} default 0,is_stalled boolean default false,stalled_at timestamptz,stagnation_checked_at timestamptz,
        elapsed_seconds bigint default 0,tracking_started_at timestamptz);
      create table task_activity_logs(id uuid primary key default gen_random_uuid(),task_id uuid references kanban_tasks,
        action varchar not null check(action in ('created','updated','moved','completed','reopened','resumed','archived','restored','tag_added','tag_removed','checklist_updated','attachment_added','attachment_removed')),
        old_values jsonb default '{}',new_values jsonb default '{}',created_at timestamptz not null default now());
      create table task_checklist_items(id uuid primary key,task_id uuid references kanban_tasks,title text,position integer,
        is_completed boolean default false,completed_at timestamptz,
        check ((is_completed and completed_at is not null) or (not is_completed and completed_at is null)));
      create table kanban_write_requests(user_id uuid,request_id text,board_id uuid,payload jsonb,saved_count integer,created_at timestamptz default now(),primary key(user_id,request_id));
      create table notifications(user_id uuid,type text,context_type text,project_id uuid,board_id uuid,task_id uuid,title text,message text,action_data jsonb,unique_key text);
      create unique index notifications_user_unique_key_idx on notifications(user_id,unique_key) where unique_key is not null;
      insert into profiles values('${user}'),('${otherUser}');
      insert into projects values('${project}','${user}','Learn','active',null),('${otherProject}','${otherUser}','Other','active',null);
      insert into kanban_boards(id,project_id) values('${board}','${project}'),('${otherBoard}','${otherProject}');
      insert into kanban_tasks(id,board_id,title,status,created_at,updated_at) values
        ('${task}','${board}','Study','in_progress','2026-10-01T12:00:00Z','2026-11-03T12:00:00Z'),
        ('${otherTask}','${otherBoard}','Foreign','completed','2026-10-01T12:00:00Z','2026-10-01T12:00:00Z');
      insert into task_checklist_items(id,task_id,title,position) values('${item}','${task}','Read docs',0);
      create function assert_owned_kanban_board(p_board_id uuid) returns void language plpgsql security invoker as $$
      begin perform b.id from kanban_boards b join projects p on p.id=b.project_id where b.id=p_board_id
        and p.owner_id=auth.uid() and p.status<>'archived' and not b.is_archived for update of b;
        if not found then raise exception 'Project board unavailable' using errcode='42501';end if;end;$$;
      create function update_task_stagnation(p_task_id uuid,p_score ${type},p_checked_at timestamptz ${
        type === "smallint" ? "default now()" : ""
      })
        returns table(became_stalled boolean,currently_stalled boolean,current_stalled_at timestamptz)
        language plpgsql security invoker set search_path=public,pg_temp as $$
        declare previous boolean;next_stalled boolean;episode timestamptz;
        begin select is_stalled,stalled_at into previous,episode from kanban_tasks where id=p_task_id for update;
          next_stalled:=p_score>=70;if next_stalled and not previous then episode:=p_checked_at;elsif not next_stalled then episode:=null;end if;
          update kanban_tasks set stagnation_score=p_score,is_stalled=next_stalled,stalled_at=episode,stagnation_checked_at=p_checked_at where id=p_task_id;
          return query select next_stalled and not previous,next_stalled,episode;end;$$;
      revoke all on function update_task_stagnation(uuid,${type},timestamptz) from public;
      grant execute on function update_task_stagnation(uuid,${type},timestamptz) to service_role;
      grant select,update on kanban_tasks to authenticated;grant select on projects,kanban_boards,profiles to authenticated;grant update on kanban_boards to authenticated;
      grant select,insert,update on task_checklist_items to authenticated;grant select,insert on task_activity_logs,kanban_write_requests to authenticated;
      grant select on profiles,projects,kanban_boards,kanban_tasks,task_activity_logs,task_checklist_items to service_role;
      grant update on kanban_tasks to service_role;grant select,insert on notifications to service_role;
      alter table kanban_tasks enable row level security;
      create policy own_task on kanban_tasks to authenticated using(exists(select 1 from kanban_boards b join projects p on p.id=b.project_id where b.id=board_id and p.owner_id=auth.uid()));
      alter table task_activity_logs enable row level security;
      create policy own_activity on task_activity_logs to authenticated using(exists(select 1 from kanban_tasks t where t.id=task_id));
      alter table task_checklist_items enable row level security;
      create policy own_checklist on task_checklist_items to authenticated using(exists(select 1 from kanban_tasks t where t.id=task_id));
      alter table kanban_write_requests enable row level security;
      create policy own_receipt on kanban_write_requests to authenticated using(user_id=auth.uid()) with check(user_id=auth.uid());
    `);
      await db.exec(candidate);
      await db.exec(
        "revoke all on function notification_task_candidates(integer,integer) from public;grant execute on function notification_task_candidates(integer,integer) to service_role",
      );
      await db.exec(enqueue);
      const contract = (await q(
        `select oid,pg_get_function_arguments(oid) as args,pg_get_function_result(oid) as result,proacl::text as grants from pg_proc where oid='update_task_stagnation(uuid,${type},timestamptz)'::regprocedure`,
      ))[0];
      await db.exec(migration);
      assert.deepEqual(
        (await q(
          `select oid,pg_get_function_arguments(oid) as args,pg_get_function_result(oid) as result,proacl::text as grants from pg_proc where oid='update_task_stagnation(uuid,${type},timestamptz)'::regprocedure`,
        ))[0],
        contract,
      );

      await tx(
        "no meaningful history uses creation, never updated_at",
        async () => {
          assert.equal(await baseline(), "2026-10-01T12:00:00.000Z");
          const row =
            (await q("select * from notification_task_candidates(0,100)"))[0];
          assert.equal(
            new Date(row.last_activity_at).toISOString(),
            await baseline(),
          );
          assert.equal(Object.keys(row).length, 14);
        },
      );
      const ignored = [
        ["tag_added", {}, { tag_id: "tag" }],
        ["tag_removed", { tag_id: "tag" }, {}],
        ["updated", {}, {
          title: "Edited",
          description: "Changed",
          priority: "high",
          deadline: "2027-01-01",
          milestone_id: "group",
        }],
        ["moved", { status: "todo" }, { status: "todo" }],
        ["moved", { status: "in_progress" }, { status: "todo" }],
        ["checklist_updated", {}, {}],
        ["checklist_updated", {}, { change: "removed" }],
        ["checklist_updated", { is_completed: true }, { is_completed: false }],
        ["checklist_updated", { is_completed: true }, { is_completed: true }],
        ["checklist_updated", { is_completed: false }, {
          is_completed: false,
          title: "Edited",
        }],
        ["updated", {}, { change: "progress_update", progress_text: "   " }],
        ["updated", {}, {
          change: "progress_update",
          progress_text: "x".repeat(1001),
        }],
        ["attachment_added", {}, { file_name: "file" }],
        ["restored", {}, {}],
      ];
      for (const [action, old, next] of ignored) {
        await tx(
          `${action} ${JSON.stringify(next)} does not advance progress`,
          async () => {
            const before = await baseline();
            await log(action, old, next, "2026-11-03T15:00:00Z");
            assert.equal(await baseline(), before);
            assert.equal(
              (await q("select count(*) as n from task_activity_logs"))[0].n,
              1,
            );
            await monitor(); // Recent nonprogress history and generic updated_at do not stop a stall.
            assert.equal((await state()).is_stalled, true);
            assert.equal(await baseline(), before);
          },
        );
      }
      await tx(
        "metadata, order, tag creation/rename and timer ticks have no progress event",
        async () => {
          await q(
            `update kanban_tasks set title='New title',priority='high',description='Edited',sort_order=9000,
        deadline='2027-01-01',milestone_id=gen_random_uuid(),updated_at=clock_timestamp(),elapsed_seconds=100 where id=$1`,
            [task],
          );
          assert.equal(await baseline(), "2026-10-01T12:00:00.000Z");
          assert.equal((await monitor()).currently_stalled, true);
        },
      );
      await tx(
        "atomic checklist completion advances once; uncheck/edit/repeated complete do not",
        async () => {
          await monitor();
          await auth();
          const first = (await checklist(true))[0];
          const at = await baseline();
          assert.ok(new Date(at) > new Date("2026-11-01"));
          assert.equal(first.is_completed, true);
          assert.equal((await state()).is_stalled, false);
          assert.equal(
            (await q("select * from task_activity_logs"))[0].old_values
              .is_completed,
            false,
          );
          await checklist(true);
          assert.equal(await baseline(), at);
          assert.equal(
            (await q("select completed_at from task_checklist_items"))[0]
              .completed_at.toISOString(),
            first.completed_at.toISOString(),
          );
          await checklist(true, "Renamed");
          assert.equal(await baseline(), at);
          await checklist(false, "Renamed");
          assert.equal(await baseline(), at);
          await checklist(false, "Edited again");
          assert.equal(await baseline(), at);
          assert.equal(
            (await q("select count(*) as n from task_activity_logs"))[0].n,
            5,
          );
        },
      );
      await tx(
        "valid progress commits once, trims text and deduplicates lost-response retries",
        async () => {
          await auth();
          const row = (await progress("  Implemented API  "))[0];
          const at = await baseline();
          assert.equal(row.new_values.progress_text, "Implemented API");
          assert.equal(row.action, "updated");
          assert.equal(row.created_at.toISOString(), at);
          assert.equal((await progress("Implemented API"))[0].id, row.id);
          assert.equal(await baseline(), at);
          assert.equal(
            (await q("select count(*) as n from task_activity_logs"))[0].n,
            1,
          );
          assert.equal(
            (await q("select count(*) as n from kanban_write_requests"))[0].n,
            1,
          );
          await db.exec("savepoint invalid");
          await assert.rejects(progress("Different text"), /already used/);
          await db.exec("rollback to savepoint invalid");
          assert.equal(await baseline(), at);
        },
      );
      await tx(
        "empty, oversized and failed progress saves cannot advance or leave a partial log",
        async () => {
          await auth();
          const before = await baseline();
          for (const text of [null, "", " \n\t ", "x".repeat(1001)]) {
            await db.exec("savepoint invalid");
            await assert.rejects(progress(text), /progress update/);
            await db.exec("rollback to savepoint invalid");
            assert.equal(await baseline(), before);
          }
          await db.exec(
            "reset role;revoke insert on kanban_write_requests from authenticated;set local role authenticated;savepoint failure",
          );
          await assert.rejects(progress(), /permission denied/);
          await db.exec("rollback to savepoint failure");
          assert.equal(await baseline(), before);
          assert.equal(
            (await q("select count(*) as n from task_activity_logs"))[0].n,
            0,
          );
          await db.exec(
            "reset role;grant insert on kanban_write_requests to authenticated;set local role authenticated",
          );
          await progress();
          assert.notEqual(await baseline(), before);
        },
      );
      await tx(
        "resume and eligible workflow transitions start a fresh monitoring period",
        async () => {
          for (
            const [action, old, next] of [["resumed", {}, {}], ["moved", {
              status: "todo",
            }, { status: "in_progress" }], [
              "reopened",
              { status: "completed" },
              { status: "in_progress" },
            ], ["completed", {}, {}]]
          ) {
            const previous = await baseline();
            await log(action, old, next);
            assert.ok(new Date(await baseline()) > new Date(previous));
          }
        },
      );
      await tx(
        "historical payloads count only when they reliably prove progress",
        async () => {
          await db.exec(
            "alter table task_activity_logs disable trigger task_activity_meaningful_progress",
          );
          await log("checklist_updated", {}, {}, "2026-10-09T12:00:00Z");
          assert.equal(await baseline(), "2026-10-01T12:00:00.000Z");
          await log("checklist_updated", { is_completed: false }, {
            is_completed: true,
          }, "2026-10-03T12:00:00Z");
          assert.equal(await baseline(), "2026-10-03T12:00:00.000Z");
          await log("resumed", {}, {}, "2026-10-05T12:00:00Z");
          await log(
            "updated",
            {},
            { description: "Metadata" },
            "2026-10-09T12:00:00Z",
          );
          assert.equal(await baseline(), "2026-10-05T12:00:00.000Z");
        },
      );
      await tx(
        "older monitoring cannot overwrite progress; later inactivity gets a new episode",
        async () => {
          const first = await monitor();
          await log("resumed");
          const fresh = await state();
          assert.equal(fresh.is_stalled, false);
          assert.equal(fresh.stalled_at, null);
          await db.exec("savepoint stale");
          await assert.rejects(monitor(100), /Stale stagnation/);
          await db.exec("rollback to savepoint stale");
          assert.equal((await state()).is_stalled, false);
          const later = new Date(
            new Date(await baseline()).getTime() + 8 * 86400000,
          );
          const episode = await monitor(80, later);
          assert.notEqual(
            episode.current_stalled_at.toISOString(),
            first.current_stalled_at.toISOString(),
          );
          const repeated = await monitor(
            90,
            new Date(later.getTime() + 3600000),
          );
          assert.equal(
            repeated.current_stalled_at.toISOString(),
            episode.current_stalled_at.toISOString(),
          );
        },
      );
      await tx(
        "newer monitoring run fences older scores and threshold remains 70",
        async () => {
          assert.equal((await monitor(69)).currently_stalled, false);
          assert.equal((await monitor(70)).currently_stalled, true);
          await db.exec("savepoint stale");
          await assert.rejects(monitor(0, "2026-10-09"), /Stale/);
          await db.exec("rollback to savepoint stale");
          assert.equal((await state()).is_stalled, true);
        },
      );
      await tx(
        "ownership, archived project/board and server-only monitoring permissions",
        async () => {
          await auth();
          await db.exec("savepoint invalid");
          await assert.rejects(
            progress("Text", "foreign-request-0001", otherTask),
            /unavailable/,
          );
          await db.exec("rollback to savepoint invalid");
          await db.exec("savepoint invalid");
          await assert.rejects(monitor(), /permission denied/);
          await db.exec("rollback to savepoint invalid");
          await db.exec(
            `reset role;update projects set status='archived' where id='${project}';set local role authenticated;savepoint invalid`,
          );
          await assert.rejects(progress(), /unavailable/);
          await db.exec("rollback to savepoint invalid");
          await db.exec(
            `reset role;update projects set status='active' where id='${project}';update kanban_boards set is_archived=true where id='${board}';set local role authenticated;savepoint invalid`,
          );
          await assert.rejects(checklist(true), /unavailable/);
          await db.exec("rollback to savepoint invalid");
          assert.equal(await baseline(), "2026-10-01T12:00:00.000Z");
        },
      );
      await tx(
        "monitoring-only touch trigger writes cannot change baseline or updated_at",
        async () => {
          await db.exec(
            `create function touch_updated_at() returns trigger language plpgsql as $$begin new.updated_at=clock_timestamp();return new;end;$$;
        create trigger touch_updated_at before update on kanban_tasks for each row execute function touch_updated_at()`,
          );
          const before = await state();
          await monitor();
          assert.equal(
            (await state()).updated_at.toISOString(),
            before.updated_at.toISOString(),
          );
          assert.equal(await baseline(), "2026-10-01T12:00:00.000Z");
        },
      );
      await tx(
        "actual generator still sends deadline reminders and deduplicates stalled episodes",
        async () => {
          const now = new Date(Date.now() - 5000);
          await q(
            `update kanban_tasks set deadline=((clock_timestamp() at time zone 'Asia/Kuala_Lumpur')::date+1+time '12:00') at time zone 'Asia/Kuala_Lumpur' where id=$1`,
            [task],
          );
          let preferences = {
            stalled_task_enabled: true,
            deadline_reminder_enabled: true,
            recommendation_enabled: true,
          };
          let beforeMonitor = null;
          const store = {
            listProjects: async () => [],
            listTasks: async (offset, limit) =>
              q("select * from notification_task_candidates($1,$2)", [
                offset,
                limit,
              ]),
            getPreferences: async () => preferences,
            updateTaskStagnation: async (id, score, checked) => {
              if (beforeMonitor) {
                const action = beforeMonitor;
                beforeMonitor = null;
                await action();
              }
              // Each real PostgREST RPC is its own transaction. A savepoint isolates
              // its failure while this test keeps all fixtures inside an outer transaction.
              await db.exec("savepoint monitoring_rpc");
              try {
                const r =
                  (await q("select * from update_task_stagnation($1,$2,$3)", [
                    id,
                    score,
                    checked,
                  ]))[0];
                await db.exec("release savepoint monitoring_rpc");
                return {
                  ...r,
                  current_stalled_at: r.current_stalled_at?.toISOString() ??
                    null,
                };
              } catch (error) {
                await db.exec(
                  "rollback to savepoint monitoring_rpc;release savepoint monitoring_rpc",
                );
                throw error;
              }
            },
            insert: async (row) =>
              (await q("select enqueue_app_notification($1::jsonb) as ok", [
                JSON.stringify(row),
              ]))[0].ok,
          };
          await log("tag_added", {}, { tag_id: "tag" });
          const first = await generateNotifications(store, now);
          assert.equal(first.created, 2);
          assert.equal(first.failed, 0);
          assert.equal(
            (await generateNotifications(store, new Date(now.getTime() + 1000)))
              .duplicates,
            2,
          );
          await log("resumed");
          assert.equal((await state()).is_stalled, false);
          const resumed = await generateNotifications(
            store,
            new Date(Date.now() + 1000),
          );
          assert.equal(resumed.created, 0);
          assert.equal((await state()).stagnation_score < 70, true);
          const later = await generateNotifications(
            store,
            new Date(Date.now() + 8 * 86400000),
          );
          assert.equal(later.created, 1);
          assert.equal(
            (await q("select * from notifications where type='STALLED_TASK'"))
              .length,
            2,
          );
          // A real stale-calculation conflict must not suppress the independent deadline path.
          await db.exec("delete from notifications");
          beforeMonitor = () => log("resumed");
          const stale = await generateNotifications(
            store,
            new Date(Date.now() - 1000),
          );
          assert.equal(stale.failed, 1);
          assert.equal(stale.created, 1);
          assert.equal(
            (await q("select type from notifications"))[0].type,
            "DEADLINE_REMINDER",
          );
          await db.exec("delete from notifications");
          preferences = { ...preferences, stalled_task_enabled: false };
          assert.equal(
            (await generateNotifications(store, new Date(Date.now() + 1000)))
              .created,
            1,
          );
        },
      );
      await t.test("migration rerun preserves history and the installed signature without extra overloads", async () => {
        await log("tag_added", {}, { tag_id: "persisted" });
        const snapshot = await q("select * from task_activity_logs");
        await db.exec(migration);
        assert.deepEqual(await q("select * from task_activity_logs"), snapshot);
        assert.equal(
          (await q(
            "select count(*) as n from pg_proc where proname='update_task_stagnation'",
          ))[0].n,
          1,
        );
        assert.equal(
          (await q(
            `select pg_get_function_arguments('update_task_stagnation(uuid,${type},timestamptz)'::regprocedure) as args`,
          ))[0].args,
          contract.args,
        );
      });
      await t.test("unknown monitoring overload aborts without changing existing definitions or history", async () => {
        const before = (await q(
          `select pg_get_functiondef('update_task_stagnation(uuid,${type},timestamptz)'::regprocedure) as body`,
        ))[0].body;
        const history = await q("select * from task_activity_logs");
        await db.exec(
          "create function update_task_stagnation(uuid,numeric,timestamptz) returns void language sql as $$select$$",
        );
        await assert.rejects(db.exec(migration), /Expected one/);
        await db.exec("rollback");
        assert.equal(
          (await q(
            `select pg_get_functiondef('update_task_stagnation(uuid,${type},timestamptz)'::regprocedure) as body`,
          ))[0].body,
          before,
        );
        assert.deepEqual(await q("select * from task_activity_logs"), history);
      });
    } finally {
      await db.close();
    }
  });
}
