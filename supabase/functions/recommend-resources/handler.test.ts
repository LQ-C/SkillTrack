import assert from "node:assert/strict";
import {
  createRecommendationHandler,
  type Recommendation,
  type RecommendationStore,
  type TaskContext,
} from "./handler.ts";
import {
  createEmbedder,
  DEFAULT_CONFIG,
  querySignals,
  RecommendationError,
  scoreCandidate,
  validateVector,
} from "../_shared/recommendations/semantic.js";
import { drainEmbedding } from "../_shared/recommendations/indexer.ts";
import { SupabaseRecommendationStore } from "./store.ts";
const id = "20000000-0000-0000-0000-000000000001";
const vector = [1, ...Array(383).fill(0)];
const request = (body: unknown = { task_id: id }) =>
  new Request("https://local", { method: "POST", body: JSON.stringify(body) });
function fixture() {
  let task: TaskContext | null = {
    title: "Flutter row layout",
    description: "Use Flutter Row widgets",
    is_stalled: true,
    source_version: "task-v1",
  };
  let visible = ["relevant", "other"];
  let calls = 0, taskReads = 0;
  const detail = (id: string) => ({
    id,
    title: id,
    summary: "Saved summary",
    kind: "Video",
    updated_at: "2026-11-11T00:00:00Z",
  });
  const matches: Recommendation[] = [{
    resource_id: "relevant",
    title: "relevant",
    summary: "Saved summary",
    resource_type: "Video",
    source_version: "v1",
    resource_updated_at: "2026-11-11T00:00:00Z",
  }];
  const store: RecommendationStore = {
    loadTask: () => {
      taskReads++;
      return Promise.resolve(task ? { ...task } : null);
    },
    visibleIds: () => Promise.resolve(visible),
    search: (_task, _user, _snapshot, ids) =>
      Promise.resolve(matches.filter((m) => ids.includes(m.resource_id))),
    visibleDetails: () => Promise.resolve(visible.map(detail)),
  };
  const embedder = {
    embed: () => {
      calls++;
      return Promise.resolve(vector);
    },
  };
  const handler = (userId: string | null = "owner") =>
    createRecommendationHandler({ userId, store, getEmbedder: () => embedder });
  return {
    store,
    embedder,
    handler,
    matches,
    setTask: (value: TaskContext | null) => task = value,
    setVisible: (ids: string[]) => visible = ids,
    calls: () => calls,
    taskReads: () => taskReads,
  };
}
Deno.test("unauthenticated and unowned task requests never reach embeddings", async () => {
  const f = fixture();
  assert.equal((await f.handler(null)(request())).status, 401);
  assert.equal(f.taskReads(), 0);
  f.setTask(null);
  assert.equal((await f.handler()(request())).status, 404);
  assert.equal(f.calls(), 0);
});
Deno.test("POST accepts only a UUID task_id, never caller content/owner/stalled flags", async () => {
  const f = fixture();
  for (
    const body of [
      { task_id: "bad" },
      { task_id: id, title: "spoof" },
      { task_id: id, owner_id: "other" },
      { task_id: id, is_stalled: true },
      [],
      null,
    ]
  ) assert.equal((await f.handler()(request(body))).status, 400);
  assert.equal((await f.handler()(new Request("https://local"))).status, 405);
  assert.equal(
    (await f.handler()(request({ task_id: id, extra: "x".repeat(3000) })))
      .status,
    413,
  );
  assert.equal(f.calls(), 0);
});
Deno.test("non-stalled and no-access tasks produce empty states without native inference", async () => {
  const f = fixture();
  f.setTask({
    title: "",
    description: "",
    is_stalled: false,
    source_version: "v",
  });
  assert.equal(
    (await (await f.handler()(request())).json()).status,
    "not_stalled",
  );
  assert.equal(f.calls(), 0);
  const denied = fixture();
  denied.setVisible([]);
  assert.deepEqual(await (await denied.handler()(request())).json(), {
    status: "empty",
    recommendations: [],
  });
  assert.equal(denied.calls(), 0);
});
Deno.test("response is at most three read-only cards with no URL, vector or private content", async () => {
  const f = fixture();
  f.setVisible(["relevant", "second", "third", "fourth"]);
  f.matches.push(
    ...["second", "third", "fourth"].map((id) => ({
      ...f.matches[0],
      resource_id: id,
      title: id,
    })),
  );
  const response = await (await f.handler()(request())).json();
  assert.equal(response.recommendations.length, 3);
  assert.deepEqual(Object.keys(response.recommendations[0]).sort(), [
    "resource_id",
    "summary",
    "title",
    "type",
  ]);
  assert.equal(f.calls(), 1);
});
Deno.test("resource hidden after ranking is removed on the final user-RLS read", async () => {
  const f = fixture();
  f.store.search = () => {
    f.setVisible([]);
    return Promise.resolve(f.matches);
  };
  assert.deepEqual(await (await f.handler()(request())).json(), {
    status: "empty",
    recommendations: [],
  });
});
Deno.test("resumed or edited task during inference never returns stale recommendations", async () => {
  for (const resumed of [true, false]) {
    const f = fixture();
    f.embedder.embed = () => {
      f.setTask({
        title: "New title",
        description: "Changed",
        is_stalled: !resumed,
        source_version: "v2",
      });
      return Promise.resolve(vector);
    };
    const response = await f.handler()(request());
    assert.equal(response.status, resumed ? 200 : 409);
    assert.deepEqual((await response.json()).recommendations, []);
  }
});
Deno.test("native failures are safe retryable errors", async () => {
  const f = fixture();
  f.embedder.embed = () => Promise.reject(new Error("private backend details"));
  const response = await f.handler()(request());
  assert.equal(response.status, 503);
  assert.ok(!(await response.text()).includes("private backend details"));
});
Deno.test("prototype pooling uses gte dimensions, mean_pool, normalization and bounded chunks", async () => {
  const inputs: string[] = [];
  const embedder = createEmbedder({
    run: (text: string, options: unknown) => {
      inputs.push(text);
      assert.deepEqual(options, { mean_pool: true, normalize: true });
      return Promise.resolve(vector);
    },
  });
  assert.deepEqual(await embedder.embed("a".repeat(850)), vector);
  assert.deepEqual(inputs.map((x) => x.length), [400, 400, 50]);
  assert.throws(() => validateVector([1, 2]), RecommendationError);
  const query = querySignals({
    title: "Flutter Row",
    description: "Mobile layout",
  });
  assert.ok(
    scoreCandidate(query, {
      keywords: query.keywords,
      topic_tags: query.topic_tags,
      frameworks: ["flutter"],
      domains: ["mobile"],
    }, .95),
  );
  assert.equal(
    scoreCandidate(
      query,
      {
        keywords: ["cooking"],
        topic_tags: [],
        frameworks: ["react"],
        domains: ["web"],
      },
      .95,
      DEFAULT_CONFIG,
    ),
    null,
  );
});
Deno.test("indexer uses saved analysis, and failed inference records retry without completing", async () => {
  let pending = true;
  let completes = 0;
  let fails = 0;
  const source = {
    title: "Flutter",
    description: "Rows",
    keywords: ["flutter"],
    topic_tags: ["mobile development"],
    source_version: "version",
  };
  const backend = (path: string, body?: unknown): Promise<unknown> => {
    if (path === "rpc/backfill_resource_embeddings") return Promise.resolve(0);
    if (path === "rpc/claim_resource_embedding") {
      return Promise.resolve(
        pending ? { resource_id: "r", claim_token: "claim", source } : null,
      );
    }
    if (path === "rpc/complete_resource_embedding") {
      completes++;
      pending = false;
      assert.equal(
        (body as { p_source_version: string }).p_source_version,
        "version",
      );
      return Promise.resolve(true);
    }
    if (path === "rpc/fail_resource_embedding") {
      fails++;
      return Promise.resolve(true);
    }
    throw new Error(path);
  };
  assert.equal(
    (await drainEmbedding(backend, () => ({
      embed: () => Promise.reject(new Error("fail")),
    }))).outcome,
    "attempt_failed",
  );
  assert.equal(completes, 0);
  assert.equal(fails, 1);
  assert.equal(
    (await drainEmbedding(backend, () => ({
      embed: () => Promise.resolve(vector),
    }))).outcome,
    "ready",
  );
  assert.equal(completes, 1);
  assert.equal(
    (await drainEmbedding(backend, () => {
      throw new Error("must not start model");
    })).outcome,
    "idle",
  );
});
Deno.test("resource ID paging uses the authenticated client, preserving RLS and all pages", async () => {
  const observed: string[] = [];
  let page = 0;
  const query = {
    select: () => query,
    eq: (key: string, value: unknown) => {
      observed.push(`${key}:${value}`);
      return query;
    },
    order: () => query,
    limit: () => query,
    gt: () => query,
    abortSignal: () =>
      Promise.resolve({
        data: page++ === 0
          ? Array.from({ length: 500 }, (_, i) => ({ id: String(i) }))
          : [{ id: "last" }],
        error: null,
      }),
  };
  const user = {
    from: (table: string) => {
      assert.equal(table, "learning_resources");
      return query;
    },
  };
  const admin = {
    from: () => {
      throw new Error("must not bypass RLS");
    },
  };
  const store = new SupabaseRecommendationStore(
    admin as unknown as ConstructorParameters<
      typeof SupabaseRecommendationStore
    >[0],
    user as unknown as ConstructorParameters<
      typeof SupabaseRecommendationStore
    >[1],
  );
  const ids = await store.visibleIds();
  assert.equal(ids.length, 501);
  assert.equal(ids[500], "last");
  assert.ok(observed.includes("status:published"));
  assert.ok(observed.includes("moderation_hidden:false"));
});

