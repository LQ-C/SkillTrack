import { createClient } from "npm:@supabase/supabase-js@2";

type NotificationRow = {
  id: string;
  user_id: string;
  type: string;
  context_type: string;
  title: string;
  message: string;
  project_id: string | null;
  board_id: string | null;
  task_id: string | null;
};
type Preferences = {
  push_enabled?: boolean;
  stalled_task_enabled?: boolean;
  deadline_reminder_enabled?: boolean;
  recommendation_enabled?: boolean;
};
type Device = { id: string; fcm_token: string };
export interface DispatchStore {
  notification(id: string, userId: string): Promise<NotificationRow | null>;
  preferences(userId: string): Promise<Preferences | null>;
  devices(userId: string, afterId: string | null): Promise<Device[]>;
  deactivate(userId: string, device: Device): Promise<void>;
}
type Sender = (
  notification: NotificationRow,
  device: Device,
) => Promise<"sent" | "invalid" | "failed">;

const channelId = "skilltrack_project_notifications";
const categoryPreference = {
  STALLED_TASK: "stalled_task_enabled",
  DEADLINE_REMINDER: "deadline_reminder_enabled",
  LEARNING_RESOURCE_RECOMMENDATION: "recommendation_enabled",
} as const;
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

async function matchesSecret(
  provided: string | null,
  expected: string,
): Promise<boolean> {
  if (!provided || !expected || provided.length > 512) return false;
  const encode = new TextEncoder();
  const [left, right] = await Promise.all([
    crypto.subtle.digest("SHA-256", encode.encode(provided)),
    crypto.subtle.digest("SHA-256", encode.encode(expected)),
  ]);
  const a = new Uint8Array(left), b = new Uint8Array(right);
  let difference = 0;
  for (let index = 0; index < a.length; index++) {
    difference |= a[index] ^ b[index];
  }
  return difference === 0;
}

export function fcmMessage(row: NotificationRow, token: string) {
  return {
    message: {
      token,
      notification: { title: row.title, body: row.message },
      data: {
        notification_id: row.id,
        user_id: row.user_id,
        type: row.type,
        context_type: row.context_type,
        project_id: row.project_id ?? "",
        board_id: row.board_id ?? "",
        task_id: row.task_id ?? "",
      },
      android: {
        priority: "HIGH",
        collapse_key: row.id,
        notification: {
          channel_id: channelId,
          tag: row.id,
          icon: "ic_launcher",
        },
      },
    },
  };
}

export function isInvalidToken(body: unknown): boolean {
  const details = (body as { error?: { details?: unknown[] } })?.error?.details;
  if (!Array.isArray(details)) return false;
  return details.some((detail) => {
    if (!detail || typeof detail !== "object") return false;
    const entry = detail as Record<string, unknown>;
    if (
      entry["@type"] ===
        "type.googleapis.com/google.firebase.fcm.v1.FcmError" &&
      entry.errorCode === "UNREGISTERED"
    ) return true;
    if (
      entry["@type"] !== "type.googleapis.com/google.rpc.BadRequest" ||
      !Array.isArray(entry.fieldViolations)
    ) return false;
    return entry.fieldViolations.some((violation: { field?: string }) =>
      violation?.field === "message.token"
    );
  });
}

