import assert from "node:assert/strict";
import {
  createFcmSender,
  createPushDispatcher,
  type DispatchStore,
  fcmMessage,
  isInvalidToken,
} from "./index.ts";

const notificationId = "10000000-0000-0000-0000-000000000001";
const userId = "20000000-0000-0000-0000-000000000001";
const secret = "test-only-secret-with-at-least-32-characters";
const notification = {
  id: notificationId,
  user_id: userId,
  type: "STALLED_TASK",
  context_type: "TASK",
  title: "Saved title",
  message: "Saved message",
  project_id: null,
  board_id: null,
  task_id: null,
};
const preferences = {
  push_enabled: true,
  stalled_task_enabled: true,
  deadline_reminder_enabled: true,
  recommendation_enabled: true,
};
function webhook(extra: object = {}, header: string = secret) {
  return new Request("https://example.invalid", {
    method: "POST",
    headers: { "x-project-push-secret": header },
    body: JSON.stringify({
      type: "INSERT",
      schema: "public",
      table: "notifications",
      record: { id: notificationId, user_id: userId, title: "Untrusted title" },
      ...extra,
    }),
  });
}
function fixture() {
  let reads = 0, pages = 0;
  const retired: string[] = [];
  const store: DispatchStore = {
    notification: async () => {
      reads++;
      return notification;
    },
    preferences: async () => preferences,
    devices: async () => {
      pages++;
      return [{ id: "device-one", fcm_token: "fake-token" }];
    },
    deactivate: async (_, device) => {
      retired.push(device.id);
    },
  };
  return { store, retired, reads: () => reads, pages: () => pages };
}

Deno.test("method and webhook secret are checked before reading private data", async () => {
  const f = fixture();
  const handle = createPushDispatcher({
    secret,
    store: f.store,
    send: async () => "sent",
  });
  assert.equal(
    (await handle(new Request("https://example.invalid"))).status,
    405,
  );
  assert.equal((await handle(webhook({}, "wrong-secret"))).status, 401);
  assert.equal(f.reads(), 0);
});

Deno.test("invalid event, table and identifiers are rejected", async () => {
  const f = fixture();
  const handle = createPushDispatcher({
    secret,
    store: f.store,
    send: async () => "sent",
  });
  for (
    const invalid of [{ type: "UPDATE" }, { table: "projects" }, {
      record: { id: "not-an-id", user_id: userId },
    }, { schema: "storage" }]
  ) {
    assert.equal((await handle(webhook(invalid))).status, 400);
  }
  assert.equal(f.reads(), 0);
});

Deno.test("only the authoritative persisted title and context are sent", async () => {
  const f = fixture();
  let sent;
  const handle = createPushDispatcher({
    secret,
    store: f.store,
    send: async (row) => {
      sent = row;
      return "sent";
    },
  });
  const response = await handle(webhook());
  assert.equal(response.status, 200);
  assert.equal(sent, notification);
  assert.deepEqual(await response.json(), {
    sent: 1,
    failed: 0,
    deactivated: 0,
    skipped: 0,
  });
});

Deno.test("missing or cross-account rows are not dispatched", async () => {
  for (const row of [null, { ...notification, user_id: "someone-else" }]) {
    const f = fixture();
    f.store.notification = async () => row;
    const handle = createPushDispatcher({
      secret,
      store: f.store,
      send: async () => "sent",
    });
    assert.equal((await (await handle(webhook())).json()).skipped, 1);
    assert.equal(f.pages(), 0);
  }
});

Deno.test("push defaults to off, and every category is checked separately", async () => {
  const categories = [
    ["STALLED_TASK", "stalled_task_enabled"],
    ["DEADLINE_REMINDER", "deadline_reminder_enabled"],
    ["LEARNING_RESOURCE_RECOMMENDATION", "recommendation_enabled"],
  ];
  for (const [type, field] of categories) {
    for (
      const prefs of [null, { ...preferences, push_enabled: false }, {
        ...preferences,
        [field]: false,
      }]
    ) {
      const f = fixture();
      f.store.notification = async () => ({ ...notification, type });
      f.store.preferences = async () => prefs;
      const handle = createPushDispatcher({
        secret,
        store: f.store,
        send: async () => "sent",
      });
      assert.equal((await (await handle(webhook())).json()).skipped, 1);
      assert.equal(f.pages(), 0);
    }
  }
});

Deno.test("FCM data contains only strings and uses the configured Android channel", () => {
  const message = fcmMessage(notification, "fake-token").message;
  assert(
    Object.values(message.data).every((value) => typeof value === "string"),
  );
  assert.equal(message.data.notification_id, notificationId);
  assert.equal(message.data.user_id, userId);
  assert.equal(message.data.project_id, "");
  assert.equal(
    message.android.notification.channel_id,
    "skilltrack_project_notifications",
  );
  assert.equal(message.notification.title, notification.title);
});

Deno.test("devices are processed with at most five concurrent sends", async () => {
  const f = fixture();
  f.store.devices = async () =>
    Array.from(
      { length: 17 },
      (_, i) => ({ id: String(i), fcm_token: "fake" }),
    );
  let active = 0, maximum = 0;
  const handle = createPushDispatcher({
    secret,
    store: f.store,
    send: async () => {
      active++;
      maximum = Math.max(maximum, active);
      await new Promise((resolve) => setTimeout(resolve, 2));
      active--;
      return "sent";
    },
  });
  assert.equal((await (await handle(webhook())).json()).sent, 17);
  assert.equal(maximum, 5);
});

