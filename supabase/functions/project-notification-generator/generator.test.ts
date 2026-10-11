import assert from "node:assert/strict";
import test from "node:test";
import {
  generateNotifications,
  type NotificationInsert,
  type NotificationStore,
  type Preferences,
  type ProjectCandidate,
  type TaskCandidate,
} from "./generator.ts";

const now = new Date("2026-10-10T12:00:00.000Z");
const enabled: Preferences = {
  stalled_task_enabled: true,
  deadline_reminder_enabled: true,
  recommendation_enabled: true,
};

function task(overrides: Partial<TaskCandidate> = {}): TaskCandidate {
  return {
    task_id: "task-1",
    board_id: "board-1",
    project_id: "project-1",
    user_id: "user-1",
    task_title: "Study",
    task_status: "in_progress",
    task_archived: false,
    board_archived: false,
    project_status: "active",
    profile_exists: true,
    deadline: null,
    last_activity_at: "2026-10-04T12:00:00.000Z",
    ...overrides,
  };
}

function project(overrides: Partial<ProjectCandidate> = {}): ProjectCandidate {
  return {
    project_id: "project-1",
    user_id: "user-1",
    project_name: "Learn Flutter",
    end_date: "2026-10-13",
    project_status: "active",
    profile_exists: true,
    ...overrides,
  };
}

class FakeStore implements NotificationStore {
  projects: ProjectCandidate[] = [];
  tasks: TaskCandidate[] = [];
  saved: NotificationInsert[] = [];
  settings = new Map<string, Preferences>();
  failKeys = new Set<string>();
  seen = new Set<string>();

  async listProjects(offset: number, limit: number) {
    return this.projects.slice(offset, offset + limit);
  }
  async listTasks(offset: number, limit: number) {
    return this.tasks.slice(offset, offset + limit);
  }
  async getPreferences(userId: string) {
    return this.settings.get(userId) ?? enabled;
  }
  async insert(value: NotificationInsert) {
    if (this.failKeys.has(value.unique_key)) throw new Error("insert failure");
    const key = `${value.user_id}:${value.unique_key}`;
    if (this.seen.has(key)) return false;
    this.seen.add(key);
    this.saved.push(value);
    return true;
  }
}

test("task inactive fewer than seven days receives no stalled alert", async () => {
  const store = new FakeStore();
  store.tasks = [task()];
  await generateNotifications(store, now);
  assert.equal(store.saved.length, 0);
});

test("task inactive for seven days receives one stalled alert", async () => {
  const store = new FakeStore();
  store.tasks = [task({ last_activity_at: "2026-10-03T12:00:00.000Z" })];
  await generateNotifications(store, now);
  assert.equal(store.saved.length, 1);
  assert.equal(store.saved[0].type, "STALLED_TASK");
  assert.equal(store.saved[0].context_type, "TASK");
  assert.equal(store.saved[0].user_id, "user-1");
  assert.equal(store.saved[0].project_id, "project-1");
  assert.equal(store.saved[0].board_id, "board-1");
  assert.equal(store.saved[0].task_id, "task-1");
});

test("completed, archived, and archived-board tasks receive no alerts", async () => {
  const store = new FakeStore();
  store.tasks = [
    task({
      task_id: "completed",
      task_status: "completed",
      deadline: "2026-10-13",
      last_activity_at: "2026-10-01T00:00:00Z",
    }),
    task({
      task_id: "archived",
      task_archived: true,
      deadline: "2026-10-13",
      last_activity_at: "2026-10-01T00:00:00Z",
    }),
    task({
      task_id: "board-archived",
      board_archived: true,
      deadline: "2026-10-13",
      last_activity_at: "2026-10-01T00:00:00Z",
    }),
  ];
  await generateNotifications(store, now);
  assert.equal(store.saved.length, 0);
});

test("rerun is duplicate-safe and later activity starts a new stall period", async () => {
  const store = new FakeStore();
  store.tasks = [task({ last_activity_at: "2026-10-03T12:00:00Z" })];
  await generateNotifications(store, now);
  const second = await generateNotifications(store, now);
  assert.equal(second.duplicates, 1);
  assert.equal(store.saved.length, 1);
  store.tasks[0].last_activity_at = "2026-10-04T12:00:00Z";
  await generateNotifications(store, new Date("2026-10-11T12:00:00Z"));
  assert.equal(store.saved.length, 2);
  assert.notEqual(store.saved[0].unique_key, store.saved[1].unique_key);
});

for (const [deadline, suffix, phrase] of [
  ["2026-10-13T09:00:00Z", "3-days", "in 3 days"],
  ["2026-10-11T09:00:00Z", "1-day", "tomorrow"],
  ["2026-10-10T09:00:00Z", "today", "today"],
]) {
  test(`task deadline ${suffix} generates the correct reminder`, async () => {
    const store = new FakeStore();
    store.tasks = [task({ deadline })];
    await generateNotifications(store, now);
    assert.equal(store.saved.length, 1);
    assert.equal(store.saved[0].type, "DEADLINE_REMINDER");
    assert.ok(store.saved[0].unique_key.endsWith(`:${suffix}`));
    assert.ok(store.saved[0].message.includes(`due ${phrase}`));
  });
}

