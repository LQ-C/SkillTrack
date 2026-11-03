// Test-only embedded PostgreSQL; never connects to live Supabase.
// PGLITE_MODULE may point to a temporary @electric-sql/pglite installation.
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { test } from "node:test";
import { generateNotifications } from "../functions/project-notification-generator/generator.ts";
const { PGlite } = await import(
  process.env.PGLITE_MODULE || "@electric-sql/pglite"
);
const user = "10000000-0000-0000-0000-000000000001";
const otherUser = "10000000-0000-0000-0000-000000000002";
const project = "20000000-0000-0000-0000-000000000001";
const board = "30000000-0000-0000-0000-000000000001";
const task = "40000000-0000-0000-0000-000000000001";
const otherTask = "40000000-0000-0000-0000-000000000002";
const now = new Date("2026-10-10T12:00:00Z");
const migration = await readFile(
  new URL("../migrations/project_notification_stagnation.sql", import.meta.url),
  "utf8",
);
const original = await readFile(
  new URL("../migrations/project_notification_generator.sql", import.meta.url),
  "utf8",
);
const candidateSql = original.slice(
  original.indexOf("create function public.notification_task_candidates("),
  original.indexOf("-- The partial unique index"),
);
const enqueueSql = original.slice(
  original.indexOf(
    "create or replace function public.enqueue_app_notification(",
  ),
  original.indexOf(
    "revoke all on function public.notification_project_candidates",
  ),
);

