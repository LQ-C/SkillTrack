import { withSupabase } from "npm:@supabase/server@1";
import { createRecommendationHandler } from "./handler.ts";
import {
  adminClient,
  rankingConfig,
  SupabaseRecommendationStore,
} from "./store.ts";
import { nativeEmbedder } from "../_shared/recommendations/runtime.ts";
import { failure } from "../_shared/recommendations/http.js";
export default {
  fetch: withSupabase({ auth: "user" }, async (request, context) => {
    try {
      const store = new SupabaseRecommendationStore(
        adminClient(),
        context.supabase,
      );
      return await createRecommendationHandler({
        userId: context.userClaims?.id ?? null,
        store,
        persistence: store,
        getEmbedder: nativeEmbedder,
        config: rankingConfig(),
      })(request);
    } catch (error) {
      return failure(error);
    }
  }),
};
