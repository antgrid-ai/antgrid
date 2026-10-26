import { afterEach, beforeEach, expect, test } from "bun:test";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { codexFork } from "../src/agents/codex/fork";
import { codexEvents } from "../src/agents/codex/handoff-events";
import type { HandoffEvent, HandoffFile, HandoffSnapshot } from "../src/agents/handoff";

let dir: string;
beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), "codex-events-"));
});
afterEach(() => rmSync(dir, { recursive: true, force: true }));

const rec = (type: string, payload: unknown, timestamp = "2026-01-01T00:00:00Z") =>
  JSON.stringify({ timestamp, type, payload });
const item = (it: Record<string, unknown>) => rec("event_msg", { type: "item_completed", item: it });
const user = (...texts: string[]) =>
  item({ type: "UserMessage", content: texts.map((text) => ({ type: "text", text })) });
const agent = (text: string) => item({ type: "AgentMessage", content: [{ type: "Text", text }] });

function manifest(names: string[]): HandoffSnapshot {
  const files: HandoffFile[] = names.map((name, index) => ({
    name,
    role: index === names.length - 1 ? "transcript" : "segment",
    bytes: 0,
    sha256: "",
  }));
  return { agent: "codex", method: "copy", primary: names[names.length - 1]!, files, references: [], redactions: [], warnings: [] };
}

async function run(files: Record<string, string[]>): Promise<HandoffEvent[]> {
  for (const [name, lines] of Object.entries(files)) writeFileSync(join(dir, name), `${lines.join("\n")}\n`);
  const events: HandoffEvent[] = [];
  await codexEvents(dir, manifest(Object.keys(files)), (e) => events.push(e), new AbortController().signal);
  return events;
}

const users = (events: HandoffEvent[]) => events.filter((e) => e.kind === "user");

test("joins split user text parts with no separator and strips the request wrapper", async () => {
  const events = await run({
    "codex-rollout-01.jsonl": [user("## My request for Codex:\nfix the", " bug\nin parser")],
  });
  expect(users(events)[0]).toMatchObject({ text: "fix the bug\nin parser", genuine: true, at: "codex-rollout-01.jsonl:1" });
});

test("the first user message comes from the root segment, which is read first", async () => {
  const events = await run({
    "codex-rollout-01.jsonl": [user("original task")],
    "codex-rollout-02.jsonl": [user("later follow up")],
  });
  expect(users(events).map((e) => (e as { text: string }).text)).toEqual(["original task", "later follow up"]);
  expect(users(events)[0]).toMatchObject({ at: "codex-rollout-01.jsonl:1" });
});

test("a nested Antgrid handoff prompt is not genuine", async () => {
  const prompt =
    "Continue a task handed off from Claude Code. Antgrid saved its context in two files under C:\\p\\.antgrid\\handoff\\x";
  const events = await run({ "codex-rollout-01.jsonl": [user(prompt), user("the real task")] });
  expect(users(events).map((e) => (e as { genuine: boolean }).genuine)).toEqual([false, true]);
});

test("the response_item twins and injected user messages are ignored", async () => {
  const events = await run({
    "codex-rollout-01.jsonl": [
      rec("response_item", { type: "message", role: "user", content: [{ type: "input_text", text: "# AGENTS.md dump" }] }),
      user("typed"),
    ],
  });
  expect(events).toHaveLength(1);
});

test("a compaction emits the note and the plaintext retained user messages, never injected ones", async () => {
  const events = await run({
    "codex-rollout-01.jsonl": [
      rec(
        "compacted",
        {
          message: "",
          replacement_history: [
            { type: "message", role: "user", content: [{ type: "input_text", text: "<environment_context>x</environment_context>" }] },
            { type: "message", role: "user", content: [{ type: "input_text", text: "keep going on parser" }] },
            { type: "message", role: "developer", content: [{ type: "input_text", text: "dev text" }] },
            { type: "compaction", encrypted_content: "AAAA" },
          ],
        },
        "2026-02-02T00:00:00Z",
      ),
    ],
  });
  const compaction = events.find((e) => e.kind === "compaction") as Extract<HandoffEvent, { kind: "compaction" }>;
  expect(compaction.note).toBe("compacted at 2026-02-02T00:00:00Z; Codex encrypts its summary");
  expect(compaction.summary).toContain("keep going on parser");
  expect(compaction.summary).not.toContain("environment_context");
  expect(compaction.summary).not.toContain("dev text");
});

