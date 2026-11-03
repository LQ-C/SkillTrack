import assert from "node:assert/strict";
import test from "node:test";
import {
  generateNotifications,
  type NotificationInsert,
  type NotificationStore,
  type Preferences,
  type ProjectCandidate,
  type StagnationUpdate,
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
    task_created_at: "2026-10-01T12:00:00.000Z",
    deadline: null,
    last_activity_at: "2026-10-10T11:00:00.000Z",
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
  failStagnation = new Set<string>();
  states = new Map<string, {
    score: number;
    isStalled: boolean;
    stalledAt: string | null;
    checkedAt: number;
  }>();
  attempts: NotificationInsert[] = [];

  resume(taskId: string, at: Date) {
    const candidate = this.tasks.find((value) => value.task_id === taskId);
    assert.ok(candidate);
    candidate.last_activity_at = at.toISOString();
    this.states.set(taskId, {
      score: 0,
      isStalled: false,
      stalledAt: null,
      checkedAt: at.getTime(),
    });
  }

  async updateTaskStagnation(
    taskId: string,
    score: number,
    checkedAt: Date,
  ): Promise<StagnationUpdate> {
    if (this.failStagnation.has(taskId)) {
      throw new Error("stagnation write failure");
    }
    const candidate = this.tasks.find((value) => value.task_id === taskId);
    if (
      !candidate || candidate.task_archived || candidate.board_archived ||
      candidate.project_status !== "active" ||
      candidate.task_status === "completed"
    ) {
      throw new Error("Task is not eligible");
    }
    assert.ok(Number.isInteger(score) && score >= 0 && score <= 100);
    assert.ok(Number.isFinite(checkedAt.getTime()));
    const previous = this.states.get(taskId);
    if (
      new Date(candidate.last_activity_at!).getTime() >= checkedAt.getTime() ||
      (previous && previous.checkedAt > checkedAt.getTime())
    ) {
      throw new Error("Stale stagnation calculation");
    }
    const isStalled = score >= 70;
    const stalledAt = isStalled
      ? (previous?.isStalled ? previous.stalledAt : null) ??
        checkedAt.toISOString()
      : null;
    this.states.set(taskId, {
      score,
      isStalled,
      stalledAt,
      checkedAt: checkedAt.getTime(),
    });
    return {
      became_stalled: isStalled && !previous?.isStalled,
      currently_stalled: isStalled,
      current_stalled_at: stalledAt,
    };
  }

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
    this.attempts.push(value);
    if (this.failKeys.has(value.unique_key)) throw new Error("insert failure");
    const key = `${value.user_id}:${value.unique_key}`;
    if (this.seen.has(key)) return false;
    this.seen.add(key);
    this.saved.push(value);
    return true;
  }
}

test("in-progress task just below the dynamic threshold receives no stalled alert", async () => {
  const store = new FakeStore();
  store.tasks = [task({ last_activity_at: "2026-10-04T12:00:00.001Z" })];
  const result = await generateNotifications(store, now);
  assert.equal(result.failed, 0);
  assert.equal(store.states.get("task-1")?.score, 69);
  assert.equal(store.saved.length, 0);
});

test("in-progress task at the dynamic threshold receives one stalled alert", async () => {
  const store = new FakeStore();
  store.tasks = [task({ last_activity_at: "2026-10-04T12:00:00.000Z" })];
  const result = await generateNotifications(store, now);
  assert.equal(result.failed, 0);
  assert.equal(store.states.get("task-1")?.score, 70);
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
  const episode = store.states.get("task-1")?.stalledAt;
  assert.equal(episode, now.toISOString());
  const resumedAt = new Date("2026-10-10T13:00:00Z");
  store.resume("task-1", resumedAt);
  await generateNotifications(store, new Date("2026-10-10T14:00:00Z"));
  assert.equal(store.states.get("task-1")?.isStalled, false);
  assert.equal(store.states.get("task-1")?.stalledAt, null);
  assert.equal(store.saved.length, 1);
  await generateNotifications(store, new Date("2026-10-16T13:00:00Z"));
  assert.equal(store.saved.length, 2);
  assert.notEqual(store.saved[0].unique_key, store.saved[1].unique_key);
});

for (
  const [deadline, suffix, phrase] of [
    ["2026-10-13T09:00:00Z", "3-days", "in 3 days"],
    ["2026-10-11T09:00:00Z", "1-day", "tomorrow"],
    ["2026-10-10T09:00:00Z", "today", "today"],
  ]
) {
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
  assert.equal(store.states.get("task-1")?.isStalled, true);
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
  store.failKeys.add("stalled:a:2026-10-10T12:00:00.000Z");
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
  store.failKeys.add("stalled:task-1:2026-10-10T12:00:00.000Z");
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
    }));
  const result = await generateNotifications(store, now);
  assert.equal(result.tasksChecked, 101);
  assert.equal(store.saved.length, 1);
  assert.equal(store.saved[0].task_id, "task-100");
});

