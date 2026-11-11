import {
  AnalysisError,
  type Labels,
  outputSchema,
  validateLabels,
} from "./generator.ts";
import { type Backend, videoLocation } from "./store.ts";

export const MAX_IMAGE_BYTES = 5 * 1024 * 1024;
export type ImageInput = {
  bytes: Uint8Array;
  mimeType: "image/png" | "image/jpeg";
};
export interface ImageProvider {
  generateImage(
    metadata: string,
    image: ImageInput,
    signal: AbortSignal,
  ): Promise<unknown>;
}
export const imageOutputSchema = {
  ...outputSchema,
  properties: {
    description: { type: "string", minLength: 1, maxLength: 4000 },
    ...outputSchema.properties,
  },
  required: ["description", "keywords", "topic_tags"],
};
export function validateImageAnalysis(
  value: unknown,
): Labels & { description: string } {
  if (
    !value || typeof value !== "object" || Array.isArray(value) ||
    Object.keys(value).sort().join(",") !== "description,keywords,topic_tags"
  ) {
    throw new AnalysisError(502, "gemini_response_invalid");
  }
  const raw = value as Record<string, unknown>;
  if (
    typeof raw.description !== "string" || /[\p{Cc}]/u.test(raw.description)
  ) {
    throw new AnalysisError(502, "gemini_response_invalid");
  }
  const description = raw.description.normalize("NFKC").trim().replace(
    /\s+/gu,
    " ",
  );
  if (!description || description.length > 4000) {
    throw new AnalysisError(502, "gemini_response_invalid");
  }
  return {
    description,
    ...validateLabels({ keywords: raw.keywords, topic_tags: raw.topic_tags }),
  };
}

// Inspect the container, not just an extension or caller-supplied MIME. No image
// decoding or unbounded decompression is performed in the Edge runtime.
export function imageMime(bytes: Uint8Array): ImageInput["mimeType"] {
  if (bytes.length > MAX_IMAGE_BYTES) {
    throw new AnalysisError(413, "image_too_large");
  }
  const invalid = (): never => {
    throw new AnalysisError(422, "image_invalid");
  };
  const dimensions = (width: number, height: number) => {
    if (
      !width || !height || width > 8192 || height > 8192 ||
      width * height > 16_000_000
    ) {
      throw new AnalysisError(413, "image_too_large");
    }
  };
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  if (
    bytes.length >= 8 &&
    [137, 80, 78, 71, 13, 10, 26, 10].every((v, i) => bytes[i] === v)
  ) {
    let offset = 8, header = false, data = false;
    while (offset + 12 <= bytes.length) {
      const length = view.getUint32(offset);
      if (length > bytes.length - offset - 12) invalid();
      const type = String.fromCharCode(
        ...bytes.subarray(offset + 4, offset + 8),
      );
      let crc = 0xffffffff;
      for (let i = offset + 4; i < offset + 8 + length; i++) {
        crc ^= bytes[i];
        for (let bit = 0; bit < 8; bit++) {
          crc = (crc >>> 1) ^ ((crc & 1) ? 0xedb88320 : 0);
        }
      }
      if (((crc ^ 0xffffffff) >>> 0) !== view.getUint32(offset + 8 + length)) {
        invalid();
      }
      if (!header && type !== "IHDR") invalid();
      if (type === "IHDR") {
        if (header || length !== 13) invalid();
        dimensions(view.getUint32(offset + 8), view.getUint32(offset + 12));
        header = true;
      }
      if (type === "acTL") throw new AnalysisError(422, "image_unsupported");
      if (type === "IDAT" && length > 0) data = true;
      offset += length + 12;
      if (type === "IEND") {
        if (!header || !data || length !== 0 || offset !== bytes.length) {
          invalid();
        }
        return "image/png";
      }
    }
    return invalid();
  }
  if (bytes.length >= 4 && bytes[0] === 0xff && bytes[1] === 0xd8) {
    let offset = 2, frame = false, scan = false;
    while (offset < bytes.length) {
      if (bytes[offset++] !== 0xff) invalid();
      while (bytes[offset] === 0xff) offset++;
      const marker = bytes[offset++];
      if (marker === 0xd9) {
        if (!frame || !scan || offset !== bytes.length) invalid();
        return "image/jpeg";
      }
      if (offset + 2 > bytes.length) invalid();
      const length = view.getUint16(offset);
      if (length < 2 || offset + length > bytes.length) invalid();
      if ([0xc0, 0xc1, 0xc2].includes(marker)) {
        if (length < 8) invalid();
        dimensions(view.getUint16(offset + 5), view.getUint16(offset + 3));
        frame = true;
      }
      offset += length;
      if (marker === 0xda) {
        if (!frame) invalid();
        scan = true;
        while (offset < bytes.length) {
          if (bytes[offset] !== 0xff) {
            offset++;
            continue;
          }
          const next = bytes[offset + 1];
          if (next === 0 || (next >= 0xd0 && next <= 0xd7)) {
            offset += 2;
            continue;
          }
          break;
        }
      }
    }
    return invalid();
  }
  throw new AnalysisError(422, "image_unsupported");
}

