import assert from "node:assert/strict";
import {
  createStalledAlertDelivery,
  ScheduledRecommendationStore,
  type StalledAlertBackend,
} from "./recommendations.ts";
import type { Preferences, TaskCandidate } from "./generator.ts";
const preferences: Preferences = {
  stalled_task_enabled: true,
  recommendation_enabled: true,
  deadline_reminder_enabled: true,
};
const task = { task_id: "task", user_id: "owner" } as TaskCandidate;
const relevant = {
  resourceId: "resource",
  resourceVersion: "v1",
  taskVersion: "t1",
};
function fixture() {
  let eligible = true,
    matches: typeof relevant | null = relevant,
    fail = false,
    matchCalls = 0,
    lost = false;
  const saved = new Map<string, string>();
  const backend: StalledAlertBackend = {
    state: (t, e) =>
      Promise.resolve(
        !eligible
          ? "ineligible"
          : saved.has(`${t.user_id}:${t.task_id}:${e}`)
          ? "handled"
          : "eligible",
      ),
    match: (_t, timeout) => {
      matchCalls++;
      assert.ok(timeout > 0 && timeout <= 5000);
      if (fail) throw Error("inference");
      return Promise.resolve(matches);
    },
    commit: (t, e, m) => {
      const key = `${t.user_id}:${t.task_id}:${e}`;
      if (!eligible || saved.has(key)) return Promise.resolve(false);
      saved.set(key, m ? "recommendation" : "stalled");
      if (lost) {
        lost = false;
        throw Error("lost response");
      }
      return Promise.resolve(true);
    },
  };
  return {
    backend,
    saved,
    delivery: createStalledAlertDelivery(backend),
    calls: () => matchCalls,
    fail: () => fail = true,
    empty: () => matches = null,
    resume: () => eligible = false,
    lostResponse: () => lost = true,
  };
}
Deno.test("relevant accessible match wins; repeated run and lost response never create fallback too", async () => {
  const f = fixture();
  f.lostResponse();
  await f.delivery(task, "episode1", preferences);
  await f.delivery(task, "episode1", preferences);
  assert.deepEqual([...f.saved.values()], ["recommendation"]);
  assert.equal(f.calls(), 1);
  await f.delivery(task, "episode2", preferences);
  assert.equal(f.saved.size, 2);
});
Deno.test("empty or unavailable recommendations preserve ordinary stalled fallback", async () => {
  for (const failure of [false, true]) {
    const f = fixture();
    if (failure) f.fail();
    else f.empty();
    await f.delivery(task, "episode", preferences);
    assert.deepEqual([...f.saved.values()], ["stalled"]);
    await f.delivery(task, "episode", preferences);
    assert.equal(f.calls(), 1);
  }
});
Deno.test("disabled recommendation preference skips inference independently of stalled preference", async () => {
  const f = fixture();
  await f.delivery(task, "episode", {
    ...preferences,
    recommendation_enabled: false,
  });
  assert.equal(f.calls(), 0);
  assert.deepEqual([...f.saved.values()], ["stalled"]);
  const g = fixture();
  await g.delivery(task, "episode", {
    ...preferences,
    stalled_task_enabled: false,
  });
  assert.deepEqual([...g.saved.values()], ["recommendation"]);
});
Deno.test("resume or deletion during matching makes final commit a no-op", async () => {
  const f = fixture();
  f.backend.match = () => {
    f.resume();
    return Promise.resolve(relevant);
  };
  assert.equal(await f.delivery(task, "episode", preferences), false);
  assert.equal(f.saved.size, 0);
});
Deno.test("matching budget is bounded and other tasks still receive ordinary alerts", async () => {
  const f = fixture();
  let now = 0;
  const deliver = createStalledAlertDelivery(f.backend, () => now);
  now = 45001;
  await deliver(task, "episode", preferences);
  assert.equal(f.calls(), 0);
  assert.deepEqual([...f.saved.values()], ["stalled"]);
});
Deno.test("a failure before any insert can retry with the same episode", async () => {
  const f = fixture();
  const commit = f.backend.commit;
  let fails = true;
  f.backend.commit = (...args) => {
    if (fails) throw Error("database down");
    return commit(...args);
  };
  await assert.rejects(f.delivery(task, "episode", preferences));
  assert.equal(f.saved.size, 0);
  fails = false;
  await f.delivery(task, "episode", preferences);
  assert.equal(f.saved.size, 1);
});
Deno.test("scheduled store resolves both visibility reads through recipient RLS RPCs", async () => {
  const calls: Record<string, unknown>[] = [];
  const admin = {
    rpc: (name: string, args: Record<string, unknown>) => {
      assert.equal(name, "recommendation_resources_for_recipient");
      calls.push(args);
      return {
        abortSignal: () =>
          Promise.resolve({ data: [{ id: "r" }], error: null }),
      };
    },
  };
  const store = new ScheduledRecommendationStore(
    admin as unknown as ConstructorParameters<
      typeof ScheduledRecommendationStore
    >[0],
    "owner",
  );
  assert.deepEqual(await store.visibleIds(), ["r"]);
  await store.visibleDetails(["r"]);
  assert.deepEqual(calls, [{ p_user_id: "owner" }, {
    p_user_id: "owner",
    p_ids: ["r"],
  }]);
});

Deno.test("failed preflight read can still safely commit the ordinary fallback", async () => {
  const f = fixture();
  f.backend.state = () => Promise.reject(Error("temporary read failure"));
  await f.delivery(task, "episode", preferences);
  assert.equal(f.calls(), 0);
  assert.deepEqual([...f.saved.values()], ["stalled"]);
});
Deno.test("saved generation runs independently of alert preferences and handled fallback", async () => {
  const f = fixture();
  f.backend.persistIndependently = true;
  await f.delivery(task, "episode", {
    ...preferences,
    recommendation_enabled: false,
  });
  assert.equal(f.calls(), 1);
  assert.deepEqual([...f.saved.values()], ["stalled"]);
  await f.delivery(task, "episode", preferences);
  assert.equal(f.calls(), 2);
  assert.equal(f.saved.size, 1);
  // The real match adapter uses cached persistence on the second call, tested
  // separately in persistence.test.ts and the SQL generation tests.
});
