import { afterEach, expect, test } from "bun:test";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { HandoffEvent } from "../src/agents/handoff/events";
import type { HandoffSnapshot } from "../src/agents/handoff/types";
import { kimiEvents } from "../src/agents/kimi/handoff-events";
import { kimiFork } from "../src/agents/kimi/fork";

const dirs: string[] = [];
afterEach(() => {
  for (const dir of dirs.splice(0)) rmSync(dir, { recursive: true, force: true });
});

async function parse(records: readonly unknown[], raw?: string): Promise<HandoffEvent[]> {
  const dir = mkdtempSync(join(tmpdir(), "kimi-events-"));
  dirs.push(dir);
  writeFileSync(join(dir, "kimi-wire.jsonl"), raw ?? records.map((record) => JSON.stringify(record)).join("\n") + "\n");
  const manifest: HandoffSnapshot = {
    agent: "kimi", method: "copy", primary: "kimi-wire.jsonl", files: [], references: [], redactions: [], warnings: [],
  };
  const events: HandoffEvent[] = [];
  await kimiEvents(dir, manifest, (event) => events.push(event), new AbortController().signal);
  return events;
}

const prompt = (text: string, origin?: unknown) => ({ type: "turn.prompt", input: [{ type: "text", text }], ...(origin === undefined ? {} : { origin }) });
const users = (events: HandoffEvent[]) => events.filter((event) => event.kind === "user");

test("Kimi's fork parses its own wire", () => {
  expect(kimiFork.events).toBe(kimiEvents);
});

test("genuine user selection honours every origin skip rule", async () => {
  const events = await parse([
    { type: "metadata", protocol_version: "1.5" },
    prompt("injected", { kind: "injection" }),
    prompt("ls", { kind: "shell_command" }),
    prompt("summary text", { kind: "compaction_summary" }),
    prompt("tick", { kind: "system_trigger" }),
    prompt("task", { kind: "task" }),
    prompt("cron", { kind: "cron_job" }),
    prompt("hook", { kind: "hook_result" }),
    prompt("retry", { kind: "retry" }),
    prompt("skill by model", { kind: "skill_activation", trigger: "model" }),
    prompt("/skill typed", { kind: "skill_activation", trigger: "user-slash" }),
    { type: "turn.prompt", input: [{ type: "text", text: "multi" }, { type: "image", url: "x" }, { type: "text", text: "part" }], origin: { kind: "user" } },
    prompt("string origin", "user"),
    prompt("no origin"),
    { type: "turn.prompt", prompt: "plain string prompt", origin: { kind: "user" } },
    prompt("   ", { kind: "user" }),
  ]);
  expect(users(events).map((event) => event.kind === "user" && event.text)).toEqual([
    "/skill typed", "multipart", "string origin", "no origin", "plain string prompt",
  ]);
  expect(users(events).every((event) => event.kind === "user" && event.genuine)).toBe(true);
});

test("a nested Antgrid handoff prompt is emitted as not genuine", async () => {
  const events = await parse([
    prompt("Continue a task handed off from Claude Code. Antgrid saved its context in two files: a, b"),
    prompt("real task"),
  ]);
  expect(users(events).map((event) => event.kind === "user" && event.genuine)).toEqual([false, true]);
});

test("the last compaction carries `summary`, not `contextSummary`, and legacy shapes degrade", async () => {
  const events = await parse([
    { type: "context.apply_compaction", summary: "first", contextSummary: "ctx" },
    { type: "context.apply_compaction", summary: "second", contextSummary: "ctx2 ## Context Recovery" },
    { type: "context.apply_compaction", summary: { content: [{ type: "text", text: "legacy" }] }, count: 3 },
    { type: "context.apply_compaction", summary: 42 },
  ]);
  const compactions = events.filter((event) => event.kind === "compaction");
  expect(compactions.map((event) => event.kind === "compaction" && event.summary)).toEqual(["first", "second", "legacy", undefined]);
  expect(compactions[3]!.kind === "compaction" && compactions[3]!.note).toBeTruthy();
});

test("tail events: assistant text, tool calls and results, never thinking or bookkeeping", async () => {
  const loop = (event: unknown) => ({ type: "context.append_loop_event", agentId: "main", event });
  const events = await parse([
    { type: "llm.request", systemPrompt: "secret" },
    loop({ type: "content.part", part: { type: "think", think: "hmm" } }),
    loop({ type: "content.part", part: { type: "text", text: "I will read it" } }),
    loop({ type: "tool.call", toolCallId: "c1", name: "Read", args: { path: "a.ts" } }),
    loop({ type: "tool.result", toolCallId: "c1", result: { output: "file body", isError: false } }),
    loop({ type: "tool.call", toolCallId: "c2", name: "Bash", args: "ls" }),
    loop({ type: "tool.result", toolCallId: "c2", result: { output: [{ type: "text", text: "boom" }], isError: true } }),
    loop({ type: "tool.result", toolCallId: "gone", result: {} }),
    { type: "usage.record" },
  ]);
  expect(events.map((event) => event.kind)).toEqual(["assistant", "tool_call", "tool_result", "tool_call", "tool_result", "tool_result"]);
  expect(events[0]).toMatchObject({ text: "I will read it", at: "kimi-wire.jsonl:3" });
  expect(events[1]).toMatchObject({ name: "Read", input: '{"path":"a.ts"}' });
  expect(events[2]).toMatchObject({ name: "Read", output: "file body" });
  expect(events[2]!.kind === "tool_result" && events[2]!.isError).toBeUndefined();
  expect(events[3]).toMatchObject({ name: "Bash", input: "ls" });
  expect(events[4]).toMatchObject({ name: "Bash", output: "boom", isError: true });
  expect(events[5]).toMatchObject({ kind: "tool_result", output: "" });
});

test("unknown shapes and torn lines never throw", async () => {
  const events = await parse([], [
    "null", "7", '"x"', "[]",
    JSON.stringify({ type: "turn.prompt", input: 5, origin: 9 }),
    JSON.stringify({ type: "context.append_loop_event", event: "nope" }),
    JSON.stringify({ type: "context.append_loop_event", event: { type: "tool.call", args: { n: 1 } } }),
    '{"type":"turn.prompt","input":[{"type":"te',
  ].join("\n"));
  expect(events.map((event) => event.kind)).toEqual(["tool_call"]);
});
