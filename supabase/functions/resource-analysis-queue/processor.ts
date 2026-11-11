import {
  AnalysisError,
  createAnalyzer,
  type ResourceStore,
  type TagProvider,
} from "./generator.ts";
import { type Backend, loadResourceSource } from "./store.ts";

type Job = {
  id: string;
  claim_token: string;
  resource_id: string;
  transcript_id: string | null;
  source_file_id: string | null;
  source_version: string | null;
  content_version: string;
  allow_draft: boolean;
};
const failureCodes = new Set([
  "gemini_rate_limited",
  "gemini_unavailable",
  "gemini_response_invalid",
  "analysis_timeout",
  "resource_changed",
  "resource_backend_unavailable",
  "video_transcript_not_ready",
  "video_storage_reference_unsupported",
  "resource_content_too_large",
  "resource_content_empty",
]);
export async function drainOne(
  backend: Backend,
  provider: TagProvider,
  projectUrl: string,
  bucket: string,
  draftResourceId: string | null = null,
  signal = AbortSignal.timeout(60_000),
  pdfBucket = "marketplace-documents",
  imageBucket = "marketplace-documents",
) {
  await backend("rpc/enqueue_ready_resource_analysis", {
    p_resource_id: draftResourceId,
    p_allow_draft: draftResourceId !== null,
    p_limit: 25,
  });
  const job = await backend("rpc/claim_resource_analysis_job", {
    p_resource_id: draftResourceId,
  }) as Job | null;
  if (!job) return { processed: 0, outcome: "idle" };
  try {
    // Resolve identity from the database after claiming. No owner arrives in the request.
    const rows = await backend(
      `learning_resources?id=eq.${
        encodeURIComponent(job.resource_id)
      }&select=author_id,status,moderation_hidden,kind`,
    ) as Record<string, unknown>[];
    const resource = rows[0];
    if (
      !resource || resource.moderation_hidden !== false ||
      !(resource.status === "published" ||
        (job.allow_draft && resource.status === "draft")) ||
      typeof resource.author_id !== "string"
    ) {
      throw new AnalysisError(403, "resource_ineligible");
    }
    const queueStore: ResourceStore = {
      async loadAuthorized(userId, resourceId) {
        const source = await loadResourceSource(
          backend,
          projectUrl,
          bucket,
          userId,
          resourceId,
          pdfBucket,
          imageBucket,
        );
        if (
          (source.transcript?.id ?? null) !== job.transcript_id ||
          (source.transcript?.source_file_id ?? null) !== job.source_file_id ||
          (source.transcript?.source_version ?? null) !== job.source_version
        ) {
          throw new AnalysisError(409, "source_replaced");
        }
        const version = await backend("rpc/resource_analysis_version", {
          p_resource: source.resource,
          p_transcript: source.transcript,
        });
        if (version !== job.content_version) {
          throw new AnalysisError(409, "source_replaced");
        }
        return source;
      },
      async saveIfCurrent(_userId, source, labels) {
        // The database derives the author again and atomically saves the index
        // and job outcome. It also rejects expired or reassigned claims.
        return await backend("rpc/complete_resource_analysis_job", {
          p_job_id: job.id,
          p_claim_token: job.claim_token,
          p_resource: source.resource,
          p_transcript: source.transcript,
          p_keywords: labels.keywords,
          p_topic_tags: labels.topic_tags,
        }) as Awaited<ReturnType<ResourceStore["saveIfCurrent"]>>;
      },
    };
    await createAnalyzer(queueStore, provider)(
      resource.author_id,
      job.resource_id,
      signal,
    );
    return { processed: 1, outcome: "ready" };
  } catch (error) {
    const code = error instanceof AnalysisError
      ? error.code
      : "analysis_failed";
    const ineligible = [
      "resource_ineligible",
      "resource_analysis_forbidden",
      "resource_unavailable",
    ].includes(code);
    const stale = [
      "source_replaced",
      "video_transcript_not_ready",
      "video_storage_reference_unsupported",
    ].includes(code);
    const recorded = ineligible
      ? "resource_ineligible"
      : stale
      ? "source_replaced"
      : failureCodes.has(code)
      ? code
      : "analysis_failed";
    const changed = await backend("rpc/fail_resource_analysis_job", {
      p_job_id: job.id,
      p_claim_token: job.claim_token,
      p_error_code: recorded,
      p_skip: ineligible || stale,
      p_retry_after_seconds: Math.min(
        86400,
        Math.max(
          60,
          error instanceof AnalysisError ? error.retryAfter ?? 60 : 60,
        ),
      ),
    });
    return {
      processed: 1,
      outcome: changed === true
        ? (ineligible || stale ? "skipped" : "attempt_failed")
        : "claim_lost",
    };
  }
}

export function createQueueHandler(
  secret: () => string | undefined,
  drain: (draftId: string | null) => Promise<unknown>,
) {
  return async (request: Request): Promise<Response> => {
    const headers = { "Cache-Control": "no-store" };
    try {
      if (request.method !== "POST") {
        return Response.json({ error: "post_required" }, {
          status: 405,
          headers: { ...headers, Allow: "POST" },
        });
      }
      const expected = secret();
      if (!expected || expected.length < 32) {
        return Response.json({ error: "queue_not_configured" }, {
          status: 503,
          headers,
        });
      }
      const supplied = request.headers.get("x-resource-analysis-secret") ?? "";
      if (supplied.length > 512) {
        return Response.json({ error: "unauthorized" }, {
          status: 401,
          headers,
        });
      }
      const hash = async (value: string) =>
        new Uint8Array(
          await crypto.subtle.digest(
            "SHA-256",
            new TextEncoder().encode(value),
          ),
        );
      const [a, b] = await Promise.all([hash(expected), hash(supplied)]);
      let mismatch = 0;
      for (let i = 0; i < a.length; i++) mismatch |= a[i] ^ b[i];
      if (mismatch !== 0) {
        return Response.json({ error: "unauthorized" }, {
          status: 401,
          headers,
        });
      }
      const reader = request.body?.getReader();
      let text = "", size = 0;
      if (reader) {
        const decoder = new TextDecoder();
        try {
          while (true) {
            const next = await reader.read();
            if (next.done) break;
            size += next.value.length;
            if (size > 2048) {
              await reader.cancel();
              return Response.json({ error: "request_too_large" }, {
                status: 413,
                headers,
              });
            }
            text += decoder.decode(next.value, { stream: true });
          }
          text += decoder.decode();
        } finally {
          reader.releaseLock();
        }
      }
      let body: unknown;
      try {
        body = text.trim() ? JSON.parse(text) : {};
      } catch {
        return Response.json({ error: "request_invalid" }, {
          status: 400,
          headers,
        });
      }
      if (
        !body || typeof body !== "object" || Array.isArray(body) ||
        Object.keys(body).some((key) => key !== "draftResourceId")
      ) {
        return Response.json({ error: "request_invalid" }, {
          status: 400,
          headers,
        });
      }
      const draftId = (body as { draftResourceId?: unknown }).draftResourceId;
      if (
        draftId !== undefined &&
        (typeof draftId !== "string" ||
          !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
            .test(draftId))
      ) {
        return Response.json({ error: "request_invalid" }, {
          status: 400,
          headers,
        });
      }
      return Response.json(
        await drain(typeof draftId === "string" ? draftId.toLowerCase() : null),
        { headers },
      );
    } catch {
      return Response.json({ error: "queue_request_failed" }, {
        status: 503,
        headers,
      });
    }
  };
}
