import assert from "node:assert/strict";
import { AnalysisError } from "./generator.ts";
import { type Backend } from "./store.ts";
import {
  ExampleDatabase,
  exampleLabels,
  resourceId,
  sourceVersion,
} from "./test_helpers.ts";
import { createQueueHandler, drainOne } from "./processor.ts";

function fixture() {
  const db = new ExampleDatabase();
  db.resource.kind = "Video";
  db.resource.status = "published";
  db.resource.external_url =
    "https://example.supabase.co/storage/v1/object/public/videos/a.mp4";
  db.transcript = {
    id: "transcript",
    resource_id: resourceId,
    status: "ready",
    source_file_id: "file",
    source_version: "v1",
    storage_bucket: "videos",
    storage_path: "a.mp4",
    transcript_text: "Use Flutter and Dart.",
  };
  const job = {
    id: "job",
    claim_token: "token",
    resource_id: resourceId,
    transcript_id: "transcript" as string | null,
    source_file_id: "file" as string | null,
    source_version: "v1" as string | null,
    content_version: sourceVersion(db.resource, db.transcript),
    allow_draft: false,
    status: "pending",
    attempt_count: 0,
  };
  const calls: { path: string; body: unknown }[] = [];
  const backend: Backend = async (path, body) => {
    calls.push({ path, body });
    const data = body as Record<string, unknown>;
    if (path === "rpc/resource_analysis_version") {
      return sourceVersion(
        data.p_resource as Record<string, unknown>,
        data.p_transcript as Record<string, unknown> | null,
      );
    }
    if (path === "rpc/enqueue_ready_resource_analysis") return 0;
    if (path === "rpc/claim_resource_analysis_job") {
      if (job.status !== "pending" || job.attempt_count >= 3) return null;
      job.status = "processing";
      job.attempt_count++;
      return structuredClone(job);
    }
    if (path === "rpc/fail_resource_analysis_job") {
      job.status = data.p_skip
        ? "skipped"
        : job.attempt_count >= 3
        ? "failed"
        : "pending";
      return true;
    }
    if (path === "rpc/complete_resource_analysis_job") {
      const saved = await db.backend("rpc/save_resource_analysis", {
        ...data,
        p_user_id: db.resource.author_id,
      });
      job.status = "ready";
      return saved;
    }
    return await db.backend(path, body);
  };
  return { db, job, backend, calls };
}
const provider = { generate: () => Promise.resolve(exampleLabels) };
const run = (
  f: ReturnType<typeof fixture>,
  p = provider,
  draft: string | null = null,
) => drainOne(f.backend, p, "https://example.supabase.co", "videos", draft);

