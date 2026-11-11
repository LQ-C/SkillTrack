import "jsr:@supabase/functions-js@2.119.0/edge-runtime.d.ts";
import { createEmbedder, RecommendationError } from "./semantic.js";
// Native Edge Runtime API documented by Supabase. The published functions-js
// declaration currently omits this global; ordinary Deno does not provide it.
declare const Supabase: {
  ai: {
    Session: new (model: "gte-small") => {
      run(
        text: string,
        options: { mean_pool: boolean; normalize: boolean },
      ): Promise<number[] | Float32Array>;
    };
  };
};
let embedder: ReturnType<typeof createEmbedder> | undefined;
export function nativeEmbedder() {
  try {
    return embedder ??= createEmbedder(new Supabase.ai.Session("gte-small"));
  } catch {
    throw new RecommendationError(503, "embedding_runtime_unavailable");
  }
}
