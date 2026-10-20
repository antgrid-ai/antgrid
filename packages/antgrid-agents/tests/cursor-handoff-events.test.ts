import { afterEach, expect, test } from "bun:test";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { cursorHandoffEvents } from "../src/agents/cursor-agent/handoff-events";
import type { HandoffEvent } from "../src/agents/handoff/events";
import type { HandoffSnapshot } from "../src/agents/handoff/types";

const directories: string[] = [];
afterEach(() => {
  for (const dir of directories.splice(0)) rmSync(dir, { recursive: true, force: true });
});

const message = (body: object, extra: object = {}) => ({ type: "message", blobId: "b", ...extra, message: body });
const query = (value: string) => ({ role: "user", content: [{ type: "text", text: `<timestamp>now</timestamp>\n<user_query>\n${value}\n</user_query>` }] });

async function parse(lines: unknown[]): Promise<HandoffEvent[]> {
  const dir = mkdtempSync(join(tmpdir(), "cursor-events-"));
  directories.push(dir);
  writeFileSync(join(dir, "cursor-chat.jsonl"), lines.map((line) => (typeof line === "string" ? line : JSON.stringify(line))).join("\n") + "\n");
  const manifest = { agent: "cursor-agent", method: "db-serialize", primary: "cursor-chat.jsonl", files: [], references: [], redactions: [], warnings: [] } as HandoffSnapshot;
  const events: HandoffEvent[] = [];
  await cursorHandoffEvents(dir, manifest, (event) => events.push(event), new AbortController().signal);
  return events;
}

test("the genuine user message is the unwrapped user_query; injected context and system records are skipped", async () => {
  const events = await parse([
    { type: "header", chatId: "c" },
    message({ role: "system", content: "You are Cursor" }),
    message({ role: "user", content: "<user_info>OS: windows</user_info>" }),
    message({ role: "user", content: [{ type: "text", text: "<system_reminder>be nice</system_reminder>" }] }),
    message(query("<cursor_commands>/plan</cursor_commands>\nbuild the thing")),
  ]);
  expect(events).toEqual([{ kind: "user", text: "build the thing", genuine: true, at: "cursor-chat.jsonl:5" }]);
});

test("a nested Antgrid handoff prompt is not genuine", async () => {
  const events = await parse([
    message(query("Continue a task handed off from Claude Code. Antgrid saved its context in two files under D:\\x\\.antgrid\\handoff\\y")),
  ]);
  expect(events).toHaveLength(1);
  expect(events[0]).toMatchObject({ kind: "user", genuine: false });
});

test("the latest compaction wins in stream order, from an archive or an isSummary message", async () => {
  const events = await parse([
    { type: "summary_archive", archiveIndex: 0, summary: "archive one" },
    { type: "summary_archive", archiveIndex: 1 },
    message({ role: "user", content: [{ type: "text", text: "summary body" }], providerOptions: { cursor: { isSummary: true } } }),
  ]);
  expect(events.filter((event) => event.kind === "compaction").map((event) => (event as { summary?: string }).summary)).toEqual([
    "archive one",
    "summary body",
  ]);
  expect(events.some((event) => event.kind === "user")).toBe(false);
});

test("archived messages precede live ones and the first user message is found among them", async () => {
  const events = await parse([
    { type: "summary_archive", summary: "s" },
    message(query("original task"), { archived: true, archiveIndex: 0 }),
    message(query("later task")),
  ]);
  const users = events.filter((event) => event.kind === "user") as { text: string }[];
  expect(users.map((event) => event.text)).toEqual(["original task", "later task"]);
});

test("tail events carry assistant text, tool calls and results; reasoning is skipped", async () => {
  const events = await parse([
    message({
      role: "assistant",
      content: [
        { type: "reasoning", text: "hmm" },
        { type: "redacted-reasoning", data: "x" },
        { type: "text", text: "Looking." },
        { type: "tool-call", toolCallId: "t", toolName: "Shell", args: { command: "ls" } },
      ],
    }),
    message({ role: "tool", content: [{ type: "tool-result", toolCallId: "t", toolName: "Shell", result: "a.ts" }] }),
    message({
      role: "tool",
      content: [{ type: "tool-result", toolName: "Read", result: "" }],
      providerOptions: { cursor: { highLevelToolCallResult: { output: "fallback body" } } },
    }),
    message({ role: "assistant", content: "plain string reply" }),
  ]);
  expect(events.map(({ at: _at, ...rest }) => rest)).toEqual([
    { kind: "assistant", text: "Looking." },
    { kind: "tool_call", name: "Shell", input: '{"command":"ls"}' },
    { kind: "tool_result", name: "Shell", output: "a.ts" },
    { kind: "tool_result", name: "Read", output: "fallback body" },
    { kind: "assistant", text: "plain string reply" },
  ]);
});

test("torn lines and unknown shapes are skipped without throwing", async () => {
  const events = await parse(["{\"type\":\"mess", { type: "message", message: 4 }, { type: "other" }, 7, message({ role: "weird" }), message(query("ok"))]);
  expect(events).toEqual([{ kind: "user", text: "ok", genuine: true, at: "cursor-chat.jsonl:6" }]);
});
