import {
  withSupabase,
} from "npm:@supabase/server@1";

import {
  GoogleGenAI,
} from "npm:@google/genai@2";

import {
  buildPrompt,
  currentDraftContext,
  existingTaskContext,
  outputSchema,
  parseGenerationMode,
  parseSourceMode,
  sanitizeGenerated,
  text,
  validDeadline,
} from "./generator.ts";

function jsonResponse(
  body: Record<string, unknown>,
  status = 200,
  extraHeaders: Record<string, string> = {},
): Response {
  return Response.json(
    body,
    {
      status,
      headers: {
        "Cache-Control": "no-store",
        ...extraHeaders,
      },
    },
  );
}

export default {
  fetch: withSupabase(
    {
      auth: "user",
    },
    async (req: Request) => {
      if (req.method !== "POST") {
        return jsonResponse(
          {
            error:
              "Use a POST request.",
          },
          405,
          {
            Allow: "POST",
          },
        );
      }

      let body: Record<string, unknown>;

      try {
        const value = await req.json();

        if (
          !value ||
          typeof value !== "object" ||
          Array.isArray(value)
        ) {
          throw new Error(
            "Invalid request",
          );
        }

        body = value as Record<
          string,
          unknown
        >;
      } catch {
        return jsonResponse(
          {
            error:
              "Send a JSON object.",
          },
          400,
        );
      }

      const projectName = text(
        body.projectName,
      );

      const description = text(
        body.description,
      );

      const deadline = text(
        body.deadline,
      );

      const constraints = text(body.constraints);
      if (constraints.length > 1000) {
        return jsonResponse(
          { error: "Constraints must be 1000 characters or fewer." },
          400,
        );
      }

      const mode = parseGenerationMode(
        body.generationMode,
      );

      if (
        !projectName ||
        projectName.length > 150
      ) {
        return jsonResponse(
          {
            error:
              "Project name is required and must be 150 characters or fewer.",
          },
          400,
        );
      }

      if (
        !description ||
        description.length > 4000
      ) {
        return jsonResponse(
          {
            error:
              "Description is required and must be 4000 characters or fewer.",
          },
          400,
        );
      }

      if (
        deadline &&
        !validDeadline(deadline)
      ) {
        return jsonResponse(
          {
            error:
              "Deadline must use a valid YYYY-MM-DD date.",
          },
          400,
        );
      }

      if (mode === null) {
        return jsonResponse(
          {
            error:
              "Invalid generation mode.",
          },
          400,
        );
      }

      const sourceMode =
        mode === "revise"
          ? parseSourceMode(
            body.sourceMode,
          )
          : null;

      const revisionFeedback =
        mode === "revise"
          ? text(
            body.revisionFeedback,
          )
          : "";

      const currentDraft =
        mode === "revise"
          ? currentDraftContext(
            body.currentDraft,
          )
          : [];

      if (mode === "revise") {
        if (sourceMode === null) {
          return jsonResponse(
            {
              error:
                "sourceMode must be initial or append.",
            },
            400,
          );
        }

        if (
          !revisionFeedback ||
          revisionFeedback.length > 1000
        ) {
          return jsonResponse(
            {
              error:
                "Revision feedback is required and must be 1000 characters or fewer.",
            },
            400,
          );
        }

        if (currentDraft.length === 0) {
          return jsonResponse(
            {
              error:
                "A current draft is required for revision.",
            },
            400,
          );
        }
      }

      const shouldReadExistingTasks =
        mode === "append" ||
        (
          mode === "revise" &&
          sourceMode === "append"
        );

      const existingTasks =
        shouldReadExistingTasks
          ? existingTaskContext(
            body.existingTasks,
          )
          : [];

      const apiKey = Deno.env.get(
        "GEMINI_API_KEY",
      );

      if (!apiKey) {
        return jsonResponse(
          {
            error:
              "Gemini is not configured.",
          },
          500,
        );
      }

      try {
        const ai = new GoogleGenAI({
          apiKey,
        });

        const result =
          await ai.interactions.create({
            model:
              "gemini-3.5-flash-lite",
            input: buildPrompt(
              mode,
              projectName,
              description,
              deadline,
              existingTasks,
              sourceMode,
              revisionFeedback,
              currentDraft,
              constraints,
            ),
            response_format: {
              type: "text",
              mime_type:
                "application/json",
              schema: outputSchema,
            },
          });

        const parsed = JSON.parse(
          result.output_text ?? "{}",
        );

        const protectExistingTasks =
          mode === "append" ||
          (
            mode === "revise" &&
            sourceMode === "append"
          );

        const response =
          sanitizeGenerated(
            parsed,
            mode,
            existingTasks,
            protectExistingTasks,
          );

        return jsonResponse(
          response,
        );
      } catch {
        /*
         * Do not log:
         * - Constraints
         * - Project description
         * - Existing task details
         * - Current draft
         * - Revision feedback
         * - Access token
         * - Gemini API key
         * - Complete AI response
         */
        console.error("Task generation failed.");

        return jsonResponse(
          {
            error:
              "Could not generate tasks. Please try again.",
          },
          502,
        );
      }
    },
  ),
};