Deno.test("automatic analysis derives author and atomically completes the job/index", async () => {
  const f = fixture();
  assert.equal((await run(f)).outcome, "ready");
  assert.equal(f.db.index.size, 1);
  assert.equal(f.job.status, "ready");
  const saved = f.calls.find((c) =>
    c.path === "rpc/complete_resource_analysis_job"
  )!.body as Record<string, unknown>;
  assert.equal(saved.p_job_id, f.job.id);
  assert.ok(!("p_user_id" in saved));
  assert.equal((await run(f)).outcome, "idle");
  assert.equal(f.db.saves, 1);
});
Deno.test("Gemini failure retries only analysis and preserves previous valid result", async () => {
  const f = fixture();
  f.db.index.set(resourceId, {
    resource_id: resourceId,
    ...exampleLabels,
    analysed_at: "previous",
  });
  const result = await run(f, {
    generate: () =>
      Promise.reject(new AnalysisError(429, "gemini_rate_limited", 120)),
  });
  assert.equal(result.outcome, "attempt_failed");
  assert.equal(f.db.index.get(resourceId)!.analysed_at, "previous");
  const failure = f.calls.find((c) =>
    c.path === "rpc/fail_resource_analysis_job"
  )!.body as Record<string, unknown>;
  assert.equal(failure.p_retry_after_seconds, 120);
  assert.equal(failure.p_skip, false);
  assert.equal((await run(f)).outcome, "ready");
  assert.equal(f.job.attempt_count, 2);
  assert.ok(!f.calls.some((c) => c.path.includes("complete_video_transcript")));
});
Deno.test("stale version is skipped before Gemini and cannot replace the index", async () => {
  const f = fixture();
  f.db.currentVersion = "v2";
  f.db.transcript!.source_version = "v2";
  let calls = 0;
  assert.equal(
    (await run(f, {
      generate: () => {
        calls++;
        return Promise.resolve(exampleLabels);
      },
    })).outcome,
    "skipped",
  );
  assert.equal(calls, 0);
  assert.equal(f.db.index.size, 0);
});
Deno.test("replacement during Gemini fails the atomic save", async () => {
  const f = fixture();
  const result = await run(f, {
    generate: () => {
      f.db.currentVersion = "v2";
      return Promise.resolve(exampleLabels);
    },
  });
  assert.equal(result.outcome, "attempt_failed");
  assert.equal(f.db.index.size, 0);
  assert.equal(f.job.status, "pending");
});
Deno.test("hidden/archive are skipped, draft requires explicit job authorization", async () => {
  for (const status of ["archived", "draft"]) {
    const f = fixture();
    f.db.resource.status = status;
    assert.equal((await run(f)).outcome, "skipped");
  }
  const hidden = fixture();
  hidden.db.resource.moderation_hidden = true;
  assert.equal((await run(hidden)).outcome, "skipped");
  const draft = fixture();
  draft.db.resource.status = "draft";
  draft.job.allow_draft = true;
  assert.equal((await run(draft, provider, resourceId)).outcome, "ready");
  assert.deepEqual(draft.calls[0].body, {
    p_resource_id: resourceId,
    p_allow_draft: true,
    p_limit: 25,
  });
});
Deno.test("dedicated backend secret is required; caller cannot supply an owner or transcript", async () => {
  const secret = "test-only-".repeat(5);
  const drained: (string | null)[] = [];
  const handler = createQueueHandler(() => secret, (id) => {
    drained.push(id);
    return Promise.resolve({ processed: 0 });
  });
  const request = (body: unknown, key: string | null = secret) =>
    new Request("https://local", {
      method: "POST",
      headers: key ? { "x-resource-analysis-secret": key } : {},
      body: JSON.stringify(body),
    });
  assert.equal((await handler(request({}, null))).status, 401);
  assert.equal((await handler(request({}, "wrong"))).status, 401);
  assert.equal(
    (await handler(request({ authorId: "spoof", transcript: "spoof" }))).status,
    400,
  );
  assert.equal(
    (await handler(request({ draftResourceId: "bad" }))).status,
    400,
  );
  assert.deepEqual(drained, []);
  assert.equal((await handler(request({}))).status, 200);
  assert.equal(
    (await handler(request({ draftResourceId: resourceId }))).status,
    200,
  );
  assert.deepEqual(drained, [null, resourceId]);
  assert.equal((await handler(new Request("https://local"))).status, 405);
  assert.equal(
    (await createQueueHandler(() => undefined, () => Promise.resolve({}))(
      request({}),
    )).status,
    503,
  );
});

Deno.test("automatic text analysis uses saved body without a transcript", async () => {
  const f = fixture();
  f.db.resource.kind = "Article";
  f.db.transcript = null;
  f.job.transcript_id = null;
  f.job.source_file_id = null;
  f.job.source_version = null;
  f.job.content_version = sourceVersion(f.db.resource, null);
  assert.equal((await run(f)).outcome, "ready");
  assert.equal(f.db.saves, 1);
  assert.ok(!f.calls.some((c) => c.path === "rpc/read_ready_video_transcript"));
});
Deno.test("changed metadata skips an old job before spending a Gemini request", async () => {
  const f = fixture();
  f.db.resource.body = "New lesson";
  let requests = 0;
  assert.equal(
    (await run(f, {
      generate: () => {
        requests++;
        return Promise.resolve(exampleLabels);
      },
    })).outcome,
    "skipped",
  );
  assert.equal(requests, 0);
  assert.equal(f.db.saves, 0);
});
