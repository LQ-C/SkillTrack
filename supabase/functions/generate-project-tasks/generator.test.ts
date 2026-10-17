import assert from "node:assert/strict";
import test from "node:test";
import {
  buildPrompt, existingTaskContext, normalizedTitle, parseGenerationMode,
  sanitizeGenerated,
  validDeadline,
} from "./generator.ts";

const task = (title: string, extras: Record<string, unknown> = {}) => ({
  title, description: "An actionable step", priority: "high",
  checklist: ["Plan it", "Build it"], ...extras,
});
const milestone = (title: string, tasks: unknown[]) => ({ title, tasks });

test("missing and explicit initial modes remain compatible", () => {
  assert.equal(parseGenerationMode(undefined), "initial");
  assert.equal(parseGenerationMode("initial"), "initial");
  assert.equal(parseGenerationMode("append"), "append");
  assert.equal(parseGenerationMode("APPEND"), null);
});

test("existing context keeps only 100 valid, unique title/status pairs", () => {
  const context = existingTaskContext([
    { title: " Create  Login Page ", status: "completed", description: "private" },
    { title: "create login page.", status: "todo" },
    { title: "Archive", status: "archived" },
    { title: "Unknown", status: "invalid" },
    {},
    ...Array.from({ length: 150 }, (_, index) => ({ title: `Task ${index}`, status: "todo" })),
  ]);
  assert.equal(context.length, 100);
  assert.deepEqual(context[0], { title: "Create  Login Page", status: "completed" });
  assert.deepEqual(context[1], { title: "Archive", status: "archived" });
  assert.equal(context[2].status, "todo");
  assert.equal(normalizedTitle("Create login page."), normalizedTitle(" CREATE  LOGIN PAGE "));
  assert.equal(normalizedTitle("Create login-page"), normalizedTitle("create login page"));
});

test("deadline validation accepts only real calendar dates", () => {
  assert.equal(validDeadline("2026-11-30"), true);
  assert.equal(validDeadline("2026-02-30"), false);
  assert.equal(validDeadline("2026-13-01"), false);
});

test("append prompt treats active, completed and archived tasks as existing", () => {
  const prompt = buildPrompt("append", "App", "Build an app", "2026-11-30", [
    { title: "Login", status: "in_progress" },
    { title: "Old feature", status: "archived" },
  ]);
  assert.match(prompt, /already planned/);
  assert.match(prompt, /already completed/);
  assert.match(prompt, /already considered/);
  assert.match(prompt, /Project context JSON/);
  assert.match(buildPrompt("initial", "App", "Build", "", []), /complete initial/);
});

test("initial requires multiple milestones and at least three valid tasks", () => {
  const valid = { milestones: [
    milestone("Plan", [task("One"), task("Two")]),
    milestone("Build", [task("Three"), task("Four")]),
  ] };
  assert.equal(sanitizeGenerated(valid, "initial").milestones.length, 2);
  assert.throws(() => sanitizeGenerated({ milestones: [] }, "initial"));
  assert.throws(() => sanitizeGenerated({ milestones: [milestone("Only", [task("One")])] }, "initial"));
});

test("append allows empty, one and two tasks", () => {
  assert.deepEqual(sanitizeGenerated({ milestones: [] }, "append"), { milestones: [] });
  const one = { milestones: [milestone("More", [task("One")])] };
  assert.equal(sanitizeGenerated(one, "append").milestones[0].tasks.length, 1);
  const two = { milestones: [milestone("More", [task("One"), task("Two")])] };
  assert.equal(sanitizeGenerated(two, "append").milestones[0].tasks.length, 2);
});

test("append removes exact, case, punctuation and internal duplicates", () => {
  const response = { milestones: [milestone("More", [
    task("Create Login Page"), task("create  login page."),
    task("Build Profile"), task("build profile!"), task("Review"),
  ])] };
  const result = sanitizeGenerated(response, "append", [
    { title: "Create login page.", status: "completed" },
  ]);
  assert.deepEqual(result.milestones[0].tasks.map((item) => item.title),
    ["Build Profile", "Review"]);
});

test("invalid tasks are dropped, fields sanitized and output capped at 12", () => {
  const response = { milestones: [
    milestone("One", Array.from({ length: 6 }, (_, i) => task(`A ${i}`))),
    milestone("Two", Array.from({ length: 6 }, (_, i) => task(`B ${i}`))),
    milestone("Three", [task("Extra")]),
  ] };
  assert.equal(sanitizeGenerated(response, "append").milestones.flatMap((m) => m.tasks).length, 12);
  const sanitized = sanitizeGenerated({ milestones: [milestone("More", [
    task("Valid", { priority: "wrong", checklist: [" First ", "first.", "Second", ""] }),
    task("No checklist", { checklist: ["Only one"] }),
  ])] }, "append");
  assert.equal(sanitized.milestones[0].tasks.length, 1);
  assert.equal(sanitized.milestones[0].tasks[0].priority, "medium");
  assert.deepEqual(sanitized.milestones[0].tasks[0].checklist, ["First", "Second"]);
});
