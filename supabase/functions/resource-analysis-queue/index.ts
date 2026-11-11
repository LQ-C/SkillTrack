import { drainImage } from "./images.ts";
import { drainEmbedding } from "../_shared/recommendations/indexer.ts";
import { nativeEmbedder } from "../_shared/recommendations/runtime.ts";
import { GeminiTagProvider } from "./gemini.ts";
import { createBackend } from "./store.ts";
import { createQueueHandler, drainOne } from "./processor.ts";

Deno.serve(createQueueHandler(
  () => Deno.env.get("RESOURCE_ANALYSIS_CRON_SECRET"),
  async (draftResourceId) => {
    const url = Deno.env.get("SUPABASE_URL")?.replace(/\/$/, "");
    const key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    if (!url || !key) throw new Error("Backend configuration unavailable");
    // Longer backend budget permits recording failure after the analysis deadline.
    const backend = createBackend(url, key, AbortSignal.timeout(75_000));
    const provider = new GeminiTagProvider({
      apiKey: () => Deno.env.get("GEMINI_API_KEY"),
      model: Deno.env.get("GEMINI_RESOURCE_TAG_MODEL"),
    });
    const [analysis, indexing, images] = await Promise.allSettled([
      drainOne(
        backend,
        provider,
        url,
        Deno.env.get("RESOURCE_VIDEO_BUCKET") ?? "marketplace-videos",
        draftResourceId,
        undefined,
        Deno.env.get("RESOURCE_PDF_BUCKET") ?? "marketplace-documents",
        Deno.env.get("RESOURCE_IMAGE_BUCKET") ?? "marketplace-documents",
      ),
      drainEmbedding(backend, nativeEmbedder),
      Promise.resolve().then(() =>
        drainImage(
          backend,
          new GeminiTagProvider({
            apiKey: () => Deno.env.get("GEMINI_API_KEY"),
            model: Deno.env.get("GEMINI_RESOURCE_IMAGE_MODEL") ??
              Deno.env.get("GEMINI_RESOURCE_TAG_MODEL"),
          }),
          url,
          key,
          Deno.env.get("RESOURCE_IMAGE_BUCKET") ?? "marketplace-documents",
          draftResourceId,
        )
      ),
    ]);
    if (analysis.status === "rejected") throw analysis.reason;
    return {
      ...analysis.value,
      images: images.status === "fulfilled"
        ? images.value
        : { outcome: "unavailable" },
      indexing: indexing.status === "fulfilled"
        ? indexing.value
        : { outcome: "unavailable" },
    };
  },
));
