import { afterEach, beforeEach, expect, test } from "bun:test";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { copilotFork } from "../src/agents/github-copilot/fork";
import type { HandoffEvent, HandoffSnapshot } from "../src/agents/handoff";

let dir: string;
beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), "copilot-events-"));
});
afterEach(() => rmSync(dir, { recursive: true, force: true }));

const manifest = (): HandoffSnapshot => ({
  agent: "github-copilot",
  method: "copy",
  primary: "copilot-events.jsonl",
  files: [],
  references: [],
  redactions: [],
  warnings: [],
});

async function parseRaw(raw: string): Promise<HandoffEvent[]> {
  writeFileSync(join(dir, "copilot-events.jsonl"), raw);
  const out: HandoffEvent[] = [];
  await copilotFork.events(dir, manifest(), (e) => out.push(e), new AbortController().signal);
  return out;
}

const parse = (records: unknown[]) => parseRaw(`${records.map((r) => JSON.stringify(r)).join("\n")}\n`);

const msg = (data: Record<string, unknown>, extra: Record<string, unknown> = {}) => ({ type: "user.message", data, ...extra });
const genuine = (events: HandoffEvent[]) => events.filter((e) => e.kind === "user" && e.genuine).map((e) => (e as { text: string }).text);

test("selects the typed prompt: no source, no autopilot, main agent only, content not transformedContent", async () => {
  const events = await parse([
    msg({ content: "skill text", source: "skill-pdf" }),
    msg({ content: "auto", isAutopilotContinuation: true }),
    msg({ content: "from a subagent" }, { agentId: "a1" }),
    msg({ content: "nested", parentToolCallId: "t9" }),
    msg({ content: "  " }),
    msg({ transformedContent: "<wrapped>" }),
    msg({ content: "fix the build", transformedContent: "<wrapped>fix the build" }),
    msg({ content: "next" }),
  ]);
  expect(genuine(events)).toEqual(["fix the build", "next"]);
});

test("a nested Antgrid handoff prompt is not genuine", async () => {
  const events = await parse([
    msg({ content: "Continue a task handed off from Claude Code. Antgrid saved its context in two files" }),
    msg({ content: "real" }),
  ]);
  expect(events.map((e) => e.kind === "user" && e.genuine)).toEqual([false, true]);
});

test("successful compactions are reported so the latest wins; a failed one is not", async () => {
  const events = await parse([
    { type: "session.compaction_complete", data: { success: true, summaryContent: "one" } },
    { type: "session.compaction_complete", data: { success: false, summaryContent: "bad" } },
    { type: "session.compaction_complete", data: { success: true, summaryContent: "two" } },
  ]);
  expect(events.map((e) => (e as { summary?: string }).summary)).toEqual(["one", "two"]);
  expect(events.at(-1)).toMatchObject({ kind: "compaction", summary: "two", at: "copilot-events.jsonl:3" });
});

test("tail events pair results with the call name and ignore reasoning, model and subagent traffic", async () => {
  const events = await parse([
    { type: "assistant.message", data: { content: "on it", reasoningText: "secret", toolRequests: [{ name: "view" }] } },
    { type: "assistant.message", data: { content: "" } },
    { type: "tool.execution_start", data: { toolCallId: "c1", toolName: "view", arguments: { path: "a.ts" } } },
    { type: "tool.execution_complete", data: { toolCallId: "c1", success: true, result: { content: "file body", detailedContent: "full" } } },
    { type: "tool.execution_complete", data: { toolCallId: "c2", success: false, error: { message: "denied" } } },
    { type: "tool.execution_start", data: { toolCallId: "c3", toolName: "rg", parentToolCallId: "p" } },
    { type: "model.call", data: { content: "x" } },
    { type: "hook.start", data: {} },
  ]);
  expect(events).toEqual([
    { kind: "assistant", text: "on it", at: "copilot-events.jsonl:1" },
    { kind: "tool_call", name: "view", input: '{"path":"a.ts"}', at: "copilot-events.jsonl:3" },
    { kind: "tool_result", name: "view", output: "file body", at: "copilot-events.jsonl:4" },
    { kind: "tool_result", output: "denied", isError: true, at: "copilot-events.jsonl:5" },
  ]);
});

test("unknown shapes degrade to no events instead of throwing", async () => {
  const events = await parseRaw(
    ["null", "[]", '{"type":"user.message"}', '{"type":"user.message","data":"x"}', '{"type":"tool.execution_start","data":{}}', '{"torn":'].join("\n"),
  );
  expect(events).toEqual([]);
});
