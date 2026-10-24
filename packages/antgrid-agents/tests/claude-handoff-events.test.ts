import { afterEach, beforeEach, expect, test } from "bun:test";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { claudeFork } from "../src/agents/claude-code/fork";
import type { HandoffEvent, HandoffSnapshot } from "../src/agents/handoff";

let dir: string;
beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), "claude-events-"));
});
afterEach(() => rmSync(dir, { recursive: true, force: true }));

const manifest = (): HandoffSnapshot => ({
  agent: "claude-code",
  method: "copy",
  primary: "claude-code.jsonl",
  files: [],
  references: [],
  redactions: [],
  warnings: [],
});

async function parseRaw(raw: string): Promise<HandoffEvent[]> {
  writeFileSync(join(dir, "claude-code.jsonl"), raw);
  const out: HandoffEvent[] = [];
  await claudeFork.events(dir, manifest(), (e) => out.push(e), new AbortController().signal);
  return out;
}

const parse = (records: unknown[]) => parseRaw(`${records.map((r) => JSON.stringify(r)).join("\n")}\n`);

const user = (content: unknown, extra: Record<string, unknown> = {}) => ({ type: "user", message: { role: "user", content }, ...extra });
const genuine = (events: HandoffEvent[]) => events.filter((e) => e.kind === "user" && e.genuine).map((e) => (e as { text: string }).text);

test("selects the typed prompt and skips every non-user record shape", async () => {
  const events = await parse([
    user("meta", { isMeta: true }),
    user("<local-command-caveat>x</local-command-caveat>"),
    user("<command-name>/clear</command-name>"),
    user("<task-notification>done</task-notification>"),
    user("<bash-input>ls</bash-input>"),
    user("<system-reminder>r</system-reminder>"),
    user("[Request interrupted by user]"),
    user("side", { isSidechain: true }),
    user("from a peer", { origin: { kind: "peer" } }),
    user("summary text", { isCompactSummary: true }),
    user([{ type: "tool_result", tool_use_id: "t1", content: "out" }]),
    user("   "),
    user([{ type: "text", text: "build the " }, { type: "text", text: "thing" }], { origin: { kind: "human" } }),
    user("second prompt"),
  ]);
  expect(genuine(events)).toEqual(["build the thing", "second prompt"]);
});

test("unwraps a slash command's arguments and drops one without arguments", async () => {
  const events = await parse([
    user("<command-name>/fix</command-name><command-args>repair the parser</command-args>"),
    user("<command-name>/clear</command-name><command-args></command-args>"),
  ]);
  expect(genuine(events)).toEqual(["repair the parser"]);
});

test("an Antgrid handoff prompt is emitted as not genuine", async () => {
  const events = await parse([
    user("Continue a task handed off from Codex. Antgrid saved its context in two files under .antgrid/handoff/abc/"),
    user("the real task"),
  ]);
  expect(events.map((e) => e.kind === "user" && e.genuine)).toEqual([false, true]);
});

test("every compaction summary is reported so the latest one wins", async () => {
  const events = await parse([
    user("first summary", { isCompactSummary: true }),
    user("work"),
    user("second summary", { isCompactSummary: true }),
  ]);
  const compactions = events.filter((e) => e.kind === "compaction");
  expect(compactions.map((e) => (e as { summary?: string }).summary)).toEqual(["first summary", "second summary"]);
  expect(events.at(-1)).toMatchObject({ kind: "compaction", summary: "second summary", at: "claude-code.jsonl:3" });
});

test("tail events carry text, tool calls and named results, never toolUseResult or thinking", async () => {
  const events = await parse([
    {
      type: "assistant",
      message: {
        content: [
          { type: "thinking", thinking: "hidden" },
          { type: "text", text: "looking" },
          { type: "tool_use", id: "t1", name: "Bash", input: { command: "ls" } },
        ],
      },
    },
    { ...user([{ type: "tool_result", tool_use_id: "t1", content: [{ type: "text", text: "a.txt" }], is_error: true }]), toolUseResult: { stdout: "HUGE" } },
    { type: "attachment", attachment: {} },
    { type: "assistant", isSidechain: true, message: { content: [{ type: "text", text: "sub" }] } },
  ]);
  expect(events).toEqual([
    { kind: "assistant", text: "looking", at: "claude-code.jsonl:1" },
    { kind: "tool_call", name: "Bash", input: '{"command":"ls"}', at: "claude-code.jsonl:1" },
    { kind: "tool_result", name: "Bash", output: "a.txt", isError: true, at: "claude-code.jsonl:2" },
  ]);
});

test("unknown shapes and torn lines degrade to fewer events instead of throwing", async () => {
  const events = await parseRaw(
    [
      "null",
      "42",
      '"x"',
      '{"type":"user","message":7}',
      '{"type":"assistant","message":{"content":"str"}}',
      '{"type":"user","message":{"content":[null,{"type":"tool_result"}]}}',
      '{"torn":',
    ].join("\n"),
  );
  expect(events).toEqual([{ kind: "tool_result", output: "", at: "claude-code.jsonl:6" }]);
});

test("a built-in local command's arguments are not the user's task, but a prompt command's are", async () => {
  const events = await parse([
    user("<command-name>/model</command-name><command-message>model</command-message><command-args>sonnet</command-args>"),
    user("<local-command-stdout>Set model to sonnet</local-command-stdout>"),
    user("<command-name>/compact</command-name><command-args>keep the db notes</command-args>"),
    user("<local-command-stdout>Compacted</local-command-stdout>"),
    user("<command-name>/fix</command-name><command-args>repair the parser</command-args>"),
    user("expanded skill body", { isMeta: true }),
    user("the real task"),
  ]);
  expect(genuine(events)).toEqual(["repair the parser", "the real task"]);
});

test("a prompt command that ends the file is still emitted", async () => {
  const events = await parse([user("<command-name>/fix</command-name><command-args>last words</command-args>")]);
  expect(genuine(events)).toEqual(["last words"]);
});
