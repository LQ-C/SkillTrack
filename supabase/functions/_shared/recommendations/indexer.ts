import {
  buildResourceText,
  RecommendationError,
  resourceTerms,
  signals,
  validateVector,
} from "./semantic.js";
import type { Backend } from "../../resource-analysis-queue/store.ts";
export type Embedder = { embed(text: string): Promise<number[]> };

export async function withEmbeddingDeadline(
  embedder: Embedder,
  text: string,
  timeoutMs = 55000,
): Promise<number[]> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  try {
    return validateVector(
      await Promise.race([
        embedder.embed(text),
        new Promise<never>((_, reject) => {
          timer = setTimeout(
            () => reject(new RecommendationError(503, "embedding_unavailable")),
            timeoutMs,
          );
        }),
      ]),
    );
  } finally {
    clearTimeout(timer);
  }
}

export async function drainEmbedding(
  backend: Backend,
  getEmbedder: () => Embedder,
) {
  await backend("rpc/backfill_resource_embeddings", { p_limit: 25 });
  const job = await backend("rpc/claim_resource_embedding", {}) as {
    resource_id: string;
    claim_token: string;
    source: Record<string, unknown> | null;
  } | null;
  if (!job) return { processed: 0, outcome: "idle" };
  try {
    if (!job.source) throw new RecommendationError(409, "source_changed");
    const source = job.source;
    const embedding = await withEmbeddingDeadline(
      getEmbedder(),
      buildResourceText(source),
    );
    const terms = resourceTerms(source);
    const tech = signals(
      [source.title, source.description, ...terms.keywords, ...terms.topic_tags]
        .join(" "),
    );
    const saved = await backend("rpc/complete_resource_embedding", {
      p_resource_id: job.resource_id,
      p_claim_token: job.claim_token,
      p_source_version: source.source_version,
      p_embedding: embedding,
      p_keywords: terms.keywords,
      p_topic_tags: terms.topic_tags,
      p_domains: tech.domains,
      p_frameworks: tech.frameworks,
    });
    if (saved !== true) throw new RecommendationError(409, "source_changed");
    return { processed: 1, outcome: "ready" };
  } catch (error) {
    const code =
      error instanceof RecommendationError && error.code === "source_changed"
        ? "source_changed"
        : "embedding_unavailable";
    const recorded = await backend("rpc/fail_resource_embedding", {
      p_resource_id: job.resource_id,
      p_claim_token: job.claim_token,
      p_error_code: code,
    });
    return {
      processed: 1,
      outcome: recorded === true ? "attempt_failed" : "claim_lost",
    };
  }
}
