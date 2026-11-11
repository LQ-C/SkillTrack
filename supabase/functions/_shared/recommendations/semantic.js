// Adapted from Recommendation_model: same gte-small pooling, text rules and hybrid ranking.
import {
  extractKeywords,
  extractTopicTags,
  normalize,
  normalizeKeywords,
  normalizeTopicTags,
} from "./terms.js";

export const MODEL_ID = "gte-small";
export const DIMENSIONS = 384;
export const TEXT_VERSION = "skilltrack-v1-chunk400-mean-l2";
// Provisional until calibrated with native runtime embeddings on validation.
export const DEFAULT_CONFIG = Object.freeze({
  minSimilarity: 0.65,
  minScore: 0.5,
  semanticWeight: 0.75,
  keywordWeight: 0.7,
});

export class RecommendationError extends Error {
  constructor(status, code) {
    super(code);
    this.status = status;
    this.code = code;
  }
}
const clean = (value, max) =>
  String(value ?? "").normalize("NFKC")
    .replace(/\s+/gu, " ").trim().slice(0, max);
export function resourceTerms(source) {
  return {
    keywords: normalizeKeywords(source.keywords ?? []),
    topic_tags: normalizeTopicTags(source.topic_tags ?? []),
  };
}
export function buildResourceText(source) {
  const terms = resourceTerms(source);
  return [
    ["Title", source.title, 300],
    ["Description", source.description, 1000],
    ["Keywords", terms.keywords.join(", "), 600],
    ["Topics", terms.topic_tags.join(", "), 600],
    ["PDF", source.pdf_text, 1000],
    ["Transcript", source.transcript, 1000],
  ]
    .map(([label, text, max]) => [label, clean(text, max)])
    .filter(([, text]) => text).map(([label, text]) => `${label}: ${text}`)
    .join("\n");
}
export function buildTaskText(task) {
  if (
    typeof task?.title !== "string" || typeof task?.description !== "string" ||
    !task.title.trim() || task.title.length > 300 ||
    task.description.length > 4000
  ) {
    throw new RecommendationError(400, "invalid_task");
  }
  return `Title: ${clean(task.title, 300)}\nDescription: ${
    clean(task.description, 4000)
  }`;
}
export function validateVector(value) {
  const vector = ArrayBuffer.isView(value) ? Array.from(value) : value;
  if (
    !Array.isArray(vector) || vector.length !== DIMENSIONS ||
    vector.some((x) => typeof x !== "number" || !Number.isFinite(x)) ||
    Math.hypot(...vector) < 1e-10
  ) {
    throw new RecommendationError(503, "invalid_embedding");
  }
  return vector;
}
export function createEmbedder(session) {
  return {
    model: MODEL_ID,
    textVersion: TEXT_VERSION,
    async embed(text) {
      if (!text?.trim() || text.length > 6000) {
        throw new RecommendationError(
          400,
          "invalid_embedding_text",
        );
      }
      // Bound chunks by characters so code/rare words cannot silently exceed the
      // model's 512-token window. Both query and resource paths use this function.
      const chunks = text.match(/[\s\S]{1,400}/gu);
      const sum = Array(DIMENSIONS).fill(0);
      try {
        for (const chunk of chunks) {
          const vector = validateVector(
            await session.run(chunk, { mean_pool: true, normalize: true }),
          );
          vector.forEach((x, i) => {
            sum[i] += x;
          });
        }
        const length = Math.hypot(...sum);
        return validateVector(sum.map((x) => x / length));
      } catch {
        throw new RecommendationError(503, "embedding_unavailable");
      }
    },
  };
}
export function assertModel(embedder) {
  if (embedder.model !== MODEL_ID || embedder.textVersion !== TEXT_VERSION) {
    throw new RecommendationError(503, "embedding_model_mismatch");
  }
}
export async function sha256(text) {
  const buffer = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(text),
  );
  return Array.from(
    new Uint8Array(buffer),
    (x) => x.toString(16).padStart(2, "0"),
  ).join("");
}
const FRAMEWORKS = [
  "flutter",
  "react native",
  "react",
  "angular",
  "vue",
  "express",
  "django",
  "flask",
  "laravel",
  "spring boot",
  "asp net",
];
export function signals(text, domain = "", framework = "") {
  let normalized = ` ${normalize([text, framework].join(" "))} `;
  const native = normalized.includes(" react native ");
  const frameworks = FRAMEWORKS.filter((f) =>
    !(native && f === "react") && normalized.includes(` ${f} `)
  );
  const explicitDomain = normalize(domain);
  const domains = new Set();
  if (
    /mobile|android|ios/.test(explicitDomain) ||
    /\b(flutter|dart|react native|android|ios)\b/.test(normalized)
  ) domains.add("mobile");
  normalized = normalized.replaceAll("react native", "");
  if (
    /web|frontend|backend/.test(explicitDomain) ||
    /\b(html|css|react|angular|vue|express|django|flask|laravel|spring boot|asp net)\b/
      .test(normalized)
  ) domains.add("web");
  return { frameworks, domains: [...domains].sort() };
}
export function querySignals(task) {
  const text = [task.title, task.description].join(" ");
  return {
    keywords: extractKeywords(text),
    topic_tags: extractTopicTags(text),
    ...signals(text),
  };
}
export function jaccard(a, b) {
  const left = new Set(a), right = new Set(b);
  const count = [...left].filter((x) => right.has(x)).length;
  return count ? count / new Set([...left, ...right]).size : 0;
}
export function validateConfig(config) {
  for (const key of Object.keys(DEFAULT_CONFIG)) {
    if (!Number.isFinite(config[key]) || config[key] < 0 || config[key] > 1) {
      throw new RecommendationError(503, "invalid_ranking_config");
    }
  }
  return config;
}
export function scoreCandidate(
  query,
  resource,
  similarity,
  config = DEFAULT_CONFIG,
) {
  validateConfig(config);
  const lexical =
    config.keywordWeight * jaccard(query.keywords, resource.keywords) +
    (1 - config.keywordWeight) * jaccard(query.topic_tags, resource.topic_tags);
  const overlap = (a, b) => a.some((x) => b.includes(x));
  if (
    query.domains.length && resource.domains.length &&
    !overlap(query.domains, resource.domains)
  ) return null;
  if (
    query.frameworks.length && resource.frameworks.length &&
    !overlap(query.frameworks, resource.frameworks)
  ) return null;
  // Metadata absent/generic task: require lexical evidence in addition to meaning.
  if (
    (!query.frameworks.length || !resource.frameworks.length) && lexical <= 0
  ) return null;
  const score = config.semanticWeight * similarity +
    (1 - config.semanticWeight) * lexical;
  return similarity >= config.minSimilarity && score >= config.minScore
    ? { similarity, score, lexical_score: lexical }
    : null;
}
export function cosine(a, b) {
  a = validateVector(a);
  b = validateVector(b);
  return Math.max(
    -1,
    Math.min(
      1,
      a.reduce((sum, x, i) => sum + x * b[i], 0) /
        (Math.hypot(...a) * Math.hypot(...b)),
    ),
  );
}
