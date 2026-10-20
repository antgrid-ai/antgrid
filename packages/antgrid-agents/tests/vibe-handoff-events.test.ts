import { afterEach, expect, test } from "bun:test";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { HandoffEvent } from "../src/agents/handoff/events";
import type { HandoffSnapshot } from "../src/agents/handoff/types";
import { vibeFork } from "../src/agents/mistral-vibe/fork";
import { vibeEvents } from "../src/agents/mistral-vibe/handoff-events";

const dirs: string[] = [];
afterEach(() => {
  for (const dir of dirs.splice(0)) rmSync(dir, { recursive: true, force: true });
});

async function parse(records: readonly unknown[], raw?: string): Promise<HandoffEvent[]> {
  const dir = mkdtempSync(join(tmpdir(), "vibe-events-"));
  dirs.push(dir);
  writeFileSync(join(dir, "vibe-messages.jsonl"), raw ?? records.map((record) => JSON.stringify(record)).join("\n") + "\n");
  const manifest: HandoffSnapshot = {
    agent: "mistral-vibe", method: "copy", primary: "vibe-messages.jsonl", files: [], references: [], redactions: [], warnings: [],
  };
  const events: HandoffEvent[] = [];
  await vibeEvents(dir, manifest, (event) => events.push(event), new AbortController().signal);
  return events;
}

const user = (content: string, extra: Record<string, unknown> = {}) => ({ role: "user", content, injected: false, ...extra });

test("Vibe's fork parses its own log", () => {
  expect(vibeFork.events).toBe(vibeEvents);
});

test("genuine user selection skips injected, boundary and shell records and prefers input_text", async () => {
  const events = await parse([
    { role: "system", content: "you are vibe" },
    user("skill body", { injected: true }),
    user("!ls", { manual_shell: true }),
    user("boundary", { context_boundary: "other" }),
    user("expanded @file contents", { input_text: "what the user typed" }),
    user("no input text"),
    user("   "),
  ]);
  expect(events.filter((event) => event.kind === "user").map((event) => event.kind === "user" && event.text)).toEqual([
    "what the user typed", "no input text",
  ]);
});

test("a nested Antgrid handoff prompt is emitted as not genuine", async () => {
  const events = await parse([
    user("Continue a task handed off from Codex. Antgrid saved its context in two files: a, b"),
    user("read .antgrid/handoff/abc/messages.jsonl please"),
    user("real task"),
  ]);
  expect(events.map((event) => event.kind === "user" && event.genuine)).toEqual([false, false, true]);
});

test("the latest compaction summary is the tagged span, not the replayed user turns", async () => {
  const compaction = (content: string) => user(content, { injected: true, context_boundary: "compaction" });
  const events = await parse([
    compaction("old user turn\n<compaction_summary>\nfirst\n</compaction_summary>"),
    compaction("replayed user turn mentioning nothing\n<compaction_summary>\nsecond\nline\n</compaction_summary>"),
    compaction("no tags at all"),
  ]);
  const compactions = events.filter((event) => event.kind === "compaction");
  expect(compactions).toHaveLength(3);
  expect(compactions[0]!.kind === "compaction" && compactions[0]!.summary).toBe("first");
  expect(compactions[1]!.kind === "compaction" && compactions[1]!.summary).toBe("second\nline");
  expect(compactions[2]!.kind === "compaction" && compactions[2]!.summary).toBeUndefined();
  expect(compactions[2]!.kind === "compaction" && compactions[2]!.note).toBeTruthy();
  expect(events.some((event) => event.kind === "user")).toBe(false);
});

test("tail events: assistant text, tool calls and results, never reasoning", async () => {
  const events = await parse([
    user("fix it"),
    { role: "assistant", content: "looking", reasoning_content: "private", injected: false, tool_calls: [
      { id: "1", index: 0, type: "function", function: { name: "read_file", arguments: '{"path":"a.py"}' } },
      { id: "2", index: 1, type: "function", function: { name: "bash", arguments: "{}" } },
      { id: "3", function: "bad" },
    ] },
    { role: "tool", name: "read_file", tool_call_id: "1", content: "print(1)", injected: false },
    { role: "assistant", content: "", reasoning_content: "only thoughts", injected: false },
    { role: "tool", content: [{ type: "text", text: "parts" }] },
  ]);
  expect(events.map((event) => event.kind)).toEqual(["user", "assistant", "tool_call", "tool_call", "tool_result", "tool_result"]);
  expect(events[1]).toMatchObject({ text: "looking", at: "vibe-messages.jsonl:2" });
  expect(events[2]).toMatchObject({ name: "read_file", input: '{"path":"a.py"}' });
  expect(events[4]).toMatchObject({ name: "read_file", output: "print(1)" });
  expect(events[5]).toMatchObject({ output: "parts" });
  expect(JSON.stringify(events)).not.toContain("private");
});

test("unknown shapes and torn lines never throw", async () => {
  const events = await parse([], [
    "null", "5", "[]", '{"role":"mystery"}', '{"role":"user","content":{"a":1}}',
    '{"role":"assistant","tool_calls":"nope"}',
    '{"role":"user","content":"tor',
  ].join("\n"));
  expect(events).toEqual([]);
});
