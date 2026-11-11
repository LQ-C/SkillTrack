import type { SupabaseClient } from "npm:@supabase/supabase-js@2";
import {
  rankingConfig,
  SupabaseRecommendationStore,
} from "../recommend-resources/store.ts";
import { recommendForTask } from "../_shared/recommendations/recommend.ts";
import type { Embedder } from "../_shared/recommendations/indexer.ts";
import type { Preferences, TaskCandidate } from "./generator.ts";

// Same matching pipeline; only visibility resolution differs because cron has
// no user access token. The RPC evaluates actual RLS as this recipient.
export class ScheduledRecommendationStore extends SupabaseRecommendationStore {
  constructor(admin: SupabaseClient, private recipient: string) {
    super(admin, admin);
  }
  override async visibleIds(): Promise<string[]> {
    const rows = await this.rpc("recommendation_resources_for_recipient", {
      p_user_id: this.recipient,
    });
    return (rows ?? []).map((r: { id: string }) => r.id);
  }
  override async visibleDetails(ids: string[]) {
    return await this.rpc("recommendation_resources_for_recipient", {
      p_user_id: this.recipient,
      p_ids: ids,
    }) ?? [];
  }
}
export type StalledAlertBackend = {
  state(task: TaskCandidate, episode: string): Promise<string>;
  match(
    task: TaskCandidate,
    timeoutMs: number,
  ): Promise<
    { resourceId: string; resourceVersion: string; taskVersion: string } | null
  >;
  commit(
    task: TaskCandidate,
    episode: string,
    match:
      | { resourceId: string; resourceVersion: string; taskVersion: string }
      | null,
  ): Promise<boolean>;
};
export function createStalledAlertDelivery(
  backend: StalledAlertBackend,
  clock = Date.now,
) {
  const deadline = clock() + 45000;
  return async (
    task: TaskCandidate,
    episode: string,
    preferences: Preferences,
  ): Promise<boolean> => {
    try {
      if (await backend.state(task, episode) !== "eligible") return false;
    } catch (error) {
      if (!preferences.stalled_task_enabled) throw error;
      // The atomic commit can still safely deliver fallback after a failed read.
      return await backend.commit(task, episode, null);
    }
    let match = null;
    // One bounded attempt, never a retry loop that can delay ordinary alerts.
    // If fallback is delivered, this period is finished. If both inserts fail,
    // the next scheduled run retries with the same persisted episode identity.
    if (preferences.recommendation_enabled && clock() < deadline) {
      try {
        let timer: ReturnType<typeof setTimeout> | undefined;
        try {
          match = await Promise.race([
            backend.match(task, Math.min(5000, deadline - clock())),
            new Promise<never>((_, reject) => {
              timer = setTimeout(
                () => reject(new Error("Recommendation attempt timed out")),
                Math.min(10000, deadline - clock()),
              );
            }),
          ]);
        } finally {
          clearTimeout(timer);
        }
      } catch {
        console.warn(
          "Stalled recommendation unavailable; attempting ordinary alert.",
        );
      }
    }
    try {
      return await backend.commit(task, episode, match);
    } catch (error) {
      if (!match || !preferences.stalled_task_enabled) throw error;
      // A policy/read failure during final validation also falls back. This
      // commit is idempotent even if the first response was lost after INSERT.
      return await backend.commit(task, episode, null);
    }
  };
}
export function scheduledStalledAlerts(
  admin: SupabaseClient,
  getEmbedder: () => Embedder,
) {
  const rpc = async (name: string, args: Record<string, unknown>) => {
    const { data, error } = await admin.rpc(name, args).abortSignal(
      AbortSignal.timeout(10000),
    );
    if (error) throw new Error("Stalled alert database request failed");
    return data;
  };
  return createStalledAlertDelivery({
    state: (task, episode) =>
      rpc("stalled_period_alert_state", {
        p_task_id: task.task_id,
        p_user_id: task.user_id,
        p_stalled_at: episode,
      }),
    async match(task, timeoutMs) {
      const result = await recommendForTask({
        userId: task.user_id,
        store: new ScheduledRecommendationStore(admin, task.user_id),
        getEmbedder,
        config: rankingConfig(),
        embeddingTimeoutMs: timeoutMs,
      }, task.task_id);
      if (!("sources" in result) || !result.sources?.length) return null;
      const first = result.sources[0];
      return {
        resourceId: first.resource_id,
        resourceVersion: first.source_version,
        taskVersion: result.task_version,
      };
    },
    commit: (task, episode, match) =>
      rpc("enqueue_stalled_period_alert", {
        p_task_id: task.task_id,
        p_user_id: task.user_id,
        p_stalled_at: episode,
        p_resource_id: match?.resourceId ?? null,
        p_resource_version: match?.resourceVersion ?? null,
        p_task_version: match?.taskVersion ?? null,
      }),
  });
}
