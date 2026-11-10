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
    return await drainOne(
      backend,
      provider,
      url,
      Deno.env.get("RESOURCE_VIDEO_BUCKET") ?? "marketplace-videos",
      draftResourceId,
    );
  },
));
