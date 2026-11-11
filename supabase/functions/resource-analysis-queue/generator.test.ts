import assert from "node:assert/strict";
import { AnalysisError, createAnalyzer, validateLabels } from "./generator.ts";
import { GeminiTagProvider } from "./gemini.ts";
import { loadResourceSource, videoLocation } from "./store.ts";
import {
  ExampleDatabase,
  exampleLabels,
  ownerId,
  resourceId,
} from "./test_helpers.ts";
const code = (expected: string) => (e: unknown) =>
  e instanceof AnalysisError && e.code === expected;
function video(db: ExampleDatabase) {
  db.resource.kind = "Video";
  db.resource.external_url =
    "https://example.supabase.co/storage/v1/object/authenticated/marketplace-videos/a.mp4";
  db.transcript = {
    id: "transcript",
    resource_id: resourceId,
    status: "ready",
    source_file_id: "file",
    source_version: "v1",
    storage_bucket: "marketplace-videos",
    storage_path: "a.mp4",
    transcript_text: "Implement database row level security.",
  };
}
Deno.test("text source contains server fields and nullable values are safe", async () => {
  const db = new ExampleDatabase();
  let source = "";
  const run = createAnalyzer(db.store(), {
    generate: (_title, text) => {
      source = text;
      return Promise.resolve(exampleLabels);
    },
  });
  const saved = await run(ownerId, resourceId);
  for (
    const field of [
      "Flutter interfaces",
      "Build a mobile app",
      "Mobile development",
      "Use Dart",
      "existing tags",
    ]
  ) assert.ok(source.includes(field));
  assert.equal(saved.resource_id, resourceId);
  assert.equal(db.index.size, 1);
  db.resource.body = null;
  db.resource.tags = null;
  await run(ownerId, resourceId);
  assert.ok(!source.includes("null"));
});
Deno.test("ready video uses current transcript, never the URL as content", async () => {
  const db = new ExampleDatabase();
  video(db);
  let source = "";
  await createAnalyzer(db.store(), {
    generate: (_title, text) => {
      source = text;
      return Promise.resolve(exampleLabels);
    },
  })(ownerId, resourceId);
  assert.ok(source.includes("row level security"));
  assert.ok(!source.includes("https://"));
});
Deno.test("pending and replaced video transcripts prevent Gemini calls", async () => {
  for (const replaced of [false, true]) {
    const db = new ExampleDatabase();
    video(db);
    if (replaced) db.currentVersion = "v2";
    else db.transcript!.status = "pending";
    let calls = 0;
    await assert.rejects(
      createAnalyzer(db.store(), {
        generate: () => {
          calls++;
          return Promise.resolve(exampleLabels);
        },
      })(ownerId, resourceId),
      code("video_transcript_not_ready"),
    );
    assert.equal(calls, 0);
    assert.equal(db.index.size, 0);
  }
});
Deno.test("unauthorized and moderated resources cannot access transcripts", async () => {
  const db = new ExampleDatabase();
  video(db);
  await assert.rejects(
    db.store().loadAuthorized("other", resourceId),
    code("resource_analysis_forbidden"),
  );
  db.resource.moderation_hidden = true;
  await assert.rejects(
    db.store().loadAuthorized(ownerId, resourceId),
    code("resource_analysis_forbidden"),
  );
  assert.ok(!db.calls.includes("rpc/read_ready_video_transcript"));
});
Deno.test("invalid Gemini output preserves existing index; reanalysis updates the same row", async () => {
  const db = new ExampleDatabase();
  await createAnalyzer(db.store(), {
    generate: () => Promise.resolve(exampleLabels),
  })(ownerId, resourceId);
  const before = structuredClone(db.index.get(resourceId));
  await assert.rejects(
    createAnalyzer(db.store(), {
      generate: () => Promise.resolve({ tags: ["wrong"] }),
    })(ownerId, resourceId),
    code("gemini_response_invalid"),
  );
  assert.deepEqual(db.index.get(resourceId), before);
  await createAnalyzer(db.store(), {
    generate: () =>
      Promise.resolve({
        keywords: ["typescript"],
        topic_tags: ["web development"],
      }),
  })(ownerId, resourceId);
  assert.equal(db.index.size, 1);
  assert.notEqual(db.index.get(resourceId)!.analysed_at, before!.analysed_at);
});
Deno.test("resource or video changes during generation prevent save", async () => {
  for (const isVideo of [false, true]) {
    const db = new ExampleDatabase();
    if (isVideo) video(db);
    const run = createAnalyzer(db.store(), {
      generate: () => {
        if (isVideo) db.currentVersion = "v2";
        else db.resource.body = "Changed";
        return Promise.resolve(exampleLabels);
      },
    });
    await assert.rejects(run(ownerId, resourceId), code("resource_changed"));
    assert.equal(db.index.size, 0);
  }
});
Deno.test("labels normalize and deduplicate, with strict shape/type/size bounds", () => {
  assert.deepEqual(
    validateLabels({
      keywords: [" Flutter ", "FLUTTER"],
      topic_tags: ["Mobile   Development"],
    }),
    { keywords: ["flutter"], topic_tags: ["mobile development"] },
  );
  for (
    const raw of [
      { keywords: [null], topic_tags: [] },
      { keywords: Array(21).fill("x"), topic_tags: [] },
      { keywords: [""], topic_tags: [] },
      { keywords: [], topic_tags: [], extra: 1 },
    ]
  ) assert.throws(() => validateLabels(raw), code("gemini_response_invalid"));
});
Deno.test("URL allowlist rejects other hosts, buckets, signed URLs, Cloudinary and traversal", () => {
  const base =
    "https://example.supabase.co/storage/v1/object/public/marketplace-videos/";
  assert.equal(
    videoLocation(
      base + "hello%20world.mp4",
      "https://example.supabase.co",
      "marketplace-videos",
    ).path,
    "hello world.mp4",
  );
  for (
    const url of [
      base + "a.mp4?token=x",
      base + "a/%2e%2e/b.mp4",
      base.replace("example.supabase.co", "evil.example") + "a.mp4",
      "https://res.cloudinary.com/a.mp4",
      base.replace("/public/", "/sign/") + "a.mp4",
    ]
  ) {
    assert.throws(
      () =>
        videoLocation(url, "https://example.supabase.co", "marketplace-videos"),
      code("video_storage_reference_unsupported"),
    );
  }
});
Deno.test("provider keeps bounded transient retry and structured JSON", async () => {
  let calls = 0;
  const provider = new GeminiTagProvider({
    apiKey: () => "fake",
    sleep: () => Promise.resolve(),
    fetch: ((_url, init) => {
      calls++;
      assert.ok(
        JSON.parse(String(init!.body)).generationConfig.responseJsonSchema
          .properties.keywords,
      );
      return Promise.resolve(
        calls === 1 ? new Response("busy", { status: 503 }) : Response.json({
          candidates: [{
            finishReason: "STOP",
            content: { parts: [{ text: JSON.stringify(exampleLabels) }] },
          }],
        }),
      );
    }) as typeof fetch,
  });
  assert.deepEqual(
    await provider.generate("title", "text", new AbortController().signal),
    exampleLabels,
  );
  assert.equal(calls, 2);
});

