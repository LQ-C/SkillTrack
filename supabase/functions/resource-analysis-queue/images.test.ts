import assert from "node:assert/strict";
import { AnalysisError } from "./generator.ts";
import { GeminiTagProvider } from "./gemini.ts";
import {
  downloadImage,
  drainImage,
  imageMime,
  MAX_IMAGE_BYTES,
  validateImageAnalysis,
} from "./images.ts";
import { type Backend, loadResourceSource } from "./store.ts";
const png = Uint8Array.from(
  atob(
    "iVBORw0KGgoAAAANSUhEUgAAAAMAAAADCAIAAADZSiLoAAAACXBIWXMAAA7EAAAOxAGVKw4bAAAADklEQVR4nGOogAEGLCwAvfYMqd43PnQAAAAASUVORK5CYII=",
  ),
  (c) => c.charCodeAt(0),
);
const jpeg = Uint8Array.from(
  atob(
    "/9j/4AAQSkZJRgABAQEAYABgAAD/2wBDAAIBAQEBAQIBAQECAgICAgQDAgICAgUEBAMEBgUGBgYFBgYGBwkIBgcJBwYGCAsICQoKCgoKBggLDAsKDAkKCgr/2wBDAQICAgICAgUDAwUKBwYHCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgr/wgARCAADAAMDAREAAhEBAxEB/8QAFAABAAAAAAAAAAAAAAAAAAAABf/EABQBAQAAAAAAAAAAAAAAAAAAAAD/2gAMAwEAAhADEAAAATz/xAAUEAEAAAAAAAAAAAAAAAAAAAAA/9oACAEBAAEFAn//xAAUEQEAAAAAAAAAAAAAAAAAAAAA/9oACAEDAQE/AX//xAAUEQEAAAAAAAAAAAAAAAAAAAAA/9oACAECAQE/AX//xAAUEAEAAAAAAAAAAAAAAAAAAAAA/9oACAEBAAY/An//xAAUEAEAAAAAAAAAAAAAAAAAAAAA/9oACAEBAAE/IX//2gAMAwEAAgADAAAAEB//xAAUEQEAAAAAAAAAAAAAAAAAAAAA/9oACAEDAQE/EH//xAAUEQEAAAAAAAAAAAAAAAAAAAAA/9oACAECAQE/EH//xAAUEAEAAAAAAAAAAAAAAAAAAAAA/9oACAEBAAE/EH//2Q==",
  ),
  (c) => c.charCodeAt(0),
);
const base = "https://example.supabase.co",
  bucket = "marketplace-documents",
  signal = () => new AbortController().signal;
