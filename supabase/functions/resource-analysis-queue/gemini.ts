import {
  AnalysisError,
  buildPrompt,
  DEFAULT_MODEL,
  outputSchema,
  type TagProvider,
} from "./generator.ts";

type ProviderOptions = {
  apiKey: () => string | undefined;
  model?: string;
  fetch?: typeof fetch;
  sleep?: (ms: number, signal: AbortSignal) => Promise<void>;
};

function sleep(ms: number, signal: AbortSignal): Promise<void> {
  return new Promise((resolve, reject) => {
    if (signal.aborted) {
      return reject(new AnalysisError(504, "analysis_timeout"));
    }
    const cancel = () => {
      clearTimeout(timer);
      reject(new AnalysisError(504, "analysis_timeout"));
    };
    const timer = setTimeout(() => {
      signal.removeEventListener("abort", cancel);
      resolve();
    }, ms);
    signal.addEventListener("abort", cancel, { once: true });
  });
}

export class GeminiTagProvider implements TagProvider {
  readonly model: string;
  constructor(private readonly options: ProviderOptions) {
    this.model = options.model?.trim() || DEFAULT_MODEL;
    if (!/^[a-zA-Z0-9][a-zA-Z0-9._-]{0,99}$/.test(this.model)) {
      throw new AnalysisError(503, "gemini_model_invalid");
    }
  }

  async generate(
    title: string,
    text: string,
    signal: AbortSignal,
  ): Promise<unknown> {
    const key = this.options.apiKey()?.trim();
    if (!key) throw new AnalysisError(503, "gemini_not_configured");
    const transport = this.options.fetch ?? fetch;
    const pause = this.options.sleep ?? sleep;
    for (let attempt = 0; attempt < 2; attempt++) {
      let response: Response;
      try {
        response = await transport(
          "https://generativelanguage.googleapis.com/v1beta/models/" +
            this.model + ":generateContent",
          {
            method: "POST",
            redirect: "error",
            headers: {
              "Content-Type": "application/json",
              "x-goog-api-key": key,
            },
            body: JSON.stringify({
              contents: [{
                role: "user",
                parts: [{ text: buildPrompt(title, text) }],
              }],
              generationConfig: {
                temperature: 0,
                maxOutputTokens: 2048,
                responseMimeType: "application/json",
                responseJsonSchema: outputSchema,
              },
            }),
            signal: AbortSignal.any([signal, AbortSignal.timeout(15_000)]),
          },
        );
      } catch {
        if (signal.aborted) throw new AnalysisError(504, "analysis_timeout");
        if (attempt === 0) {
          await pause(500, signal);
          continue;
        }
        throw new AnalysisError(503, "gemini_unavailable");
      }
      if (!response.ok) {
        const header = response.headers.get("Retry-After");
        const retryAfter = header && /^\d+$/.test(header)
          ? Math.max(1, Math.min(Number(header), 86400))
          : header && Number.isFinite(Date.parse(header))
          ? Math.max(1, Math.ceil((Date.parse(header) - Date.now()) / 1000))
          : 5;
        await response.body?.cancel();
        const transient = [429, 500, 502, 503, 504].includes(response.status);
        if (transient && attempt === 0 && (!header || retryAfter <= 2)) {
          await pause(header ? retryAfter * 1000 : 500, signal);
          continue;
        }
        if (response.status === 429) {
          throw new AnalysisError(429, "gemini_rate_limited", retryAfter);
        }
        throw new AnalysisError(503, "gemini_unavailable");
      }
      try {
        const raw = await response.text();
        if (raw.length > 64_000) throw new Error();
        const body = JSON.parse(raw);
        const candidate = body.candidates?.[0];
        if (candidate?.finishReason !== "STOP") throw new Error();
        const text = candidate.content.parts
          .filter((part: { text?: unknown; thought?: boolean }) =>
            !part.thought && typeof part.text === "string"
          )
          .map((part: { text: string }) => part.text).join("");
        return JSON.parse(text);
      } catch {
        if (signal.aborted) throw new AnalysisError(504, "analysis_timeout");
        throw new AnalysisError(502, "gemini_response_invalid");
      }
    }
    throw new AnalysisError(503, "gemini_unavailable");
  }
}