Deno.test("one failed device does not prevent other devices or leak raw responses", async () => {
  const f = fixture();
  f.store.devices = async () => [
    { id: "valid", fcm_token: "secret-token-one" },
    { id: "invalid", fcm_token: "secret-token-two" },
    { id: "failed", fcm_token: "secret-token-three" },
  ];
  const handle = createPushDispatcher({
    secret,
    store: f.store,
    send: async (_, device) => {
      if (device.id === "failed") throw new Error("private response contents");
      return device.id === "invalid" ? "invalid" : "sent";
    },
  });
  const response = await handle(webhook());
  assert.equal(response.status, 502);
  const text = await response.text();
  assert(!text.includes("secret-token"));
  assert(!text.includes("private"));
  assert.deepEqual(JSON.parse(text), {
    sent: 1,
    failed: 2,
    deactivated: 1,
    skipped: 0,
  });
  assert.deepEqual(f.retired, ["invalid"]);
});

Deno.test("pagination stays valid while invalid tokens are deactivated", async () => {
  const f = fixture();
  const devices = Array.from(
    { length: 205 },
    (_, i) => ({ id: String(i).padStart(4, "0"), fcm_token: "fake" }),
  );
  f.store.devices = async (_, after) =>
    devices.filter((d) => after === null || d.id > after).slice(0, 100);
  const handle = createPushDispatcher({
    secret,
    store: f.store,
    send: async () => "invalid",
  });
  assert.equal((await (await handle(webhook())).json()).deactivated, 205);
  assert.equal(f.retired.length, 205);
});

Deno.test("only confirmed token errors cause deactivation", () => {
  assert(isInvalidToken({
    error: {
      details: [{
        "@type": "type.googleapis.com/google.firebase.fcm.v1.FcmError",
        errorCode: "UNREGISTERED",
      }],
    },
  }));
  assert(
    !isInvalidToken({
      error: { status: "INVALID_ARGUMENT", message: "Private payload problem" },
    }),
  );
  assert(
    !isInvalidToken({
      error: {
        details: [{
          "@type": "type.googleapis.com/google.rpc.BadRequest",
          fieldViolations: [{
            field: "message.data",
            description: "Private data",
          }],
        }],
      },
    }),
  );
  assert(isInvalidToken({
    error: {
      details: [{
        "@type": "type.googleapis.com/google.rpc.BadRequest",
        fieldViolations: [{ field: "message.token" }],
      }],
    },
  }));
});

Deno.test("oversized authenticated requests are rejected before database reads", async () => {
  const f = fixture();
  const handle = createPushDispatcher({
    secret,
    store: f.store,
    send: async () => "sent",
  });
  const response = await handle(
    new Request("https://example.invalid", {
      method: "POST",
      headers: { "x-project-push-secret": secret },
      body: "x".repeat(65537),
    }),
  );
  assert.equal(response.status, 413);
  assert.equal(f.reads(), 0);
});

Deno.test("FCM OAuth assertions are signed and the access token is reused", async () => {
  const keys = await crypto.subtle.generateKey(
    {
      name: "RSASSA-PKCS1-v1_5",
      modulusLength: 2048,
      publicExponent: new Uint8Array([1, 0, 1]),
      hash: "SHA-256",
    },
    true,
    ["sign", "verify"],
  );
  const pkcs8 = new Uint8Array(
    await crypto.subtle.exportKey("pkcs8", keys.privateKey),
  );
  const pem = "-----BEGIN PRIVATE KEY-----\n" +
    btoa(String.fromCharCode(...pkcs8)) + "\n-----END PRIVATE KEY-----";
  let oauthCalls = 0, sendCalls = 0;
  const http: typeof fetch = async (input, init) => {
    if (String(input) === "https://oauth2.googleapis.com/token") {
      oauthCalls++;
      const params = init!.body as URLSearchParams;
      const parts = params.get("assertion")!.split(".");
      const decode = (value: string) =>
        Uint8Array.from(
          atob(value.replace(/-/g, "+").replace(/_/g, "/")),
          (c) => c.charCodeAt(0),
        );
      assert(
        await crypto.subtle.verify(
          "RSASSA-PKCS1-v1_5",
          keys.publicKey,
          decode(parts[2]),
          new TextEncoder().encode(parts[0] + "." + parts[1]),
        ),
      );
      const claims = JSON.parse(new TextDecoder().decode(decode(parts[1])));
      assert.equal(
        claims.scope,
        "https://www.googleapis.com/auth/firebase.messaging",
      );
      return Response.json({
        access_token: "test-only-access-token",
        expires_in: 3600,
      });
    }
    sendCalls++;
    assert.equal(
      new Headers(init!.headers).get("Authorization"),
      "Bearer test-only-access-token",
    );
    assert.equal(
      JSON.parse(init!.body as string).message.notification.title,
      notification.title,
    );
    return Response.json({ name: "ignored" });
  };
  const send = createFcmSender({
    projectId: "example-project",
    clientEmail: "example@example.invalid",
    privateKey: pem,
  }, http);
  await Promise.all([
    send(notification, { id: "one", fcm_token: "fake-one" }),
    send(notification, { id: "two", fcm_token: "fake-two" }),
  ]);
  assert.equal(oauthCalls, 1);
  assert.equal(sendCalls, 2);
});
