import {
  createClient,
} from "npm:@supabase/supabase-js@2";

import {
  generateNotifications,
  type NotificationInsert,
  type NotificationStore,
  type Preferences,
  type ProjectCandidate,
  type StagnationUpdate,
  type TaskCandidate,
} from "./generator.ts";

function required(name: string): string {
  const value = Deno.env.get(name);

  if (!value) {
    throw new Error(`Missing ${name}`);
  }

  return value;
}

async function matchesSecret(
  provided: string | null,
  expected: string,
): Promise<boolean> {
  if (!provided || !expected) {
    return false;
  }

  const encoder = new TextEncoder();

  const [left, right] = await Promise.all([
    crypto.subtle.digest(
      "SHA-256",
      encoder.encode(provided),
    ),
    crypto.subtle.digest(
      "SHA-256",
      encoder.encode(expected),
    ),
  ]);

  const a = new Uint8Array(left);
  const b = new Uint8Array(right);

  let difference = 0;

  for (let index = 0; index < a.length; index++) {
    difference |= a[index] ^ b[index];
  }

  return difference === 0;
}

Deno.serve(async (request) => {
  if (request.method !== "POST") {
    return Response.json(
      {
        error: "Method not allowed",
      },
      {
        status: 405,
        headers: {
          "Cache-Control": "no-store",
        },
      },
    );
  }

  const expectedSecret = Deno.env.get(
    "PROJECT_NOTIFICATION_CRON_SECRET",
  );

  const providedSecret = request.headers.get(
    "x-notification-cron-secret",
  );

  if (
    !expectedSecret ||
    !(await matchesSecret(
      providedSecret,
      expectedSecret,
    ))
  ) {
    return Response.json(
      {
        error: "Unauthorized",
      },
      {
        status: 401,
        headers: {
          "Cache-Control": "no-store",
        },
      },
    );
  }

  try {
    const admin = createClient(
      required("SUPABASE_URL"),
      required("SUPABASE_SERVICE_ROLE_KEY"),
      {
        auth: {
          persistSession: false,
          autoRefreshToken: false,
        },
      },
    );

    const store: NotificationStore = {
      async listProjects(
        offset,
        limit,
      ) {
        const { data, error } = await admin.rpc(
          "notification_project_candidates",
          {
            p_offset: offset,
            p_limit: limit,
          },
        );

        if (error) {
          throw error;
        }

        return (data ?? []) as ProjectCandidate[];
      },

      async listTasks(
        offset,
        limit,
      ) {
        const { data, error } = await admin.rpc(
          "notification_task_candidates",
          {
            p_offset: offset,
            p_limit: limit,
          },
        );

        if (error) {
          throw error;
        }

        return (data ?? []) as TaskCandidate[];
      },

      async getPreferences(
        userId,
      ) {
        const { data, error } = await admin
          .from("notification_preferences")
          .select(
            "stalled_task_enabled," +
              "deadline_reminder_enabled," +
              "recommendation_enabled",
          )
          .eq("user_id", userId)
          .maybeSingle();

        if (error) {
          throw error;
        }

        if (data) {
          return data as Preferences;
        }

        const defaults: Preferences = {
          stalled_task_enabled: true,
          deadline_reminder_enabled: true,
          recommendation_enabled: true,
        };

        const { error: insertError } = await admin
          .from("notification_preferences")
          .insert({
            user_id: userId,
            ...defaults,
          });

        if (
          insertError &&
          insertError.code !== "23505"
        ) {
          throw insertError;
        }

        const {
          data: saved,
          error: loadError,
        } = await admin
          .from("notification_preferences")
          .select(
            "stalled_task_enabled," +
              "deadline_reminder_enabled," +
              "recommendation_enabled",
          )
          .eq("user_id", userId)
          .single();

        if (loadError) {
          throw loadError;
        }

        return saved as Preferences;
      },

      async updateTaskStagnation(
        taskId,
        score,
        checkedAt,
      ) {
        const { data, error } = await admin.rpc(
          "update_task_stagnation",
          {
            p_task_id: taskId,
            p_score: score,
            p_checked_at: checkedAt.toISOString(),
          },
        );

        if (error) {
          throw error;
        }

        const result =
          (data as StagnationUpdate[] | null)?.[0];

        if (!result) {
          throw new Error(
            "Stagnation update returned no result",
          );
        }

        return result;
      },

      async insert(
        notification: NotificationInsert,
      ) {
        const { data, error } = await admin.rpc(
          "enqueue_app_notification",
          {
            p_notification: notification,
          },
        );

        if (error) {
          throw error;
        }

        return data === true;
      },
    };

    const summary = await generateNotifications(
      store,
    );

    // Counts only. Do not log task titles, user IDs,
    // notification messages, URLs or credentials.
    console.log(
      "Project Notification Generator summary",
      summary,
    );

    return Response.json(
      summary,
      {
        headers: {
          "Cache-Control": "no-store",
        },
      },
    );
  } catch (error) {
    const errorMessage = error instanceof Error
      ? error.message
      : "Unknown server error";

    // The error message is useful for database/RPC diagnostics,
    // but no request data, user data or secrets are logged.
    console.error(
      "Project Notification Generator failed:",
      errorMessage,
    );

    return Response.json(
      {
        error: "Generation failed",
      },
      {
        status: 500,
        headers: {
          "Cache-Control": "no-store",
        },
      },
    );
  }
});