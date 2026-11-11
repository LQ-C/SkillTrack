import assert from "node:assert/strict";
import {
  recommendAndSave,
  type RecommendationPersistence,
  type SavedRecommendations,
} from "./persistence.ts";
import type { RecommendationStore } from "./recommend.ts";
function fixture() {
  let saved: SavedRecommendations = {
    generated: false,
    status: "empty",
    recommendations: [],
  };
  let token: string | undefined;
  let calls = 0;
  let fail = false;
  let visible = false;
  const persistence: RecommendationPersistence = {
    begin: async (_task, _user, mode) => {
      if (mode === "automatic" && saved.generated) {
        return { cached: true, result: saved };
      }
      if (token) throw Error("busy");
      token = "claim";
      return { cached: false, token };
    },
    complete: async (_task, _user, claim, sources) => {
      assert.equal(claim, token);
      if (fail) throw Error("save failed");
      saved = {
        generated: true,
        status: sources.length ? "ok" : "empty",
        sources,
        recommendations: sources.map((s) => ({
          ...s,
          title: "Tutorial",
          summary: "Learn Flutter",
          type: "Reading",
        })),
      };
      token = undefined;
      return saved;
    },
    fail: async () => {
      token = undefined;
    },
  };
  const store: RecommendationStore = {
    loadTask: async () => ({
      title: "Flutter",
      description: "Layouts",
      is_stalled: true,
      source_version: "task-v1",
    }),
    visibleIds: async () => visible ? ["resource"] : [],
    search: async () => [{
      resource_id: "resource",
      title: "Tutorial",
      summary: "Learn Flutter",
      resource_type: "Reading",
      source_version: "v1",
      resource_updated_at: "2026-11-11T00:00:00Z",
    }],
    visibleDetails: async () => [{
      id: "resource",
      title: "Tutorial",
      summary: "Learn Flutter",
      kind: "Reading",
      updated_at: "2026-11-11T00:00:00Z",
    }],
  };
  const run = (mode: "automatic" | "manual" = "automatic") =>
    recommendAndSave(
      {
        userId: "owner",
        store,
        getEmbedder: () => ({
          embed: async () => {
            calls++;
            return [1, ...Array(383).fill(0)];
          },
        }),
      },
      persistence,
      "task",
      mode,
    );
  return {
    run,
    get saved() {
      return saved;
    },
    get calls() {
      return calls;
    },
    set visible(value: boolean) {
      visible = value;
    },
    set fail(value: boolean) {
      fail = value;
    },
  };
}
Deno.test("successful empty set is cached without matching again; explicit refresh includes new resources", async () => {
  const f = fixture();
  assert.equal((await f.run()).generated, true);
  await f.run();
  assert.equal(f.calls, 0);
  f.visible = true;
  assert.equal((await f.run("manual")).recommendations.length, 1);
  assert.equal(f.calls, 1);
  await f.run();
  assert.equal(f.calls, 1);
});
Deno.test("failed refresh preserves saved results and releases claim for retry", async () => {
  const f = fixture();
  f.visible = true;
  await f.run();
  const original = f.saved;
  f.fail = true;
  await assert.rejects(f.run("manual"), /save failed/);
  assert.equal(f.saved, original);
  f.fail = false;
  f.visible = false;
  await f.run("manual");
  assert.deepEqual(f.saved.recommendations, []);
});