test("same key is unique per user and orphan profiles are skipped", async () => {
  const store = new FakeStore();
  store.tasks = [
    task({ user_id: "user-1", last_activity_at: "2026-10-03T12:00:00Z" }),
    task({
      task_id: "task-2",
      user_id: "user-2",
      last_activity_at: "2026-10-03T12:00:00Z",
    }),
    task({
      task_id: "orphan-task",
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
  assert.equal(store.saved.length, 1);
  assert.deepEqual(store.saved.map((value) => value.type), ["STALLED_TASK"]);
});

test("notification keys are scoped per user", async () => {
  const store = new FakeStore();
  store.tasks = [task({ last_activity_at: "2026-10-03T12:00:00Z" })];
  await generateNotifications(store, now);
  const alert = store.saved[0];
  assert.equal(await store.insert(alert), false);
  assert.equal(await store.insert({ ...alert, user_id: "user-2" }), true);
  assert.equal(await store.insert({ ...alert, user_id: "user-2" }), false);
  assert.equal(store.saved.length, 2);
});

test("a stalled insert failure retries the same persisted episode", async () => {
  const store = new FakeStore();
  store.tasks = [task({ last_activity_at: "2026-10-03T12:00:00Z" })];
  const key = `stalled:task-1:${now.toISOString()}`;
  store.failKeys.add(key);
  assert.equal((await generateNotifications(store, now)).failed, 1);
  assert.equal(store.saved.length, 0);
  assert.equal(store.states.get("task-1")?.stalledAt, now.toISOString());
  store.failKeys.clear();
  const later = new Date("2026-10-10T13:00:00Z");
  assert.equal((await generateNotifications(store, later)).created, 1);
  assert.equal(store.saved[0].unique_key, key);
  assert.equal((await generateNotifications(store, later)).duplicates, 1);
  assert.equal(store.saved.length, 1);
});

test("stagnation RPC failure preserves deadlines and subsequent task processing", async () => {
  const store = new FakeStore();
  store.tasks = [
    task({ task_id: "failed", deadline: "2026-10-13" }),
    task({ task_id: "next", last_activity_at: "2026-10-03T12:00:00Z" }),
  ];
  store.failStagnation.add("failed");
  const result = await generateNotifications(store, now);
  assert.equal(result.failed, 1);
  assert.deepEqual(store.saved.map((value) => [value.task_id, value.type]), [
    ["failed", "DEADLINE_REMINDER"],
    ["next", "STALLED_TASK"],
  ]);
});

test("short-duration overdue task uses its dynamic allowance", async () => {
  const store = new FakeStore();
  store.tasks = [task({
    task_created_at: "2026-10-09T12:00:00Z",
    last_activity_at: "2026-10-09T18:00:00Z",
    deadline: "2026-10-10T11:00:00Z",
  })];
  const result = await generateNotifications(store, now);
  assert.equal(result.failed, 0);
  assert.equal(store.states.get("task-1")?.score, 72);
  assert.equal(
    store.saved.filter((value) => value.type === "STALLED_TASK").length,
    1,
  );
});

test("a recent resume on an overdue task does not immediately stall it", async () => {
  const store = new FakeStore();
  store.tasks = [task({
    task_created_at: "2026-10-09T12:00:00Z",
    deadline: "2026-10-10T11:00:00Z",
  })];
  store.resume("task-1", new Date("2026-10-10T11:59:00Z"));
  const result = await generateNotifications(store, now);
  assert.equal(result.failed, 0);
  assert.equal(store.states.get("task-1")?.score, 20);
  assert.equal(store.states.get("task-1")?.isStalled, false);
  assert.equal(
    store.saved.filter((value) => value.type === "STALLED_TASK").length,
    0,
  );
});

test("To-Do without a deadline reaches the threshold at seven inactive days", async () => {
  const store = new FakeStore();
  store.tasks = [
    task({ task_status: "todo", last_activity_at: "2026-10-03T12:00:00.001Z" }),
  ];
  await generateNotifications(store, now);
  assert.equal(store.states.get("task-1")?.score, 69);
  assert.equal(store.saved.length, 0);
  await generateNotifications(store, new Date(now.getTime() + 1));
  assert.equal(store.states.get("task-1")?.score, 70);
  assert.equal(store.saved.length, 1);
});

for (
  const field of ["task_created_at", "last_activity_at", "deadline"] as const
) {
  test(`invalid ${field} does not persist a fabricated stagnation score`, async () => {
    const store = new FakeStore();
    store.tasks = [task({
      [field]: "not-a-date",
      deadline: "2026-10-13",
      ...(
        field === "deadline" ? { deadline: "not-a-date" } : {}
      ),
    })];
    const result = await generateNotifications(store, now);
    assert.equal(result.failed, 1);
    assert.equal(store.states.size, 0);
    assert.equal(
      store.saved.filter((value) => value.type === "STALLED_TASK").length,
      0,
    );
    assert.equal(store.saved.length, field === "deadline" ? 0 : 1);
  });
}

test("new activity clears persisted stalled state before a later episode", async () => {
  const store = new FakeStore();
  store.tasks = [task({ last_activity_at: "2026-10-03T12:00:00Z" })];
  await generateNotifications(store, now);
  store.tasks[0].last_activity_at = "2026-10-10T12:30:00Z";
  await generateNotifications(store, new Date("2026-10-10T13:00:00Z"));
  assert.equal(store.states.get("task-1")?.isStalled, false);
  assert.equal(store.states.get("task-1")?.stalledAt, null);
  await generateNotifications(store, new Date("2026-10-16T12:30:00Z"));
  assert.equal(store.saved.length, 2);
  assert.notEqual(store.saved[0].unique_key, store.saved[1].unique_key);
});

test("recommendation preference does not gate real task alerts", async () => {
  const store = new FakeStore();
  store.settings.set("user-1", { ...enabled, recommendation_enabled: false });
  store.tasks = [
    task({ last_activity_at: "2026-10-03T12:00:00Z", deadline: "2026-10-13" }),
  ];
  const result = await generateNotifications(store, now);
  assert.equal(result.failed, 0);
  assert.deepEqual(store.saved.map((value) => value.type), [
    "STALLED_TASK",
    "DEADLINE_REMINDER",
  ]);
});

test("missing project and task profiles are skipped before preference or state writes", async () => {
  const store = new FakeStore();
  store.projects = [project({ profile_exists: false })];
  store.tasks = [task({ profile_exists: false })];
  const result = await generateNotifications(store, now);
  assert.equal(result.missingProfiles, 2);
  assert.equal(result.failed, 0);
  assert.equal(store.states.size, 0);
  assert.equal(store.attempts.length, 0);
});

test("null creation timestamp is rejected rather than coerced to 1970", async () => {
  const store = new FakeStore();
  const candidate = task();
  Reflect.set(candidate, "task_created_at", null);
  store.tasks = [candidate];
  const result = await generateNotifications(store, now);
  assert.equal(result.failed, 1);
  assert.equal(store.states.size, 0);
  assert.equal(store.saved.length, 0);
});

test("date-only deadlines omit invented clock times and retain deduplication", async () => {
  const store = new FakeStore();
  store.tasks = [
    task({ deadline: "2026-10-13T15:59:59.999Z", deadline_has_time: false }),
  ];
  const first = await generateNotifications(store, now);
  assert.equal(first.failed, 0);
  assert.equal(store.saved.length, 1);
  assert.match(store.saved[0].message, /due in 3 days\.$/);
  assert.ok(!store.saved[0].message.includes(" at "));
  assert.equal((await generateNotifications(store, now)).duplicates, 1);
});

test("explicit Malaysia midnight includes its clock time", async () => {
  const store = new FakeStore();
  store.tasks = [
    task({ deadline: "2026-10-12T16:00:00Z", deadline_has_time: true }),
  ];
  await generateNotifications(store, now);
  assert.match(store.saved[0].message, /in 3 days at 12:00 AM\.$/);
});

for (const metadata of [null, undefined]) {
  test(`legacy deadline metadata ${metadata} preserves existing timed reminder keys`, async () => {
    const store = new FakeStore();
    store.tasks = [
      task({ deadline: "2026-10-13T00:00:00Z", deadline_has_time: metadata }),
    ];
    await generateNotifications(store, now);
    assert.match(store.saved[0].message, /at 8:00 AM\.$/);
    assert.equal(
      store.saved[0].unique_key,
      "task-deadline:task-1:2026-10-13T00:00:00.000Z:3-days",
    );
  });
}

test("legacy date-only candidate strings do not invent an 8 AM deadline", async () => {
  const store = new FakeStore();
  store.tasks = [task({ deadline: "2026-10-13" })];
  await generateNotifications(store, now);
  assert.match(store.saved[0].message, /due in 3 days\.$/);
});

test("Malaysia midnight selects today independently of UTC date", async () => {
  const store = new FakeStore();
  store.tasks = [
    task({ deadline: "2026-10-12T16:00:00Z", deadline_has_time: true }),
  ];
  await generateNotifications(store, new Date("2026-10-12T15:59:59Z"));
  assert.match(store.saved[0].message, /tomorrow at 12:00 AM\.$/);
  await generateNotifications(store, new Date("2026-10-12T16:00:00Z"));
  assert.match(store.saved[1].message, /today at 12:00 AM\.$/);
});
