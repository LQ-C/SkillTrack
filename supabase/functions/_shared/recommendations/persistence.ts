import { MODEL_ID, RecommendationError, TEXT_VERSION } from "./semantic.js";
import { recommendForTask, type RequestMode } from "./recommend.ts";
export type SavedRecommendations = {
  generated: boolean;
  generation_id?: string;
  generated_at?: string;
  stalled_at?: string | null;
  status: string;
  task_version?: string;
  sources?: { resource_id: string; source_version: string }[];
  recommendations: {
    resource_id: string;
    title: string;
    summary: string;
    type: string;
  }[];
};
export interface RecommendationPersistence {
  begin(
    taskId: string,
    userId: string,
    mode: RequestMode,
  ): Promise<
    { cached: boolean; token?: string; result?: SavedRecommendations }
  >;
  complete(
    taskId: string,
    userId: string,
    token: string,
    sources: { resource_id: string; source_version: string }[],
    model: string,
    textVersion: string,
  ): Promise<SavedRecommendations>;
  fail(taskId: string, userId: string, token: string): Promise<void>;
}
export async function recommendAndSave(
  deps: Parameters<typeof recommendForTask>[0],
  persistence: RecommendationPersistence,
  taskId: string,
  mode: RequestMode = "automatic",
): Promise<SavedRecommendations> {
  const claim = await persistence.begin(taskId, deps.userId, mode);
  if (claim.cached && claim.result) return claim.result;
  if (!claim.token) throw new RecommendationError(409, "recommendation_busy");
  try {
    const result = await recommendForTask(deps, taskId, mode);
    if (result.status === "not_stalled") {
      throw new RecommendationError(409, "task_changed");
    }
    return await persistence.complete(
      taskId,
      deps.userId,
      claim.token,
      "sources" in result ? result.sources ?? [] : [],
      MODEL_ID,
      TEXT_VERSION,
    );
  } catch (error) {
    // If the response was lost after commit, fail cannot erase the saved set.
    await persistence.fail(taskId, deps.userId, claim.token).catch(() => {});
    throw error;
  }
}