const labels = {
  description: "A Flutter widget hierarchy diagram.",
  keywords: ["Flutter", "flutter"],
  topic_tags: ["Mobile development"],
};
function transport(bytes = png, mime = "image/png"): typeof fetch {
  return () =>
    Promise.resolve(
      new Response(bytes.slice(), { headers: { "Content-Type": mime } }),
    );
}
Deno.test("PNG/JPEG signatures and containers, corrupt data and unsupported images", () => {
  assert.equal(imageMime(png), "image/png");
  assert.equal(imageMime(jpeg), "image/jpeg");
  for (
    const bytes of [
      png.slice(0, -1),
      jpeg.slice(0, -1),
      new Uint8Array([0xff, 0xd8, 0xff, 0xd9]),
    ]
  ) {
    assert.throws(() => imageMime(bytes), { code: "image_invalid" });
  }
  const corrupt = png.slice();
  corrupt[40] ^= 1;
  assert.throws(() => imageMime(corrupt), { code: "image_invalid" });
  assert.throws(() => imageMime(new TextEncoder().encode("<svg/>")), {
    code: "image_unsupported",
  });
  assert.throws(() => imageMime(new Uint8Array(MAX_IMAGE_BYTES + 1)), {
    code: "image_too_large",
  });
});
Deno.test("private download uses only verified Storage path and backend headers", async () => {
  for (
    const [bytes, mime] of [[png, "image/png"], [jpeg, "image/jpeg"]] as const
  ) {
    const result = await downloadImage(
      base,
      "test-backend-key",
      { bucket, path: "a folder/diagram" },
      mime,
      signal(),
      (input, init) => {
        assert.equal(
          String(input),
          `${base}/storage/v1/object/authenticated/${bucket}/a%20folder/diagram`,
        );
        assert.equal(init?.redirect, "error");
        assert.equal(
          new Headers(init?.headers).get("apikey"),
          "test-backend-key",
        );
        return transport(bytes, mime)(input, init);
      },
    );
    assert.equal(result.mimeType, mime);
  }
});
Deno.test("MIME spoofing, oversized streams and denied downloads never reach Gemini", async () => {
  const run = (mime: string, fetcher: typeof fetch) =>
    downloadImage(
      base,
      "key",
      { bucket, path: "file" },
      mime,
      signal(),
      fetcher,
    );
  await assert.rejects(run("image/png", transport(jpeg, "image/png")), {
    code: "image_mime_mismatch",
  });
  await assert.rejects(run("image/png", transport(png, "image/jpeg")), {
    code: "image_mime_mismatch",
  });
  await assert.rejects(run("image/webp", transport()), {
    code: "image_unsupported",
  });
  await assert.rejects(
    run(
      "image/png",
      () => Promise.resolve(new Response(null, { status: 403 })),
    ),
    { code: "image_download_failed" },
  );
  await assert.rejects(
    run("image/png", () =>
      Promise.resolve(
        new Response(null, {
          headers: {
            "Content-Type": "image/png",
            "Content-Length": String(MAX_IMAGE_BYTES + 1),
          },
        }),
      )),
    { code: "image_too_large" },
  );
  await assert.rejects(
    run("image/png", transport(new Uint8Array(MAX_IMAGE_BYTES + 1))),
    { code: "image_too_large" },
  );
});
Deno.test("strict structured image output and unreadable images", () => {
  assert.deepEqual(validateImageAnalysis(labels), {
    ...labels,
    keywords: ["flutter"],
    topic_tags: ["mobile development"],
  });
  const unreadable = {
    description: "The image is too blurred to read reliably.",
    keywords: [],
    topic_tags: [],
  };
  assert.deepEqual(validateImageAnalysis(unreadable), unreadable);
  for (
    const value of [
      { ...labels, description: " " },
      { ...labels, description: "x".repeat(4001) },
      { ...labels, description: "line\nbreak" },
      { ...labels, extra: true },
      { ...labels, keywords: [1] },
      { ...labels, topic_tags: ["x".repeat(81)] },
    ]
  ) {
    assert.throws(() => validateImageAnalysis(value), {
      code: "gemini_response_invalid",
    });
  }
});
Deno.test("Gemini REST inline image data, schema and bounded retry reuse existing provider", async () => {
  let calls = 0;
  const provider = new GeminiTagProvider({
    apiKey: () => "fake-key",
    sleep: () => Promise.resolve(),
    fetch: (_url, init) => {
      calls++;
      const body = JSON.parse(String(init?.body));
      assert.equal(body.contents[0].parts[1].inlineData.mimeType, "image/png");
      assert.equal(
        body.contents[0].parts[1].inlineData.data,
        btoa(String.fromCharCode(...png)),
      );
      assert.deepEqual(body.generationConfig.responseJsonSchema.required, [
        "description",
        "keywords",
        "topic_tags",
      ]);
      assert.match(body.contents[0].parts[0].text, /Do not guess/);
      return Promise.resolve(
        calls === 1 ? new Response(null, { status: 503 }) : Response.json({
          candidates: [{
            finishReason: "STOP",
            content: { parts: [{ text: JSON.stringify(labels) }] },
          }],
        }),
      );
    },
  });
  assert.deepEqual(
    await provider.generateImage("metadata", {
      bytes: png,
      mimeType: "image/png",
    }, signal()),
    labels,
  );
  assert.equal(calls, 2);
});
function fixture() {
  const resource = {
    id: "resource",
    author_id: "owner",
    kind: "Reading",
    status: "published",
    moderation_hidden: false,
    external_url:
      `${base}/storage/v1/object/authenticated/${bucket}/diagram.png`,
    title: "Diagram",
    body: "Original body",
  };
  const job = {
    id: "job",
    claim_token: "token",
    resource_id: resource.id,
    storage_bucket: bucket,
    storage_path: "diagram.png",
    mime_type: "image/png",
    resource,
  };
  let status = "pending", saved: unknown = "previous valid result", saves = 0;
  const calls: { path: string; body: Record<string, unknown> }[] = [];
  const backend: Backend = (path, input) =>
    Promise.resolve().then(() => {
      const body = input as Record<string, unknown>;
      calls.push({ path, body });
      if (path === "rpc/claim_resource_image") {
        if (status !== "pending") return null;
        status = "processing";
        return structuredClone(job);
      }
      if (path === "rpc/complete_resource_image") {
        if (JSON.stringify(body.p_resource) !== JSON.stringify(resource)) {
          throw new AnalysisError(409, "resource_changed");
        }
        status = "ready";
        saved = body;
        saves++;
        return true;
      }
      if (path === "rpc/fail_resource_image") {
        status = "pending";
        return true;
      }
      throw new Error("Unexpected call");
    });
  return {
    resource,
    job,
    backend,
    calls,
    get saved() {
      return saved;
    },
    get saves() {
      return saves;
    },
  };
}
Deno.test("cloud PNG/JPEG processing completes once; unchanged ready image skips Gemini", async () => {
  for (
    const [bytes, mime] of [[png, "image/png"], [jpeg, "image/jpeg"]] as const
  ) {
    const f = fixture();
    f.job.mime_type = mime;
    let generated = 0;
    const provider = {
      generateImage: () => {
        generated++;
        return Promise.resolve(labels);
      },
    };
    const run = () =>
      drainImage(
        f.backend,
        provider,
        base,
        "key",
        bucket,
        null,
        signal(),
        transport(bytes, mime),
      );
    assert.equal((await run()).outcome, "ready");
    assert.equal((await run()).outcome, "idle");
    assert.equal(generated, 1);
    assert.equal(f.saves, 1);
    assert.equal(f.resource.body, "Original body");
  }
});
Deno.test("Gemini failure and invalid output preserve previous result; retry succeeds", async () => {
  for (
    const failure of [
      () => Promise.reject(new AnalysisError(429, "gemini_rate_limited", 120)),
      () => Promise.resolve({ ...labels, keywords: "wrong" }),
    ]
  ) {
    const f = fixture();
    assert.equal(
      (await drainImage(
        f.backend,
        { generateImage: failure },
        base,
        "key",
        bucket,
        null,
        signal(),
        transport(),
      )).outcome,
      "attempt_failed",
    );
    assert.equal(f.saved, "previous valid result");
    assert.equal(f.saves, 0);
    assert.equal(
      (await drainImage(
        f.backend,
        { generateImage: () => Promise.resolve(labels) },
        base,
        "key",
        bucket,
        null,
        signal(),
        transport(),
      )).outcome,
      "ready",
    );
  }
});
Deno.test("file replacement or changed metadata during Gemini never overwrites analysis", async () => {
  const f = fixture();
  const result = await drainImage(
    f.backend,
    {
      generateImage: () => {
        f.resource.external_url =
          `${base}/storage/v1/object/authenticated/${bucket}/replacement.jpg`;
        return Promise.resolve(labels);
      },
    },
    base,
    "key",
    bucket,
    null,
    signal(),
    transport(),
  );
  assert.equal(result.outcome, "attempt_failed");
  assert.equal(f.saves, 0);
  assert.equal(f.saved, "previous valid result");
  assert.equal(f.calls.at(-1)?.body.p_error_code, "resource_changed");
});
Deno.test("hidden, archived, untargeted draft and invalid URLs reject before private download", async () => {
  for (
    const changes of [
      { moderation_hidden: true },
      { status: "archived" },
      { status: "draft" },
      { external_url: "https://evil.example/image.png" },
      {
        external_url:
          `${base}/storage/v1/object/sign/${bucket}/diagram.png?token=secret`,
      },
      {
        external_url:
          `${base}/storage/v1/object/authenticated/task-attachments/diagram.png`,
      },
    ]
  ) {
    const f = fixture();
    Object.assign(f.resource, changes);
    let downloads = 0, generated = 0;
    await drainImage(
      f.backend,
      {
        generateImage: () => {
          generated++;
          return Promise.resolve(labels);
        },
      },
      base,
      "key",
      bucket,
      null,
      signal(),
      () => {
        downloads++;
        throw new Error();
      },
    );
    assert.equal(downloads, 0);
    assert.equal(generated, 0);
    assert.equal(f.saves, 0);
  }
  const f = fixture();
  f.resource.status = "draft";
  assert.equal(
    (await drainImage(
      f.backend,
      { generateImage: () => Promise.resolve(labels) },
      base,
      "key",
      bucket,
      "resource",
      signal(),
      transport(),
    )).outcome,
    "ready",
  );
});
Deno.test("metadata reanalysis uses only current ready image description, not URL/body fallback", async () => {
  const f = fixture();
  let ready = true;
  const backend: Backend = (path) => {
    if (path.startsWith("learning_resources?")) {
      return Promise.resolve([f.resource]);
    }
    if (path === "rpc/is_image_resource") return Promise.resolve(true);
    if (path === "rpc/read_ready_resource_extraction") {
      return Promise.resolve(
        ready
          ? [{
            id: "image",
            status: "ready",
            extraction_type: "image_description",
            extracted_text: labels.description,
          }]
          : [],
      );
    }
    throw new Error("Unexpected call");
  };
  const source = await loadResourceSource(
    backend,
    base,
    "videos",
    "owner",
    "resource",
  );
  assert.match(source.text, /widget hierarchy/);
  ready = false;
  await assert.rejects(
    loadResourceSource(backend, base, "videos", "owner", "resource"),
    { code: "video_transcript_not_ready" },
  );
});
Deno.test("Storage ETag pins the downloaded version and rejects replacement responses", async () => {
  const run = (etag: string, status = 200) =>
    downloadImage(
      base,
      "key",
      { bucket, path: "diagram.png" },
      "image/png",
      signal(),
      (_input, init) => {
        assert.equal(
          new Headers(init?.headers).get("If-Match"),
          '"version-etag"',
        );
        assert.equal(init?.cache, "no-store");
        return Promise.resolve(
          new Response(status === 200 ? png.slice() : null, {
            status,
            headers: { "Content-Type": "image/png", "ETag": etag },
          }),
        );
      },
      "version-etag",
    );
  assert.equal((await run('"version-etag"')).mimeType, "image/png");
  await assert.rejects(run('"replacement"'), { code: "source_replaced" });
  await assert.rejects(run('"replacement"', 412), { code: "source_replaced" });
});
