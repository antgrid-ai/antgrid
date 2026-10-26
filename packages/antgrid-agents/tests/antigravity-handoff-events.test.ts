import { afterEach, beforeEach, expect, test } from "bun:test";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { antigravityFork } from "../src/agents/antigravity/fork";
import type { HandoffEvent, HandoffSnapshot } from "../src/agents/handoff";

let dir: string;
beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), "agy-events-"));
});
afterEach(() => rmSync(dir, { recursive: true, force: true }));

const manifest = (): HandoffSnapshot => ({
  agent: "antigravity",
  method: "copy",
  primary: "antigravity-transcript.jsonl",
  files: [],
  references: [],
  redactions: [],
  warnings: [],
});

async function parseRaw(raw: string): Promise<HandoffEvent[]> {
  writeFileSync(join(dir, "antigravity-transcript.jsonl"), raw);
  const out: HandoffEvent[] = [];
  await antigravityFork.events(dir, manifest(), (e) => out.push(e), new AbortController().signal);
  return out;
}

const parse = (records: unknown[]) => parseRaw(`${records.map((r) => JSON.stringify(r)).join("\n")}\n`);

const input = (content: string, source = "USER_EXPLICIT") => ({ type: "USER_INPUT", source, content });
const wrap = (text: string) => `<USER_REQUEST>\n${text}\n</USER_REQUEST>\n<ADDITIONAL_METADATA>\nlocal time\n</ADDITIONAL_METADATA>`;
const genuine = (events: HandoffEvent[]) => events.filter((e) => e.kind === "user" && e.genuine).map((e) => (e as { text: string }).text);

test("selects explicit user input, unwrapped, skipping system records and non-explicit input", async () => {
  const events = await parse([
    { type: "SYSTEM_MESSAGE", source: "SYSTEM", content: "<SYSTEM_MESSAGE>task done</SYSTEM_MESSAGE>" },
    input(wrap("injected"), "SYSTEM"),
    input(wrap("add a retry")),
    input("bare text\n<USER_SETTINGS_CHANGE>x</USER_SETTINGS_CHANGE>"),
  ]);
  expect(genuine(events)).toEqual(["add a retry", "bare text"]);
});

test("a nested Antgrid handoff prompt is not genuine", async () => {
  const events = await parse([
    input(wrap("Continue a task handed off from Codex. Antgrid saved its context in two files")),
    input(wrap("real")),
  ]);
  expect(events.map((e) => e.kind === "user" && e.genuine)).toEqual([false, true]);
});

test("every checkpoint is reported so the latest one wins", async () => {
  const events = await parse([
    { type: "CHECKPOINT", source: "SYSTEM", content: "{{ CHECKPOINT 1 }} old" },
    { type: "CHECKPOINT", source: "SYSTEM", content: "{{ CHECKPOINT 2 }} new" },
  ]);
  expect(events).toHaveLength(2);
  expect(events.at(-1)).toMatchObject({ kind: "compaction", summary: "{{ CHECKPOINT 2 }} new", at: "antigravity-transcript.jsonl:2" });
});

test("tail events pair results with calls by position and drop thinking and error records", async () => {
  const events = await parse([
    {
      type: "PLANNER_RESPONSE",
      content: "checking",
      thinking: "hidden",
      tool_calls: [{ name: "view_file", args: { Path: "a.ts" } }, { name: "run_command", args: { CommandLine: "ls" } }],
    },
    { type: "GENERIC", content: "Created At: t0\nCompleted At: t1\nfile body" },
    { type: "GENERIC", status: "ERROR", error: "exit 1", content: "Created At: t0\nCompleted At: t1\n" },
    { type: "GENERIC", content: "stray" },
    { type: "ERROR_MESSAGE", content: "model failed" },
    { type: "PLANNER_RESPONSE", content: "", tool_calls: [] },
  ]);
  expect(events).toEqual([
    { kind: "assistant", text: "checking", at: "antigravity-transcript.jsonl:1" },
    { kind: "tool_call", name: "view_file", input: '{"Path":"a.ts"}', at: "antigravity-transcript.jsonl:1" },
    { kind: "tool_call", name: "run_command", input: '{"CommandLine":"ls"}', at: "antigravity-transcript.jsonl:1" },
    { kind: "tool_result", name: "view_file", output: "file body", at: "antigravity-transcript.jsonl:2" },
    { kind: "tool_result", name: "run_command", output: "exit 1", isError: true, at: "antigravity-transcript.jsonl:3" },
    { kind: "tool_result", output: "stray", at: "antigravity-transcript.jsonl:4" },
  ]);
});

