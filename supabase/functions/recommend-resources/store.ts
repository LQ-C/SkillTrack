import type {
  RecommendationPersistence,
  SavedRecommendations,
} from "../_shared/recommendations/persistence.ts";
import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2";
import {
  DEFAULT_CONFIG,
  MODEL_ID,
  RecommendationError,
  TEXT_VERSION,
  validateConfig,
} from "../_shared/recommendations/semantic.js";
import type {
  Recommendation,
  RecommendationStore,
  RequestMode,
  TaskContext,
} from "../_shared/recommendations/recommend.ts";
export function rankingConfig() {
  const names = {
    minSimilarity: "RECOMMENDATION_MIN_SIMILARITY",
    minScore: "RECOMMENDATION_MIN_SCORE",
    semanticWeight: "RECOMMENDATION_SEMANTIC_WEIGHT",
    keywordWeight: "RECOMMENDATION_KEYWORD_WEIGHT",
  };
  return validateConfig(
    Object.fromEntries(
      Object.entries(names).map((
        [key, name],
      ) => [
        key,
        Deno.env.get(name) === undefined
          ? DEFAULT_CONFIG[key as keyof typeof DEFAULT_CONFIG]
          : Number(Deno.env.get(name)),
      ]),
    ),
  ) as typeof DEFAULT_CONFIG;
}
export function adminClient() {
  const url = Deno.env.get("SUPABASE_URL"),
    key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !key) {
    throw new RecommendationError(503, "missing_server_configuration");
  }
  return createClient(url, key, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
}
export class SupabaseRecommendationStore
  implements RecommendationStore, RecommendationPersistence {
  constructor(private admin: SupabaseClient, private user: SupabaseClient) {}
  async rpc(name: string, args: Record<string, unknown>) {
    const { data, error } = await this.admin.rpc(name, args).abortSignal(
      AbortSignal.timeout(15000),
    );
    if (error) throw new RecommendationError(503, "recommendation_unavailable");
    return data;
  }
  async begin(taskId: string, userId: string, mode: RequestMode) {
    return await this.rpc("begin_task_recommendations", {
      p_task_id: taskId,
      p_user_id: userId,
      p_mode: mode,
    });
  }
  async complete(
    taskId: string,
    userId: string,
    token: string,
    sources: { resource_id: string; source_version: string }[],
    model: string,
    textVersion: string,
  ): Promise<SavedRecommendations> {
    return await this.rpc("complete_task_recommendations", {
      p_task_id: taskId,
      p_user_id: userId,
      p_token: token,
      p_sources: sources.map((s) => ({
        resource_id: s.resource_id,
        source_version: s.source_version,
      })),
      p_model_id: model,
      p_text_version: textVersion,
    });
  }
  async fail(taskId: string, userId: string, token: string): Promise<void> {
    await this.rpc("fail_task_recommendations", {
      p_task_id: taskId,
      p_user_id: userId,
      p_token: token,
    });
  }
  async loadTask(
    taskId: string,
    userId: string,
    mode: RequestMode = "automatic",
  ): Promise<TaskContext | null> {
    const rows = await this.rpc("recommendation_load_owned_task", {
      p_task_id: taskId,
      p_user_id: userId,
      p_mode: mode,
    });
    return rows?.[0] ?? null;
  }
  async visibleIds(): Promise<string[]> {
    const ids: string[] = [];
    const signal = AbortSignal.timeout(15000);
    // Keyset paging avoids an arbitrary candidate cap before relevance ranking.
    let after: string | undefined;
    while (true) {
      let query = this.user.from("learning_resources").select("id").eq(
        "status",
        "published",
      ).eq("moderation_hidden", false).order("id").limit(500);
      if (after) query = query.gt("id", after);
      const { data, error } = await query.abortSignal(signal);
      if (error) {
        throw new RecommendationError(503, "resource_access_unavailable");
      }
      for (const row of data ?? []) ids.push(row.id);
      if (!data || data.length < 500) return ids;
      after = data[data.length - 1].id;
    }
  }
  async search(
    ...[
      taskId,
      userId,
      task,
      ids,
      embedding,
      query,
      config,
      mode = "automatic",
    ]: Parameters<
      RecommendationStore["search"]
    >
  ): Promise<Recommendation[]> {
    return await this.rpc("match_resource_embeddings", {
      p_task_id: taskId,
      p_user_id: userId,
      p_mode: mode,
      p_task_version: task.source_version,
      p_visible_ids: ids,
      p_embedding: embedding,
      p_model_id: MODEL_ID,
      p_text_version: TEXT_VERSION,
      p_keywords: query.keywords,
      p_topic_tags: query.topic_tags,
      p_frameworks: query.frameworks,
      p_domains: query.domains,
      p_min_similarity: config.minSimilarity,
      p_min_score: config.minScore,
      p_semantic_weight: config.semanticWeight,
      p_keyword_weight: config.keywordWeight,
    });
  }
  async visibleDetails(ids: string[]) {
    const { data, error } = await this.user.from("learning_resources").select(
      "id,title,summary,kind,updated_at",
    ).in("id", ids).eq("status", "published").eq("moderation_hidden", false)
      .abortSignal(AbortSignal.timeout(15000));
    if (error) {
      throw new RecommendationError(503, "resource_access_unavailable");
    }
    return data ?? [];
  }
}