test("a compaction with retained_context summarises both sides of the kept turns in order", async () => {
  const events = await run({
    "codex-rollout-01.jsonl": [
      rec("compacted", {
        message: "",
        retained_context: {
          user_messages: [
            { order: 0, text: "fix the bug" },
            { order: 5, text: "## My request for Codex:\nand add a test" },
          ],
          assistant_messages: [
            { order: 2, text: "looking" },
            { order: 3, text: "fixed" },
          ],
        },
        replacement_history: [{ type: "message", role: "user", content: [{ type: "input_text", text: "replayed context" }] }],
      }),
    ],
  });
  expect(events[0]).toMatchObject({
    kind: "compaction",
    summary: "User: fix the bug\n\nAssistant: looking\n\nAssistant: fixed\n\nUser: and add a test",
  });
});

test("a non-empty compacted message is used as the summary", async () => {
  const events = await run({ "codex-rollout-01.jsonl": [rec("compacted", { message: "plain summary" })] });
  expect(events[0]).toMatchObject({ kind: "compaction", summary: "plain summary" });
});

test("tail items become assistant, tool call and tool result events", async () => {
  const events = await run({
    "codex-rollout-01.jsonl": [
      agent("on it"),
      item({ type: "CommandExecution", command: ["bun", "test"], exit_code: 1, aggregated_output: "boom" }),
      item({ type: "FileChange", changes: { "a.ts": {}, "b.ts": {} } }),
      item({ type: "McpToolCall", server: "docs", tool: "search", arguments: { q: "x" }, result: { isError: true } }),
      item({ type: "Plan", text: "1. do it" }),
      item({ type: "Reasoning", summary_text: ["thinking"] }),
    ],
  });
  expect(events.map((e) => e.kind)).toEqual([
    "assistant",
    "tool_call",
    "tool_result",
    "tool_call",
    "tool_call",
    "tool_result",
    "assistant",
  ]);
  expect(events[1]).toMatchObject({ name: "shell", input: "bun test" });
  expect(events[2]).toMatchObject({ output: "boom\n[exit code 1]", isError: true });
  expect(events[3]).toMatchObject({ input: "a.ts\nb.ts" });
  expect(events[4]).toMatchObject({ name: "docs.search", input: '{"q":"x"}' });
  expect(events[5]).toMatchObject({ isError: true });
  expect(events[6]).toMatchObject({ text: "Plan:\n1. do it" });
});

test("an image view keeps its place in the turn as a tool call naming the file", async () => {
  const events = await run({
    "codex-rollout-01.jsonl": [user("check the layout"), item({ type: "ImageView", id: "exec-1", path: "shots/home.png" }), agent("looks right")],
  });
  expect(events.map((e) => e.kind)).toEqual(["user", "tool_call", "assistant"]);
  expect(events[1]).toMatchObject({ name: "view image", input: "shots/home.png" });
});

test("a usage-limit turn error becomes an assistant note", async () => {
  const events = await run({
    "codex-rollout-01.jsonl": [
      rec("event_msg", { type: "task_complete", error: { message: "limit hit", codex_error_info: "usage_limit_exceeded" } }),
    ],
  });
  expect(events[0]).toMatchObject({ kind: "assistant" });
  expect((events[0] as { text: string }).text).toContain("usage_limit_exceeded");
});

test("unknown shapes and torn lines degrade to fewer events without throwing", async () => {
  const events = await run({
    "codex-rollout-01.jsonl": [
      "{not json",
      "42",
      rec("event_msg", { type: "item_completed", item: "nope" }),
      rec("event_msg", { type: "item_completed", item: { type: "CommandExecution", command: 7 } }),
      rec("compacted", "bad"),
      rec("event_msg", { type: "task_complete", error: 5 }),
    ],
  });
  expect(events.every((e) => e.kind === "tool_call")).toBe(true);
});

test("a legacy rollout's user_message and agent_message events are read", async () => {
  const events = await run({
    "rollout.jsonl": [
      rec("event_msg", { type: "user_message", message: "## My request for Codex:\nport the lexer" }),
      rec("event_msg", { type: "agent_message", message: "starting" }),
    ],
  });
  expect(events.map((e) => e.kind)).toEqual(["user", "assistant"]);
  expect(users(events)[0]).toMatchObject({ text: "port the lexer", genuine: true });
});

test("the registered fork reads through codexEvents", () => {
  expect(codexFork.events).toBe(codexEvents);
});