test("notification stagnation migration and generator in local PostgreSQL", async (t) => {
  const db = new PGlite();
  const query = async (sql, params = []) => (await db.query(sql, params)).rows;
  const state = async () =>
    (await query("select * from kanban_tasks where id=$1", [task]))[0];
  const update = async (score, checkedAt = now, id = task) =>
    (await query(
      "select * from update_task_stagnation($1,$2,$3)",
      [id, score, checkedAt],
    ))[0];
  const reset = async () => {
    await db.exec(
      `reset role; truncate task_activity_logs, kanban_tasks, notifications;
      insert into kanban_tasks(id,board_id,title,status,created_at,updated_at)
      values ('${task}','${board}','Study','in_progress','2026-10-01T12:00:00Z','2026-10-04T12:00:00Z'),
        ('${otherTask}','${board}','Other','todo','2026-10-01T12:00:00Z','2026-10-10T11:00:00Z');`,
    );
  };
  try {
    await db.exec(
      `create role anon; create role authenticated; create role service_role bypassrls;
      create table profiles(id uuid primary key);
      create table projects(id uuid primary key,owner_id uuid,name text,status text,end_date date);
      create table kanban_boards(id uuid primary key,project_id uuid references projects,is_archived boolean default false);
      create table kanban_tasks(id uuid primary key,board_id uuid references kanban_boards,title text,status text,
        is_archived boolean default false,created_at timestamptz,updated_at timestamptz,deadline timestamptz,
        elapsed_seconds bigint default 0,tracking_started_at timestamptz);
      create table task_activity_logs(task_id uuid references kanban_tasks,created_at timestamptz,action text);
      create table notifications(user_id uuid,type text,context_type text,project_id uuid,board_id uuid,task_id uuid,
        title text,message text,action_data jsonb,unique_key text);
      create unique index notifications_user_unique_key_idx on notifications(user_id,unique_key) where unique_key is not null;
      create function touch_task_updated_at() returns trigger language plpgsql as $$
        begin new.updated_at = '2026-10-10T13:00:00Z'; return new; end $$;
      create trigger touch_task_updated_at before update on kanban_tasks for each row execute function touch_task_updated_at();
      grant usage on schema public to service_role,authenticated,anon;
      alter table kanban_tasks enable row level security;
      grant select,update on kanban_tasks to service_role;
      grant select on profiles,projects,kanban_boards,task_activity_logs to service_role;
      grant select,insert on notifications to service_role;
      insert into profiles values ('${user}'),('${otherUser}');
      insert into projects values ('${project}','${user}','Learn','active',null);
      insert into kanban_boards(id,project_id) values ('${board}','${project}');
      create function notification_task_candidates(integer,integer) returns table(task_id uuid)
        language sql as $$ select id from kanban_tasks $$;`,
    );
    await db.exec(migration);
    await db.exec(enqueueSql);
    await db.exec(
      "grant execute on function enqueue_app_notification(jsonb) to service_role",
    );
    await reset();

    await t.test("candidate SQL returns creation and derived activity timestamps; both migrations agree", async () => {
      const first =
        (await query("select * from notification_task_candidates(0,100)"))[0];
      assert.equal(
        new Date(first.task_created_at).toISOString(),
        "2026-10-01T12:00:00.000Z",
      );
      assert.equal(
        new Date(first.last_activity_at).toISOString(),
        "2026-10-04T12:00:00.000Z",
      );
      await db.exec(
        "drop function notification_task_candidates(integer,integer)",
      );
      await db.exec(candidateSql);
      assert.deepEqual(
        (await query("select * from notification_task_candidates(0,100)"))[0],
        first,
      );
      await db.exec(migration);
    });
    await t.test("69 stays active; 70 starts an episode and updates only the intended task", async () => {
      assert.deepEqual(await update(69), {
        became_stalled: false,
        currently_stalled: false,
        current_stalled_at: null,
      });
      const result = await update(70);
      assert.equal(result.became_stalled, true);
      assert.equal(result.currently_stalled, true);
      assert.equal(
        new Date(result.current_stalled_at).toISOString(),
        now.toISOString(),
      );
      const row = await state();
      assert.equal(row.stagnation_score, 70);
      assert.equal(row.is_stalled, true);
      assert.equal(row.updated_at.toISOString(), "2026-10-04T12:00:00.000Z");
      assert.equal(
        (await query("select stagnation_score from kanban_tasks where id=$1", [
          otherTask,
        ]))[0].stagnation_score,
        0,
      );
      assert.equal(row.deadline, null);
      assert.equal(row.elapsed_seconds, 0);
      assert.equal(row.status, "in_progress");
    });
    await t.test("same episode preserves stalled_at; lower score clears it; later episode is new", async () => {
      const later = new Date("2026-10-10T13:00:00Z");
      const same = await update(80, later);
      assert.equal(same.became_stalled, false);
      assert.equal(same.current_stalled_at.toISOString(), now.toISOString());
      assert.equal((await update(20, later)).current_stalled_at, null);
      assert.equal((await state()).is_stalled, false);
      const next = await update(70, new Date("2026-10-16T12:00:00Z"));
      assert.equal(next.became_stalled, true);
      assert.notEqual(next.current_stalled_at.toISOString(), now.toISOString());
    });
    await t.test("newer check, resume timestamp and activity log each reject stale calculations", async () => {
      await assert.rejects(update(99, now), /Stale stagnation/);
      await reset();
      // Reproduce Resume Task without changing its existing implementation.
      await db.exec(
        `update kanban_tasks set is_stalled=false,stagnation_score=0,stalled_at=null where id='${task}';`,
      );
      assert.ok((await state()).updated_at > now);
      await assert.rejects(update(99), /Stale stagnation/);
      assert.equal((await state()).stagnation_score, 0);
      await reset();
      await query("insert into task_activity_logs values($1,$2,'resumed')", [
        task,
        "2026-10-10T12:01:00Z",
      ]);
      await assert.rejects(update(99), /Stale stagnation/);
      assert.equal((await state()).stagnation_score, 0);
    });
    await t.test("normal Resume Task writes still update activity and start a new episode later", async () => {
      await reset();
      await update(70);
      await db.exec(`drop trigger touch_task_updated_at on kanban_tasks;
        update kanban_tasks set is_stalled=false,stagnation_score=0,stalled_at=null,
          updated_at='2026-10-10T13:00:00Z' where id='${task}';
        insert into task_activity_logs values('${task}','2026-10-10T13:00:00Z','resumed');
        create trigger touch_task_updated_at before update on kanban_tasks for each row execute function touch_task_updated_at();`);
      assert.equal(
        (await state()).updated_at.toISOString(),
        "2026-10-10T13:00:00.000Z",
      );
      const next = await update(70, new Date("2026-10-16T13:00:00Z"));
      assert.equal(next.became_stalled, true);
      assert.equal(
        next.current_stalled_at.toISOString(),
        "2026-10-16T13:00:00.000Z",
      );
    });
    await t.test("missing, completed and archived tasks cannot be updated", async () => {
      await reset();
      await assert.rejects(
        update(70, now, "40000000-0000-0000-0000-000000000099"),
        /not eligible/,
      );
      for (const assignment of ["status='completed'", "is_archived=true"]) {
        await reset();
        await db.exec(
          `update kanban_tasks set ${assignment} where id='${task}'`,
        );
        await assert.rejects(update(70), /not eligible/);
      }
      await reset();
      await db.exec(
        `update kanban_boards set is_archived=true where id='${board}'`,
      );
      await assert.rejects(update(70), /not eligible/);
      assert.equal(
        (await query(
          "select count(*)::int as n from notification_task_candidates(0,100)",
        ))[0].n,
        0,
      );
      await db.exec(
        `update kanban_boards set is_archived=false where id='${board}'`,
      );
    });
    await t.test("invalid scores and timestamps do not write state", async () => {
      await reset();
      for (const score of [-1, 101, null]) {
        await assert.rejects(update(score), /Invalid stagnation/);
      }
      await assert.rejects(update(70, "infinity"), /Invalid stagnation/);
      await assert.rejects(update(70, null), /Invalid stagnation/);
      assert.equal((await state()).stagnation_checked_at, null);
    });
    await t.test("only service_role can invoke the RPC; it retains SECURITY INVOKER", async () => {
      await reset();
      for (const role of ["anon", "authenticated"]) {
        await db.exec(`set role ${role}`);
        await assert.rejects(update(70), /permission denied/);
        await db.exec("reset role");
      }
      await db.exec("set role service_role");
      assert.equal((await update(70)).currently_stalled, true);
      await db.exec("reset role");
      assert.equal(
        (await query(
          "select prosecdef from pg_proc where oid='update_task_stagnation(uuid,integer,timestamptz)'::regprocedure",
        ))[0].prosecdef,
        false,
      );
    });
    await t.test("database duplicate keys are scoped per user", async () => {
      const insert = async (userId) =>
        (await query("select enqueue_app_notification($1::jsonb) as inserted", [
          JSON.stringify({
            user_id: userId,
            type: "STALLED_TASK",
            context_type: "TASK",
            project_id: project,
            board_id: board,
            task_id: task,
            title: "Test",
            message: "Test",
            unique_key: "same-key",
          }),
        ]))[0].inserted;
      assert.equal(await insert(user), true);
      assert.equal(await insert(user), false);
      assert.equal(await insert(otherUser), true);
      assert.equal(await insert(otherUser), false);
    });
    await t.test("actual generator and RPC preserve retry identity and deadline reminders", async () => {
      await reset();
      await db.exec(
        `alter table kanban_tasks disable trigger touch_task_updated_at;
        update kanban_tasks set deadline='2026-10-13T09:00:00Z' where id='${task}';
        alter table kanban_tasks enable trigger touch_task_updated_at;`,
      );
      let failInsert = true;
      const store = {
        listProjects: async () => [],
        listTasks: async (offset, limit) =>
          query("select * from notification_task_candidates($1,$2)", [
            offset,
            limit,
          ]),
        getPreferences: async () => ({
          stalled_task_enabled: true,
          deadline_reminder_enabled: true,
          recommendation_enabled: true,
        }),
        updateTaskStagnation: async (id, score, checkedAt) => {
          const result = await update(score, checkedAt, id);
          return {
            ...result,
            current_stalled_at: result.current_stalled_at?.toISOString() ??
              null,
          };
        },
        insert: async (value) => {
          if (failInsert && value.type === "STALLED_TASK") {
            throw new Error("temporary insert failure");
          }
          return (await query(
            "select enqueue_app_notification($1::jsonb) as inserted",
            [JSON.stringify(value)],
          ))[0].inserted;
        },
      };
      assert.equal((await generateNotifications(store, now)).failed, 1);
      assert.equal((await query("select * from notifications")).length, 1);
      assert.equal((await state()).stalled_at.toISOString(), now.toISOString());
      failInsert = false;
      const retry = await generateNotifications(
        store,
        new Date("2026-10-10T13:00:00Z"),
      );
      assert.equal(retry.created, 1);
      assert.equal(retry.duplicates, 1);
      assert.equal((await query("select * from notifications")).length, 2);
      assert.equal((await state()).stalled_at.toISOString(), now.toISOString());
      assert.equal(
        (await generateNotifications(store, new Date("2026-10-10T14:00:00Z")))
          .duplicates,
        2,
      );
      await reset();
      await db.exec(
        `update kanban_tasks set deadline='2026-10-13T09:00:00Z' where id='${task}'`,
      );
      const stale = await generateNotifications(store, now);
      assert.equal(stale.failed, 1);
      assert.equal(stale.created, 1);
      assert.equal(
        (await query("select type from notifications"))[0].type,
        "DEADLINE_REMINDER",
      );
      assert.equal((await state()).stagnation_score, 0);
    });
    await t.test("incompatible live overload aborts migration without replacing objects", async () => {
      await db.exec(
        "create function update_task_stagnation(uuid,numeric,timestamptz) returns void language sql as $$ select $$",
      );
      await assert.rejects(db.exec(migration), /Inspect installed/);
      await db.exec("rollback");
      await db.exec(
        "drop function update_task_stagnation(uuid,numeric,timestamptz)",
      );
    });
    await t.test("unknown activity-writing triggers fail safely and roll back", async () => {
      await reset();
      await db.exec(
        `create function log_all_updates() returns trigger language plpgsql as $$
        begin insert into task_activity_logs values(new.id,'2026-10-10T13:00:00Z','updated'); return new; end $$;
        create trigger log_all_updates after update on kanban_tasks for each row execute function log_all_updates();`,
      );
      await assert.rejects(update(70), /inspect task triggers/);
      assert.equal((await state()).is_stalled, false);
      assert.equal((await query("select * from task_activity_logs")).length, 0);
    });
  } finally {
    await db.close();
  }
});
