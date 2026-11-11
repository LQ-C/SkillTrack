import { RecommendationError } from "./semantic.js";
export const json = (body, status = 200) =>
  Response.json(body, {
    status,
    headers: { "Cache-Control": "no-store" },
  });
export async function readBody(request) {
  if (request.method !== "POST") {
    throw new RecommendationError(405, "post_required");
  }
  // Bounded streaming also covers chunked requests without Content-Length.
  const reader = request.body?.getReader();
  if (!reader) throw new RecommendationError(400, "invalid_json");
  const chunks = [];
  let length = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      length += value.length;
      if (length > 2048) {
        await reader.cancel();
        throw new RecommendationError(413, "request_too_large");
      }
      chunks.push(value);
    }
    const buffer = new Uint8Array(length);
    let offset = 0;
    for (const chunk of chunks) {
      buffer.set(chunk, offset);
      offset += chunk.length;
    }
    const body = JSON.parse(new TextDecoder().decode(buffer));
    if (!body || typeof body !== "object" || Array.isArray(body)) {
      throw new Error();
    }
    return body;
  } catch (error) {
    if (error instanceof RecommendationError) throw error;
    throw new RecommendationError(400, "invalid_json");
  } finally {
    reader.releaseLock();
  }
}
export function failure(error) {
  return json({
    error: error instanceof RecommendationError
      ? error.code
      : "recommendation_unavailable",
    recommendations: [],
  }, error instanceof RecommendationError ? error.status : 503);
}
