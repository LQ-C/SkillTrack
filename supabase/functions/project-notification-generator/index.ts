import { createClient } from "npm:@supabase/supabase-js@2";
import {
  generateNotifications,
  type NotificationInsert,
  type NotificationStore,
  type Preferences,
  type ProjectCandidate,
  type TaskCandidate,
} from "./generator.ts";

function required(name: string): string {
  const value = Deno.env.get(name);
  if (!value) throw new Error(`Missing ${name}`);
  return value;
}

async function matchesSecret(
  provided: string | null,
  expected: string,
): Promise<boolean> {
  if (!provided || !expected) return false;
  const encoder = new TextEncoder();
  const [left, right] = await Promise.all([
    crypto.subtle.digest("SHA-256", encoder.encode(provided)),
    crypto.subtle.digest("SHA-256", encoder.encode(expected)),
  ]);
  const a = new Uint8Array(left);
  const b = new Uint8Array(right);
  let difference = 0;
  for (let i = 0; i < a.length; i++) difference |= a[i] ^ b[i];
  return difference === 0;
}

Deno.serve(async (request) => {
  if (request.method !== "POST") {
    return Response.json({ error: "Method not allowed" }, { status: 405 });
  }
  const expectedSecret = Deno.env.get("PROJECT_NOTIFICATION_CRON_SECRET");
  if (
    !expectedSecret ||
    !(await matchesSecret(
      request.headers.get("x-notification-cron-secret"),
      expectedSecret,
    ))
  ) {
    return Response.json({ error: "Unauthorized" }, { status: 401 });
  }

  try {
    const admin = createClient(
      required("SUPABASE_URL"),
      required("SUPABASE_SERVICE_ROLE_KEY"),
      {
        auth: { persistSession: false, autoRefreshToken: false },
      },
    );
    const store: NotificationStore = {
      async listProjects(offset, limit) {
        const { data, error } = await admin.rpc(
          "notification_project_candidates",
          {
            p_offset: offset,
            p_limit: limit,
          },
        );
        if (error) throw error;
        return (data ?? []) as ProjectCandidate[];
      },
      async listTasks(offset, limit) {
        const { data, error } = await admin.rpc(
          "notification_task_candidates",
          {
            p_offset: offset,
            p_limit: limit,
          },
        );
        if (error) throw error;
        return (data ?? []) as TaskCandidate[];
      },
      async getPreferences(userId) {
        const { data, error } = await admin
          .from("notification_preferences")
          .select(
            "stalled_task_enabled,deadline_reminder_enabled,recommendation_enabled",
          )
          .eq("user_id", userId)
          .maybeSingle();
        if (error) throw error;
        if (data) return data as Preferences;
        const defaults: Preferences = {
          stalled_task_enabled: true,
          deadline_reminder_enabled: true,
          recommendation_enabled: true,
        };
        const { error: insertError } = await admin
          .from("notification_preferences")
          .insert({ user_id: userId, ...defaults });
        if (insertError && insertError.code !== "23505") throw insertError;
        const { data: saved, error: loadError } = await admin
          .from("notification_preferences")
          .select(
            "stalled_task_enabled,deadline_reminder_enabled,recommendation_enabled",
          )
          .eq("user_id", userId)
          .single();
        if (loadError) throw loadError;
        return saved as Preferences;
      },
      async insert(notification: NotificationInsert) {
        const { data, error } = await admin.rpc("enqueue_app_notification", {
          p_notification: notification,
        });
        if (error) throw error;
        return data === true;
      },
    };
    const summary = await generateNotifications(store);
    // Counts only: no task titles, user IDs, URLs, or credentials in logs.
    console.log("Project Notification Generator summary", summary);
    return Response.json(summary, { headers: { "Cache-Control": "no-store" } });
  } catch (_) {
    console.error("Project Notification Generator failed before completion");
    return Response.json({ error: "Generation failed" }, { status: 500 });
  }
});