Deno.test("manual non-stalled requests use only saved text and explicit manual mode", async () => {
  const f = fixture();
  const task = {
    title: "Saved Flutter row",
    description: "Saved description",
    is_stalled: false,
    source_version: "v1",
  };
  f.setTask(task);
  const modes: unknown[] = [];
  const load = f.store.loadTask;
  f.store.loadTask = (taskId, userId, mode) => {
    assert.equal(taskId, id);
    assert.equal(userId, "owner");
    modes.push(mode);
    return load(taskId, userId, mode);
  };
  f.embedder.embed = (text?: string) => {
    assert.ok(text?.includes(task.title));
    assert.ok(text?.includes(task.description));
    return Promise.resolve(vector);
  };
  const search = f.store.search;
  f.store.search = (...args) => {
    assert.equal(args[7], "manual");
    return search(...args);
  };
  const response = await f.handler()(request({ task_id: id, mode: "manual" }));
  assert.equal(response.status, 200);
  assert.equal((await response.json()).recommendations.length, 1);
  assert.deepEqual(modes, ["manual", "manual"]);
});
Deno.test("manual mode cannot bypass ownership, eligibility, RLS or source changes", async () => {
  const body = { task_id: id, mode: "manual" };
  const f = fixture();
  assert.equal((await f.handler(null)(request(body))).status, 401);
  f.setTask(null); // repository returns no context for completed/archived/unowned manual tasks
  assert.equal((await f.handler()(request(body))).status, 404);
  assert.equal(f.calls(), 0);
  const denied = fixture();
  denied.setVisible([]);
  assert.equal(
    (await (await denied.handler()(request(body))).json()).status,
    "empty",
  );
  assert.equal(denied.calls(), 0);
  for (
    const changed of [null, {
      title: "Changed",
      description: "",
      is_stalled: false,
      source_version: "v2",
    }]
  ) {
    const g = fixture();
    g.embedder.embed = () => {
      g.setTask(changed);
      return Promise.resolve(vector);
    };
    assert.equal(
      (await g.handler()(request(body))).status,
      changed ? 409 : 404,
    );
  }
});
Deno.test("omitted mode stays automatic and invalid modes are rejected", async () => {
  const f = fixture();
  for (const mode of [null, true, "MANUAL", "other", {}]) {
    assert.equal(
      (await f.handler()(request({ task_id: id, mode }))).status,
      400,
    );
  }
  const load = f.store.loadTask;
  f.store.loadTask = (task, user, mode) => {
    assert.equal(mode, "automatic");
    return load(task, user, mode);
  };
  assert.equal((await f.handler()(request())).status, 200);
  assert.equal(
    (await f.handler()(request({ task_id: id, mode: "automatic" }))).status,
    200,
  );
});