export function createPushDispatcher(dependencies: {
  secret: string;
  store: DispatchStore;
  send: Sender;
}) {
  return async (request: Request): Promise<Response> => {
    if (request.method !== "POST") {
      return Response.json({ error: "Method not allowed" }, { status: 405 });
    }
    if (
      !(await matchesSecret(
        request.headers.get("x-project-push-secret"),
        dependencies.secret,
      ))
    ) {
      return Response.json({ error: "Unauthorized" }, { status: 401 });
    }
    const counts = { sent: 0, failed: 0, deactivated: 0, skipped: 0 };
    try {
      // Database Webhooks send only one row. Bound parsing without trusting Content-Length.
      const reader = request.body?.getReader();
      if (!reader) {
        return Response.json({ error: "Invalid webhook" }, { status: 400 });
      }
      const chunks: Uint8Array[] = [];
      let length = 0;
      while (true) {
        const result = await reader.read();
        if (result.done) break;
        length += result.value.length;
        if (length > 65536) {
          await reader.cancel();
          return Response.json({ error: "Payload too large" }, { status: 413 });
        }
        chunks.push(result.value);
      }
      const bytes = new Uint8Array(length);
      let offset = 0;
      for (const chunk of chunks) {
        bytes.set(chunk, offset);
        offset += chunk.length;
      }
      let payload;
      try {
        payload = JSON.parse(new TextDecoder().decode(bytes));
      } catch (_) {
        return Response.json({ error: "Invalid webhook" }, { status: 400 });
      }
      const id = payload?.record?.id, userId = payload?.record?.user_id;
      if (
        payload?.type !== "INSERT" || payload?.schema !== "public" ||
        payload?.table !== "notifications" ||
        typeof id !== "string" || !uuid.test(id) ||
        typeof userId !== "string" || !uuid.test(userId)
      ) {
        return Response.json({ error: "Invalid webhook" }, { status: 400 });
      }
      const row = await dependencies.store.notification(id, userId);
      if (!row || row.id !== id || row.user_id !== userId) {
        counts.skipped++;
        return Response.json(counts);
      }
      const category =
        categoryPreference[row.type as keyof typeof categoryPreference];
      const preferences = await dependencies.store.preferences(userId);
      if (
        !category || preferences?.push_enabled !== true ||
        preferences[category] !== true
      ) {
        counts.skipped++;
        return Response.json(counts);
      }
      let afterId: string | null = null;
      while (true) {
        const devices = await dependencies.store.devices(userId, afterId);
        for (let index = 0; index < devices.length; index += 5) {
          const results = await Promise.allSettled(
            devices.slice(index, index + 5).map(async (device) => {
              const result = await dependencies.send(row, device);
              if (result === "sent") {
                counts.sent++;
                return;
              }
              counts.failed++;
              if (result === "invalid") {
                try {
                  await dependencies.store.deactivate(userId, device);
                  counts.deactivated++;
                } catch (_) { /* This device is already included in failed. */ }
              }
            }),
          );
          // Failed transports and cleanup operations never expose response bodies.
          counts.failed += results.filter((result) =>
            result.status === "rejected"
          ).length;
        }
        if (devices.length < 100) break;
        const next = devices[devices.length - 1].id;
        if (next === afterId) throw new Error("Invalid device page");
        afterId = next;
      }
      return Response.json(counts, { status: counts.failed ? 502 : 200 });
    } catch (_) {
      return Response.json({ ...counts, failed: counts.failed + 1 }, {
        status: 503,
      });
    }
  };
}