export async function downloadImage(
  projectUrl: string,
  serviceKey: string,
  location: { bucket: string; path: string },
  storedMime: unknown,
  signal: AbortSignal,
  transport: typeof fetch = fetch,
  objectEtag?: string | null,
): Promise<ImageInput> {
  const mime = typeof storedMime === "string" ? storedMime.toLowerCase() : "";
  if (!["image/png", "image/jpeg"].includes(mime)) {
    throw new AnalysisError(422, "image_unsupported");
  }
  const expectedEtag = objectEtag?.replace(/^W\//, "").replace(/^"|"$/g, "");
  if (expectedEtag && !/^[a-zA-Z0-9._:-]{1,128}$/.test(expectedEtag)) {
    throw new AnalysisError(422, "image_configuration_invalid");
  }
  try {
    const path = [location.bucket, ...location.path.split("/")].map(
      encodeURIComponent,
    ).join("/");
    const response = await transport(
      `${projectUrl}/storage/v1/object/authenticated/${path}`,
      {
        headers: {
          apikey: serviceKey,
          Authorization: `Bearer ${serviceKey}`,
          ...(expectedEtag ? { "If-Match": `"${expectedEtag}"` } : {}),
        },
        redirect: "error",
        cache: "no-store",
        signal: AbortSignal.any([signal, AbortSignal.timeout(10_000)]),
      },
    );
    if (response.status === 412) {
      await response.body?.cancel();
      throw new AnalysisError(409, "source_replaced");
    }
    if (!response.ok) {
      await response.body?.cancel();
      throw new AnalysisError(503, "image_download_failed");
    }
    if (
      expectedEtag &&
      response.headers.get("ETag")?.replace(/^W\//, "").replace(
          /^"|"$/g,
          "",
        ) !== expectedEtag
    ) {
      await response.body?.cancel();
      throw new AnalysisError(409, "source_replaced");
    }
    if (
      response.headers.get("Content-Type")?.split(";")[0].trim()
        .toLowerCase() !== mime
    ) {
      await response.body?.cancel();
      throw new AnalysisError(422, "image_mime_mismatch");
    }
    if (Number(response.headers.get("Content-Length")) > MAX_IMAGE_BYTES) {
      await response.body?.cancel();
      throw new AnalysisError(413, "image_too_large");
    }
    const reader = response.body?.getReader();
    if (!reader) throw new AnalysisError(422, "image_invalid");
    const chunks: Uint8Array[] = [];
    let size = 0;
    try {
      while (true) {
        const next = await reader.read();
        if (next.done) break;
        size += next.value.length;
        if (size > MAX_IMAGE_BYTES) {
          await reader.cancel();
          throw new AnalysisError(413, "image_too_large");
        }
        chunks.push(next.value);
      }
    } finally {
      reader.releaseLock();
    }
    const bytes = new Uint8Array(size);
    let offset = 0;
    for (const chunk of chunks) {
      bytes.set(chunk, offset);
      offset += chunk.length;
    }
    const actual = imageMime(bytes);
    if (actual !== mime) throw new AnalysisError(422, "image_mime_mismatch");
    return { bytes, mimeType: actual };
  } catch (error) {
    if (error instanceof AnalysisError) throw error;
    throw new AnalysisError(503, "image_download_failed");
  }
}

type ImageJob = {
  id: string;
  claim_token: string;
  resource_id: string;
  storage_bucket: string;
  storage_path: string;
  mime_type: unknown;
  object_etag?: string | null;
  resource: Record<string, unknown>;
};
export async function drainImage(
  backend: Backend,
  provider: ImageProvider,
  projectUrl: string,
  serviceKey: string,
  bucket: string,
  draftResourceId: string | null = null,
  signal = AbortSignal.timeout(60_000),
  transport: typeof fetch = fetch,
) {
  const job = await backend("rpc/claim_resource_image", {
    p_project_url: projectUrl,
    p_bucket: bucket,
    p_draft_resource_id: draftResourceId,
  }) as ImageJob | null;
  if (!job) return { processed: 0, outcome: "idle" };
  try {
    const r = job.resource;
    if (
      r.id !== job.resource_id || r.kind !== "Reading" ||
      r.moderation_hidden !== false ||
      !(r.status === "published" ||
        (r.status === "draft" && r.id === draftResourceId))
    ) {
      throw new AnalysisError(409, "source_replaced");
    }
    let location;
    try {
      location = videoLocation(r.external_url, projectUrl, bucket);
    } catch {
      throw new AnalysisError(422, "image_configuration_invalid");
    }
    if (
      location.bucket !== job.storage_bucket ||
      location.path !== job.storage_path
    ) {
      throw new AnalysisError(409, "source_replaced");
    }
    const image = await downloadImage(
      projectUrl,
      serviceKey,
      location,
      job.mime_type,
      signal,
      transport,
      job.object_etag,
    );
    const metadata = JSON.stringify({
      title: r.title,
      summary: r.summary,
      category: r.category,
      body: r.body,
      tags: r.tags,
    }).slice(0, 12000);
    const analysis = validateImageAnalysis(
      await provider.generateImage(metadata, image, signal),
    );
    const saved = await backend("rpc/complete_resource_image", {
      p_extraction_id: job.id,
      p_claim_token: job.claim_token,
      p_resource: r,
      p_description: analysis.description,
      p_keywords: analysis.keywords,
      p_topic_tags: analysis.topic_tags,
    });
    if (saved !== true) throw new AnalysisError(409, "source_replaced");
    return { processed: 1, outcome: "ready" };
  } catch (error) {
    let code = error instanceof AnalysisError ? error.code : "analysis_failed";
    if (code === "resource_analysis_forbidden") {
      code = "source_replaced";
    }
    const allowed = [
      "image_invalid",
      "image_mime_mismatch",
      "image_unsupported",
      "image_too_large",
      "image_download_failed",
      "image_configuration_invalid",
      "source_replaced",
      "resource_changed",
      "gemini_response_invalid",
      "gemini_rate_limited",
      "gemini_unavailable",
      "gemini_not_configured",
      "analysis_timeout",
    ];
    if (!allowed.includes(code)) code = "analysis_failed";
    const saved = await backend("rpc/fail_resource_image", {
      p_extraction_id: job.id,
      p_claim_token: job.claim_token,
      p_error_code: code,
      p_retry_after_seconds: error instanceof AnalysisError
        ? error.retryAfter ?? 60
        : 60,
    });
    return {
      processed: 1,
      outcome: saved === true ? "attempt_failed" : "claim_lost",
      error: code,
    };
  }
}
