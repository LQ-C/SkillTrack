import {
  buildTaskText,
  DEFAULT_CONFIG,
  querySignals,
  RecommendationError,
} from "./semantic.js";
import { type Embedder, withEmbeddingDeadline } from "./indexer.ts";
export type RequestMode = "automatic" | "manual";

export type TaskContext = {
  title: string;
  description: string;
  is_stalled: boolean;
  source_version: string;
};
export type Recommendation = {
  resource_id: string;
  title: string;
  summary: string | null;
  resource_type: string;
  source_version: string;
  resource_updated_at: string;
};
export interface RecommendationStore {
  loadTask(
    taskId: string,
    userId: string,
    mode?: RequestMode,
  ): Promise<TaskContext | null>;
  visibleIds(): Promise<string[]>;
  search(
    taskId: string,
    userId: string,
    task: TaskContext,
    ids: string[],
    embedding: number[],
    query: ReturnType<typeof querySignals>,
    config: typeof DEFAULT_CONFIG,
    mode?: RequestMode,
  ): Promise<Recommendation[]>;
  visibleDetails(
    ids: string[],
  ): Promise<
    {
      id: string;
      title: string;
      summary: string | null;
      kind: string;
      updated_at: string;
    }[]
  >;
}
export async function recommendForTask(
  deps: {
    userId: string;
    store: RecommendationStore;
    getEmbedder: () => Embedder;
    config?: typeof DEFAULT_CONFIG;
    embeddingTimeoutMs?: number;
  },
  taskId: string,
  mode: RequestMode = "automatic",
) {
  const task = await deps.store.loadTask(taskId, deps.userId, mode);
  if (!task) throw new RecommendationError(404, "task_not_found");
  if (mode === "automatic" && !task.is_stalled) {
    return ({ status: "not_stalled", recommendations: [] });
  }
  // These IDs come from the authenticated client's RLS query, never request data.
  const ids = await deps.store.visibleIds();
  if (!ids.length) return ({ status: "empty", recommendations: [] });
  const embedding = await withEmbeddingDeadline(
    deps.getEmbedder(),
    buildTaskText(task),
    deps.embeddingTimeoutMs,
  );
  const matches = await deps.store.search(
    taskId,
    deps.userId,
    task,
    ids,
    embedding,
    querySignals(task),
    deps.config ?? DEFAULT_CONFIG,
    mode,
  );
  const details = matches.length
    ? await deps.store.visibleDetails(matches.map((m) => m.resource_id))
    : [];
  // Recheck both task eligibility and resource RLS after inference/ranking.
  const current = await deps.store.loadTask(taskId, deps.userId, mode);
  if (!current) throw new RecommendationError(404, "task_not_found");
  if (mode === "automatic" && !current.is_stalled) {
    return ({ status: "not_stalled", recommendations: [] });
  }
  if (current.source_version !== task.source_version) {
    throw new RecommendationError(409, "task_changed");
  }
  const recommendations = matches.slice(0, 3).flatMap((m) => {
    const d = details.find((d) => d.id === m.resource_id);
    if (
      !d || d.title !== m.title || d.summary !== m.summary ||
      d.kind !== m.resource_type ||
      Date.parse(d.updated_at) !== Date.parse(m.resource_updated_at)
    ) return [];
    return [{
      resource_id: m.resource_id,
      title: m.title,
      summary: m.summary ?? "",
      type: m.resource_type,
    }];
  });
  return ({
    status: recommendations.length ? "ok" : "empty",
    task_version: task.source_version,
    sources: matches.filter((m) =>
      recommendations.some((r) => r.resource_id === m.resource_id)
    ),
    recommendations,
  });
}