Deno.test("store forwards the mode to both ownership and matching RPCs", async () => {
  const calls: { name: string; args: Record<string, unknown> }[] = [];
  const task = {
    title: "Flutter",
    description: "Rows",
    is_stalled: false,
    source_version: "v1",
  };
  const admin = {
    rpc: (name: string, args: Record<string, unknown>) => {
      calls.push({ name, args });
      return {
        abortSignal: () =>
          Promise.resolve({
            data: name === "recommendation_load_owned_task" ? [task] : [],
            error: null,
          }),
      };
    },
  };
  const store = new SupabaseRecommendationStore(
    admin as unknown as ConstructorParameters<
      typeof SupabaseRecommendationStore
    >[0],
    {} as ConstructorParameters<typeof SupabaseRecommendationStore>[1],
  );
  for (const mode of ["manual", "automatic"] as const) {
    await store.loadTask(id, "owner", mode);
    await store.search(
      id,
      "owner",
      task,
      ["resource"],
      vector,
      querySignals(task),
      DEFAULT_CONFIG,
      mode,
    );
    assert.equal(calls.at(-2)?.args.p_mode, mode);
    assert.equal(calls.at(-1)?.args.p_mode, mode);
    assert.equal(calls.at(-1)?.args.p_task_version, "v1");
    assert.deepEqual(calls.at(-1)?.args.p_visible_ids, ["resource"]);
  }
  await store.loadTask(id, "owner");
  assert.equal(calls.at(-1)?.args.p_mode, "automatic");
});
