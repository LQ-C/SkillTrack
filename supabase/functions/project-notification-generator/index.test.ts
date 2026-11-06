// Execute the real handler/adapter without network access or real credentials.
import assert from "node:assert/strict";
import test from "node:test";
import { registerHooks } from "node:module";

const now = "2026-10-10T12:00:00.000Z";
const secret = "test-only-cron-secret";
const preferences = {
  stalled_task_enabled: true,
  deadline_reminder_enabled: true,
  recommendation_enabled: true,
};
let handler: (request: Request) => Promise<Response>;
let fixture: ReturnType<typeof createFixture>;
const hooks = registerHooks({
  resolve(specifier, context, next) {
    let source: string | undefined;
    if (specifier === "npm:@supabase/supabase-js@2") {
      source =
        "export const createClient = () => globalThis.__notificationTestAdmin;";
    } else if (
      specifier === "./generator.ts" &&
      context.parentURL === new URL("./index.ts", import.meta.url).href
    ) {
      source = `import {generateNotifications as generate} from ${
        JSON.stringify(new URL("./generator.ts", import.meta.url).href)
      };
        export const generateNotifications = store => generate(store, new Date(${
        JSON.stringify(now)
      }));`;
    }
    return source === undefined ? next(specifier, context) : {
      url: `data:text/javascript,${encodeURIComponent(source)}`,
      shortCircuit: true,
    };
  },
});
const previousDeno = Reflect.get(globalThis, "Deno");
Reflect.set(globalThis, "Deno", {
  env: {
    get: (name: string) =>
      ({
        PROJECT_NOTIFICATION_CRON_SECRET: secret,
        SUPABASE_URL: "https://example.invalid",
        SUPABASE_SERVICE_ROLE_KEY: "test-only-key",
      })[name],
  },
  serve: (value: typeof handler) => {
    handler = value;
  },
});
try {
  await import("./index.ts");
} finally {
  hooks.deregister();
}
test.after(() => {
  Reflect.set(globalThis, "Deno", previousDeno);
  Reflect.deleteProperty(globalThis, "__notificationTestAdmin");
});

function createFixture() {
  const calls: { name: string; args: Record<string, unknown> }[] = [];
  const queries: string[] = [];
  const saved: Record<string, unknown>[] = [];
  const value = {
    calls,
    queries,
    saved,
    stagnation: [{
      became_stalled: true,
      currently_stalled: true,
      current_stalled_at: "2026-10-10 12:00:00+00",
    }] as unknown,
    stagnationError: null as unknown,
    admin: {
      async rpc(name: string, args: Record<string, unknown>) {
        calls.push({ name, args });
        if (name === "notification_project_candidates") {
          return { data: [], error: null };
        }
        if (name === "notification_task_candidates") {
          return {
            data: [{
              task_id: "task-1",
              board_id: "board-1",
              project_id: "project-1",
              user_id: "user-1",
              task_title: "Study",
              task_status: "in_progress",
              task_archived: false,
              board_archived: false,
              project_status: "active",
              profile_exists: true,
              task_created_at: "2026-10-01T12:00:00Z",
              last_activity_at: "2026-10-04T12:00:00Z",
              deadline: null,
            }],
            error: null,
          };
        }
        if (name === "update_task_stagnation") {
          return { data: value.stagnation, error: value.stagnationError };
        }
        if (name === "enqueue_app_notification") {
          saved.push(args.p_notification as Record<string, unknown>);
          return { data: true, error: null };
        }
        throw new Error(`Unexpected RPC ${name}`);
      },
      from(table: string) {
        assert.equal(table, "notification_preferences");
        return {
          select(columns: string) {
            queries.push(columns);
            return this;
          },
          eq(key: string, id: string) {
            assert.equal(key, "user_id");
            assert.equal(id, "user-1");
            return this;
          },
          async maybeSingle() {
            return { data: preferences, error: null };
          },
        };
      },
    },
  };
  return value;
}

function reset() {
  fixture = createFixture();
  Reflect.set(globalThis, "__notificationTestAdmin", fixture.admin);
}
const request = (header = secret, method = "POST") =>
  new Request("https://example.invalid", {
    method,
    headers: { "x-notification-cron-secret": header },
  });

test("adapter preserves candidate creation time and exact RPC argument/return contract", async () => {
  reset();
  const response = await handler(request());
  assert.equal(response.status, 200);
  assert.deepEqual(
    fixture.calls.find((call) => call.name === "update_task_stagnation")?.args,
    {
      p_task_id: "task-1",
      p_score: 70,
      p_checked_at: now,
    },
  );
  assert.equal(fixture.saved.length, 1);
  assert.equal(
    fixture.saved[0].unique_key,
    "stalled:task-1:2026-10-10 12:00:00+00",
  );
  assert.equal(fixture.saved[0].type, "STALLED_TASK");
  assert.equal((await response.json()).failed, 0);
  assert.deepEqual(fixture.queries, [
    "stalled_task_enabled,deadline_reminder_enabled,recommendation_enabled",
  ]);
});

for (
  const result of [null, [], [{}], [{
    currently_stalled: true,
    became_stalled: true,
    current_stalled_at: "bad-date",
  }]]
) {
  test(`adapter rejects malformed RPC response ${JSON.stringify(result)}`, async () => {
    reset();
    fixture.stagnation = result;
    const response = await handler(request());
    assert.equal((await response.json()).failed, 1);
    assert.equal(fixture.saved.length, 0);
  });
}

test("adapter propagates RPC failure instead of inventing a stalled state", async () => {
  reset();
  fixture.stagnationError = new Error("database failure");
  const response = await handler(request());
  assert.equal((await response.json()).failed, 1);
  assert.equal(fixture.saved.length, 0);
});

test("authentication and method checks prevent database access", async () => {
  reset();
  assert.equal((await handler(request(secret, "GET"))).status, 405);
  assert.equal((await handler(request("incorrect"))).status, 401);
  assert.equal(fixture.calls.length, 0);
  assert.equal(fixture.queries.length, 0);
});
