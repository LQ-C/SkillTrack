import { AnalysisError, type Source } from "./generator.ts";
export type Backend = (path: string, body?: unknown) => Promise<unknown>;
export function videoLocation(
  value: unknown,
  projectUrl: string,
  bucket: string,
): { bucket: string; path: string } {
  try {
    if (
      typeof value !== "string" || !bucket || value.includes("?") ||
      value.includes("#")
    ) throw new Error();
    if (
      value.split("/").some((part) =>
        [".", ".."].includes(decodeURIComponent(part))
      )
    ) throw new Error();
    const url = new URL(value), project = new URL(projectUrl);
    if (
      url.protocol !== "https:" || url.origin !== project.origin ||
      url.username || url.password
    ) throw new Error();
    const match =
      /^\/storage\/v1\/object\/(?:public|authenticated)\/([^/]+)\/(.+)$/.exec(
        url.pathname,
      );
    if (!match || decodeURIComponent(match[1]) !== bucket) throw new Error();
    const path = decodeURIComponent(match[2]);
    if (
      !path || path.length > 1024 || path.split("/").some((p) =>
        !p || p === "." || p === ".."
      ) || /[\\\p{Cc}]/u.test(path)
    ) throw new Error();
    return { bucket, path };
  } catch {
    throw new AnalysisError(422, "video_storage_reference_unsupported");
  }
}
export async function loadResourceSource(
  backend: Backend,
  projectUrl: string,
  bucket: string,
  userId: string,
  resourceId: string,
): Promise<Source> {
  const rows = await backend(
    `learning_resources?id=eq.${encodeURIComponent(resourceId)}&select=*`,
  ) as Record<string, unknown>[];
  const resource = rows[0];
  if (!resource) throw new AnalysisError(404, "resource_unavailable");
  if (
    resource.author_id !== userId || resource.moderation_hidden !== false ||
    !["draft", "published"].includes(String(resource.status))
  ) {
    throw new AnalysisError(403, "resource_analysis_forbidden");
  }
  let transcript: Record<string, unknown> | null = null;
  if (resource.kind === "Video") {
    const location = videoLocation(
      resource.external_url,
      projectUrl,
      bucket,
    );
    const ready = await backend("rpc/read_ready_video_transcript", {
      p_resource_id: resource.id,
      p_external_url: resource.external_url,
      p_storage_bucket: location.bucket,
      p_storage_path: location.path,
    }) as Record<string, unknown>[];
    transcript = ready[0] ?? null;
    if (
      !transcript || transcript.status !== "ready" ||
      typeof transcript.transcript_text !== "string" ||
      !transcript.transcript_text.trim()
    ) {
      throw new AnalysisError(409, "video_transcript_not_ready", 30);
    }
  }
  const parts = ["title", "summary", "category", "body"].map((field) => {
    const value = resource[field];
    return typeof value === "string" && value.trim()
      ? `${field}: ${value.trim()}`
      : "";
  });
  if (Array.isArray(resource.tags)) {
    const tags = resource.tags.filter((v): v is string =>
      typeof v === "string" && !!v.trim()
    );
    if (tags.length) parts.push(`existing tags: ${tags.join(", ")}`);
  }
  if (transcript) parts.push(`transcript: ${transcript.transcript_text}`);
  return {
    resource,
    transcript,
    title: String(resource.title ?? ""),
    text: parts.filter(Boolean).join("\n\n"),
  };
}
export function createBackend(
  projectUrl: string,
  serviceKey: string,
  signal: AbortSignal,
): Backend {
  return async (path, body) => {
    const response = await fetch(`${projectUrl}/rest/v1/${path}`, {
      method: body === undefined ? "GET" : "POST",
      redirect: "error",
      headers: { apikey: serviceKey, "Content-Type": "application/json" },
      body: body === undefined ? undefined : JSON.stringify(body),
      signal,
    });
    if (!response.ok) {
      const error = await response.json().catch(() => ({}));
      if (error.code === "40001") {
        throw new AnalysisError(409, "resource_changed", 1);
      }
      if (error.code === "42501") {
        throw new AnalysisError(403, "resource_analysis_forbidden");
      }
      throw new AnalysisError(503, "resource_backend_unavailable", 5);
    }
    return await response.json();
  };
}
