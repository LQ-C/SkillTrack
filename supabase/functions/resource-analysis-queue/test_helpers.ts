// Offline fixtures only; never imported by the deployed function.
import {
  AnalysisError,
  type Labels,
  type ResourceStore,
  type SavedAnalysis,
} from "./generator.ts";
import { type Backend, loadResourceSource } from "./store.ts";
export const resourceId = "10000000-0000-0000-0000-000000000001";
export const ownerId = "20000000-0000-0000-0000-000000000001";
export class ExampleDatabase {
  resource: Record<string, unknown> = {
    id: resourceId,
    author_id: ownerId,
    title: "Flutter interfaces",
    summary: "Build a mobile app",
    category: "Mobile development",
    body: "Use Dart widgets and Supabase authentication.",
    tags: ["Flutter"],
    kind: "Article",
    status: "draft",
    moderation_hidden: false,
    external_url: "",
    updated_at: "2026-11-10T00:00:00Z",
    created_at: "2026-11-10T00:00:00Z",
  };
  transcript: Record<string, unknown> | null = null;
  currentVersion = "v1";
  index = new Map<string, SavedAnalysis>();
  calls: string[] = [];
  saves = 0;
  backend: Backend = (path, body) =>
    Promise.resolve().then(() => {
      this.calls.push(path);
      if (path.startsWith("learning_resources?")) {
        return [structuredClone(this.resource)];
      }
      if (path === "rpc/read_ready_video_transcript") {
        return this.transcript?.status === "ready" &&
            this.transcript.source_version === this.currentVersion
          ? [structuredClone(this.transcript)]
          : [];
      }
      if (path === "rpc/save_resource_analysis") {
        const input = body as {
          p_user_id: string;
          p_resource: unknown;
          p_transcript: unknown;
          p_keywords: string[];
          p_topic_tags: string[];
        };
        if (
          input.p_user_id !== this.resource.author_id ||
          this.resource.moderation_hidden
        ) throw new AnalysisError(403, "resource_analysis_forbidden");
        if (
          JSON.stringify(input.p_resource) !== JSON.stringify(this.resource) ||
          JSON.stringify(input.p_transcript) !==
            JSON.stringify(this.transcript) ||
          (this.transcript &&
            this.transcript.source_version !== this.currentVersion)
        ) throw new AnalysisError(409, "resource_changed");
        const saved = {
          resource_id: resourceId,
          keywords: input.p_keywords,
          topic_tags: input.p_topic_tags,
          analysed_at: new Date(Date.UTC(2026, 10, 10, 0, 0, ++this.saves))
            .toISOString(),
        };
        this.index.set(resourceId, saved);
        return saved;
      }
      throw new Error("unexpected backend operation");
    });
  store(): ResourceStore {
    return {
      loadAuthorized: (userId, id) =>
        loadResourceSource(
          this.backend,
          "https://example.supabase.co",
          "marketplace-videos",
          userId,
          id,
        ),
      saveIfCurrent: async (userId, source, labels) =>
        await this.backend("rpc/save_resource_analysis", {
          p_user_id: userId,
          p_resource: source.resource,
          p_transcript: source.transcript,
          p_keywords: labels.keywords,
          p_topic_tags: labels.topic_tags,
        }) as SavedAnalysis,
    };
  }
}
export const exampleLabels: Labels = {
  keywords: ["flutter", "dart", "supabase"],
  topic_tags: ["mobile development", "authentication"],
};

// Mirrors the SQL fingerprint inputs, using a readable key for offline tests.
export function sourceVersion(
  resource: Record<string, unknown>,
  transcript: Record<string, unknown> | null,
) {
  return JSON.stringify([
    ...[
      "id",
      "author_id",
      "title",
      "summary",
      "category",
      "body",
      "tags",
      "kind",
      "external_url",
    ].map((k) => resource[k] ?? null),
    ...["id", "source_file_id", "source_version", "transcript_text"].map((k) =>
      transcript?.[k] ?? null
    ),
  ]);
}
