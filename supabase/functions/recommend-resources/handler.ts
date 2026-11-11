import {
  recommendAndSave,
  type RecommendationPersistence,
} from "../_shared/recommendations/persistence.ts";
import {
  DEFAULT_CONFIG,
  RecommendationError,
} from "../_shared/recommendations/semantic.js";
import { failure, json, readBody } from "../_shared/recommendations/http.js";
import type { Embedder } from "../_shared/recommendations/indexer.ts";
import {
  type RecommendationStore,
  type RequestMode,
} from "../_shared/recommendations/recommend.ts";
export type {
  Recommendation,
  RecommendationStore,
  RequestMode,
  TaskContext,
} from "../_shared/recommendations/recommend.ts";
export function createRecommendationHandler(deps: {
  userId: string | null;
  store: RecommendationStore;
  getEmbedder: () => Embedder;
  config?: typeof DEFAULT_CONFIG;
  persistence: RecommendationPersistence;
}) {
  return async (request: Request): Promise<Response> => {
    try {
      if (!deps.userId) throw new RecommendationError(401, "unauthorized");
      const body = await readBody(request);
      if (
        Object.keys(body).some((key) => key !== "task_id" && key !== "mode") ||
        ("mode" in body && body.mode !== "automatic" &&
          body.mode !== "manual") ||
        typeof body.task_id !== "string" ||
        !/^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(body.task_id)
      ) throw new RecommendationError(400, "invalid_task_id");
      const taskId = body.task_id;
      const mode: RequestMode = body.mode === "manual" ? "manual" : "automatic";
      const result = await recommendAndSave(
        { ...deps, userId: deps.userId },
        deps.persistence,
        taskId,
        mode,
      );
      return json({
        generated: result.generated,
        status: result.status,
        recommendations: result.recommendations,
      });
    } catch (error) {
      return failure(error);
    }
  };
}