test("changing a deadline creates a new unique reminder schedule", async () => {
  const store = new FakeStore();
  store.tasks = [task({ deadline: "2026-10-13T09:00:00Z" })];
  await generateNotifications(store, now);
  store.tasks[0].deadline = "2026-10-13T10:00:00Z";
  await generateNotifications(store, now);
  assert.equal(store.saved.length, 2);
});

test("project deadline uses project context and has no task or board", async () => {
  const store = new FakeStore();
  store.projects = [project()];
  await generateNotifications(store, now);
  assert.deepEqual(
    store.saved.map((value) => [
      value.type,
      value.context_type,
      value.board_id,
      value.task_id,
    ]),
    [["DEADLINE_REMINDER", "PROJECT", null, null]],
  );
});

test("completed or archived projects receive no reminder", async () => {
  const store = new FakeStore();
  store.projects = [
    project({ project_status: "completed" }),
    project({ project_id: "archived", project_status: "archived" }),
  ];
  await generateNotifications(store, now);
  assert.equal(store.saved.length, 0);
});

test("disabled preferences stop only their corresponding alerts", async () => {
  const store = new FakeStore();
  store.projects = [project()];
  store.tasks = [
    task({ deadline: "2026-10-13", last_activity_at: "2026-10-03T12:00:00Z" }),
  ];
  store.settings.set("user-1", { ...enabled, stalled_task_enabled: false });
  await generateNotifications(store, now);
  assert.equal(store.saved.length, 2);
  assert.ok(store.saved.every((value) => value.type === "DEADLINE_REMINDER"));
  store.saved = [];
  store.seen.clear();
  store.settings.set("user-1", {
    ...enabled,
    deadline_reminder_enabled: false,
  });
  await generateNotifications(store, now);
  assert.equal(store.saved.length, 1);
  assert.equal(store.saved[0].type, "STALLED_TASK");
});

test("one failed record does not stop the next task", async () => {
  const store = new FakeStore();
  store.tasks = [
    task({ task_id: "a", last_activity_at: "2026-10-03T12:00:00Z" }),
    task({ task_id: "b", last_activity_at: "2026-10-03T12:00:00Z" }),
  ];
  store.failKeys.add("stalled:a:2026-10-03T12:00:00.000Z");
  const result = await generateNotifications(store, now);
  assert.equal(result.failed, 1);
  assert.equal(store.saved.length, 1);
  assert.equal(store.saved[0].task_id, "b");
});

test("a failed stalled insert does not suppress that task deadline", async () => {
  const store = new FakeStore();
  store.tasks = [
    task({ deadline: "2026-10-13", last_activity_at: "2026-10-03T12:00:00Z" }),
  ];
  store.failKeys.add("stalled:task-1:2026-10-03T12:00:00.000Z");
  const result = await generateNotifications(store, now);
  assert.equal(result.failed, 1);
  assert.equal(store.saved.length, 1);
  assert.equal(store.saved[0].type, "DEADLINE_REMINDER");
});

test("candidate pagination processes records after the first page", async () => {
  const store = new FakeStore();
  store.tasks = Array.from({ length: 101 }, (_, index) =>
    task({
      task_id: `task-${index}`,
      deadline: index === 100 ? "2026-10-13" : null,
    }),
  );
  const result = await generateNotifications(store, now);
  assert.equal(result.tasksChecked, 101);
  assert.equal(store.saved.length, 1);
  assert.equal(store.saved[0].task_id, "task-100");
});

test("same key is unique per user and orphan profiles are skipped", async () => {
  const store = new FakeStore();
  store.tasks = [
    task({ user_id: "user-1", last_activity_at: "2026-10-03T12:00:00Z" }),
    task({ user_id: "user-2", last_activity_at: "2026-10-03T12:00:00Z" }),
    task({
      user_id: "orphan",
      profile_exists: false,
      last_activity_at: "2026-10-03T12:00:00Z",
    }),
  ];
  const result = await generateNotifications(store, now);
  assert.equal(store.saved.length, 2);
  assert.deepEqual(
    store.saved.map((value) => value.user_id),
    ["user-1", "user-2"],
  );
  assert.equal(result.missingProfiles, 1);
});

test("no recommendation is generated without a real resource source", async () => {
  const store = new FakeStore();
  store.tasks = [task({ last_activity_at: "2026-10-03T12:00:00Z" })];
  await generateNotifications(store, now);
  assert.ok(
    store.saved.every(
      (value) => value.type !== "LEARNING_RESOURCE_RECOMMENDATION",
    ),
  );
});