function base64Url(bytes: Uint8Array): string {
  return btoa(String.fromCharCode(...bytes))
    .replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

export function createFcmSender(config: {
  projectId: string;
  clientEmail: string;
  privateKey: string;
}, http: typeof fetch = fetch): Sender {
  let cached: { token: string; expiresAt: number } | null = null;
  let pending: Promise<string> | null = null;
  async function accessToken(): Promise<string> {
    if (cached && cached.expiresAt > Date.now() + 60000) return cached.token;
    if (pending) return pending;
    pending = (async () => {
      const encode = new TextEncoder();
      const now = Math.floor(Date.now() / 1000);
      const header = base64Url(
        encode.encode(JSON.stringify({ alg: "RS256", typ: "JWT" })),
      );
      const claims = base64Url(encode.encode(JSON.stringify({
        iss: config.clientEmail,
        scope: "https://www.googleapis.com/auth/firebase.messaging",
        aud: "https://oauth2.googleapis.com/token",
        iat: now,
        exp: now + 3600,
      })));
      const pem = config.privateKey.replace(/\\n/g, "\n")
        .replace(
          /-----BEGIN PRIVATE KEY-----|-----END PRIVATE KEY-----|\s/g,
          "",
        );
      const key = await crypto.subtle.importKey(
        "pkcs8",
        Uint8Array.from(atob(pem), (character) => character.charCodeAt(0)),
        { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
        false,
        ["sign"],
      );
      const unsigned = header + "." + claims;
      const signature = await crypto.subtle.sign(
        "RSASSA-PKCS1-v1_5",
        key,
        encode.encode(unsigned),
      );
      const assertion = unsigned + "." + base64Url(new Uint8Array(signature));
      const response = await http("https://oauth2.googleapis.com/token", {
        method: "POST",
        body: new URLSearchParams({
          grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
          assertion,
        }),
        signal: AbortSignal.timeout(10000),
      });
      if (!response.ok) throw new Error("Push authentication unavailable");
      const data = await response.json();
      if (typeof data.access_token !== "string" || !data.access_token) {
        throw new Error("Push authentication unavailable");
      }
      cached = {
        token: data.access_token,
        expiresAt: Date.now() +
          Math.min(Number(data.expires_in) || 3600, 3600) * 1000,
      };
      return cached.token;
    })();
    try {
      return await pending;
    } finally {
      pending = null;
    }
  }
  return async (row, device) => {
    const token = await accessToken();
    const response = await http(
      "https://fcm.googleapis.com/v1/projects/" +
        encodeURIComponent(config.projectId) + "/messages:send",
      {
        method: "POST",
        headers: {
          Authorization: "Bearer " + token,
          "Content-Type": "application/json",
        },
        body: JSON.stringify(fcmMessage(row, device.fcm_token)),
        signal: AbortSignal.timeout(10000),
      },
    );
    if (response.ok) return "sent";
    const body = await response.json().catch(() => null);
    if (isInvalidToken(body)) return "invalid";
    if (response.status === 401) cached = null;
    return "failed";
  };
}

function productionDispatcher() {
  function required(name: string): string {
    const value = Deno.env.get(name);
    if (!value) throw new Error("Push configuration unavailable");
    return value;
  }
  const secret = required("PROJECT_PUSH_WEBHOOK_SECRET");
  if (secret.length < 32) throw new Error("Push configuration unavailable");
  const client = createClient(
    required("SUPABASE_URL"),
    required("SUPABASE_SERVICE_ROLE_KEY"),
    {
      auth: { persistSession: false, autoRefreshToken: false },
    },
  );
  const store: DispatchStore = {
    async notification(id, userId) {
      const { data, error } = await client.from("notifications").select(
        "id,user_id,type,context_type,title,message,project_id,board_id,task_id",
      ).eq("id", id).eq("user_id", userId).maybeSingle();
      if (error) throw new Error("Notification unavailable");
      return data;
    },
    async preferences(userId) {
      const { data, error } = await client.from("notification_preferences")
        .select(
          "push_enabled,stalled_task_enabled,deadline_reminder_enabled,recommendation_enabled",
        ).eq("user_id", userId).maybeSingle();
      if (error) throw new Error("Preferences unavailable");
      return data;
    },
    async devices(userId, afterId) {
      let query = client.from("project_push_devices").select("id,fcm_token")
        .eq("user_id", userId).eq("is_active", true);
      if (afterId) query = query.gt("id", afterId);
      const { data, error } = await query.order("id").limit(100);
      if (error) throw new Error("Devices unavailable");
      return data ?? [];
    },
    async deactivate(userId, device) {
      const { error } = await client.from("project_push_devices").update({
        is_active: false,
      })
        .eq("user_id", userId).eq("id", device.id).eq(
          "fcm_token",
          device.fcm_token,
        );
      if (error) throw new Error("Device unavailable");
    },
  };
  return createPushDispatcher({
    secret,
    store,
    send: createFcmSender({
      projectId: required("FIREBASE_PROJECT_ID"),
      clientEmail: required("FIREBASE_CLIENT_EMAIL"),
      privateKey: required("FIREBASE_PRIVATE_KEY"),
    }),
  });
}

if (import.meta.main) {
  let handler: ReturnType<typeof createPushDispatcher> | null = null;
  Deno.serve((request) => {
    try {
      handler ??= productionDispatcher();
      return handler(request);
    } catch (_) {
      return Response.json({ sent: 0, failed: 1, deactivated: 0, skipped: 0 }, {
        status: 503,
      });
    }
  });
}