test("unknown shapes degrade to no events instead of throwing", async () => {
  const events = await parseRaw(
    ["null", "7", '{"type":"USER_INPUT"}', '{"type":"PLANNER_RESPONSE","tool_calls":"x"}', '{"type":"MYSTERY"}', '{"torn":'].join("\n"),
  );
  expect(events).toEqual([]);
});

test("a call that never got a result does not mislabel the next turn's results", async () => {
  const events = await parse([
    input(wrap("first")),
    { type: "PLANNER_RESPONSE", content: "", tool_calls: [{ name: "run_command", args: {} }, { name: "view_file", args: {} }] },
    { type: "GENERIC", content: "Created At: t\nonly one result" },
    input(wrap("second")),
    { type: "PLANNER_RESPONSE", content: "", tool_calls: [{ name: "grep_search", args: {} }] },
    { type: "GENERIC", content: "Created At: t\nmatch" },
  ]);
  const names = events.filter((e) => e.kind === "tool_result").map((e) => (e as { name?: string }).name);
  expect(names).toEqual(["run_command", "grep_search"]);
});

const step = (step_index: number, record: Record<string, unknown>) => ({ step_index, source: "MODEL", status: "DONE", created_at: "2026-10-01T00:00:00Z", ...record });
const planner = (step_index: number, ...names: string[]) =>
  step(step_index, { type: "PLANNER_RESPONSE", content: "", tool_calls: names.map((name) => ({ name, args: {} })) });
const result = (step_index: number, body: string) => step(step_index, { type: "GENERIC", source: "SYSTEM", content: `Created At: t\n${body}` });

test("a result agy wrote ahead of its planner step stays with the call that made it", async () => {
  // Recorded live (agy 1.4.3): the result of step 3's first call lands before step 3 itself.
  const events = await parse([
    step(0, input(wrap("look around"))),
    planner(1, "view_file"),
    result(2, "a.ts"),
    result(4, "b.ts"),
    planner(3, "list_dir", "grep_search"),
    result(5, "c.ts"),
    result(7, "d.ts"),
    planner(6, "run_command"),
  ]);
  const order = events.filter((e) => e.kind === "tool_call" || e.kind === "tool_result")
    .map((e) => (e.kind === "tool_call" ? `call ${e.name}` : `result ${(e as { name?: string }).name}: ${(e as { output: string }).output}`));
  expect(order).toEqual([
    "call view_file", "result view_file: a.ts",
    "call list_dir", "call grep_search", "result list_dir: b.ts", "result grep_search: c.ts",
    "call run_command", "result run_command: d.ts",
  ]);
});

test("a rewound turn is marked as retracted before the prompt that replaces it", async () => {
  // agy keeps the retracted records and writes the new pass under the same step indices.
  const events = await parse([
    step(0, input(wrap("first"))),
    planner(1),
    step(2, input(wrap("try A"))),
    planner(3, "search_web"),
    result(4, "found A"),
    step(2, input(wrap("try B"))),
    planner(3, "search_web"),
    result(4, "found B"),
  ]);
  const kinds = events.map((e) => (e.kind === "user" ? `user ${(e as { text: string }).text}` : e.kind));
  expect(kinds).toEqual(["user first", "user try A", "tool_call", "tool_result", "note", "user try B", "tool_call", "tool_result"]);
  expect(events.find((e) => e.kind === "note")).toMatchObject({ at: "antigravity-transcript.jsonl:6" });
});