Deno.test("Reading PDF requires a current extraction; other Reading links keep authored body", async () => {
  const resource: Record<string, unknown> = {
    id: resourceId,
    author_id: ownerId,
    kind: "Reading",
    status: "published",
    moderation_hidden: false,
    title: "PDF",
    body: "Authored body",
    external_url:
      "https://example.supabase.co/storage/v1/object/authenticated/marketplace-documents/lesson.pdf",
  };
  let ready = true;
  const calls: string[] = [];
  const backend = (path: string) => {
    calls.push(path);
    return Promise.resolve(
      path.startsWith("learning_resources") ? [resource] : ready
        ? [{
          id: "extraction",
          status: "ready",
          extracted_text: "PDF Flutter layouts",
        }]
        : [],
    );
  };
  const load = () =>
    loadResourceSource(
      backend,
      "https://example.supabase.co",
      "marketplace-videos",
      ownerId,
      resourceId,
    );
  const source = await load();
  assert.ok(source.text.includes("PDF Flutter layouts"));
  assert.ok(source.text.includes("Authored body"));
  assert.ok(calls.includes("rpc/read_ready_resource_extraction"));
  ready = false;
  await assert.rejects(load, code("video_transcript_not_ready"));
  resource.external_url =
    "https://other.invalid/storage/v1/object/authenticated/marketplace-documents/lesson.pdf";
  await assert.rejects(load, code("video_storage_reference_unsupported"));
  resource.external_url = "https://example.org/article";
  assert.equal((await load()).transcript, null);
});
