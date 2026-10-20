import { afterEach, expect, test } from "bun:test";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { HandoffEvent } from "../src/agents/handoff/events";
import type { HandoffSnapshot } from "../src/agents/handoff/types";
import { kiloHandoffEvents } from "../src/agents/kilo/handoff-events";
import { opencodeFamilyEvents } from "../src/agents/opencode/handoff-events";

const directories: string[] = [];
afterEach(() => {
  for (const dir of directories.splice(0)) rmSync(dir, { recursive: true, force: true });
});

const text = (id: string, value: string, extra: object = {}) => ({ id, type: "text", text: value, ...extra });
const user = (id: string, parts: object[]) => ({ info: { id, role: "user", summary: { diffs: [] } }, parts });
const assistant = (id: string, parts: object[], info: object = {}) => ({ info: { id, role: "assistant", ...info }, parts });

async function parse(messages: unknown[], raw?: string, parser = opencodeFamilyEvents): Promise<HandoffEvent[]> {
  const dir = mkdtempSync(join(tmpdir(), "opencode-events-"));
  directories.push(dir);
  writeFileSync(join(dir, "opencode-session.json"), raw ?? JSON.stringify({ info: {}, messages }));
  const manifest = { agent: "opencode", method: "db-serialize", primary: "opencode-session.json", files: [], references: [], redactions: [], warnings: [] } as HandoffSnapshot;
  const events: HandoffEvent[] = [];
  await parser(dir, manifest, (event) => events.push(event), new AbortController().signal);
  return events;
}

test("a genuine user message skips synthetic, ignored and compaction-only messages", async () => {
  const events = await parse([
    user("m1", [{ id: "p0", type: "compaction", auto: true }]),
    user("m2", [{ id: "p1", type: "subtask", prompt: "x" }]),
    user("m3", [text("p2", "Called the Read tool", { synthetic: true }), text("p3", "hidden", { ignored: true })]),
    user("m4", [text("p4", "fix the build"), text("p5", "and the lint", { synthetic: false })]),
  ]);
  expect(events).toEqual([{ kind: "user", text: "fix the build\nand the lint", genuine: true, at: "m4" }]);
});

test("an Antgrid handoff prompt is a non-genuine user event", async () => {
  const prompt = "Continue a task handed off from Codex. Antgrid saved its context in two files under C:\\p\\.antgrid\\handoff\\x.";
  const events = await parse([user("m1", [text("p1", prompt)]), user("m2", [text("p2", "real follow-up")])]);
  expect(events.map((event) => (event.kind === "user" ? event.genuine : null))).toEqual([false, true]);
});

test("the compaction summary message becomes a compaction event, the last one winning in order", async () => {
  const summary = (id: string, body: string, info: object = {}) =>
    assistant(id, [text(`${id}p`, body)], { summary: true, mode: "compaction", finish: "stop", ...info });
  const events = await parse([
    user("u1", [text("a", "task")]),
    summary("s1", "first summary"),
    summary("s2", "errored summary", { error: { name: "x" } }),
    summary("s3", "unfinished summary", { finish: undefined }),
    assistant("a1", [text("b", "plain reply")], { summary: false }),
    summary("s4", "second summary"),
  ]);
  const compactions = events.filter((event) => event.kind === "compaction");
  expect(compactions.map((event) => (event as { summary?: string }).summary)).toEqual(["first summary", "second summary"]);
  expect(events.filter((event) => event.kind === "assistant").map((event) => (event as { text: string }).text)).toEqual(["errored summary", "unfinished summary", "plain reply"]);
});

test("a user message's per-turn summary object is not mistaken for a compaction", async () => {
  const events = await parse([{ info: { id: "u", role: "user", summary: true, mode: "compaction", finish: "stop" }, parts: [text("p", "hello")] }]);
  expect(events).toEqual([{ kind: "user", text: "hello", genuine: true, at: "u" }]);
});

test("tool parts yield a call and its output or error; reasoning and patches are skipped", async () => {
  const events = await parse([
    assistant("a1", [
      { id: "r", type: "reasoning", text: "thinking" },
      { id: "t1", type: "tool", tool: "bash", state: { status: "completed", input: { command: "ls" }, output: "a.ts" } },
      { id: "t2", type: "tool", tool: "read", state: { status: "error", input: { path: "x" }, error: "ENOENT" } },
      { id: "t3", type: "tool", tool: "grep", state: { status: "running", input: { q: "y" } } },
      { id: "pa", type: "patch", hash: "h", files: [] },
      { id: "s", type: "step-finish" },
    ]),
  ]);
  expect(events).toEqual([
    { kind: "tool_call", name: "bash", input: '{"command":"ls"}', at: "a1" },
    { kind: "tool_result", name: "bash", output: "a.ts", at: "a1" },
    { kind: "tool_call", name: "read", input: '{"path":"x"}', at: "a1" },
    { kind: "tool_result", name: "read", output: "ENOENT", isError: true, at: "a1" },
    { kind: "tool_call", name: "grep", input: '{"q":"y"}', at: "a1" },
  ]);
});

test("unknown shapes and unreadable files degrade to fewer events without throwing", async () => {
  expect(await parse([], "not json")).toEqual([]);
  expect(await parse([], JSON.stringify({ messages: "nope" }))).toEqual([]);
  expect(await parse([null, 3, { info: 4 }, { info: { role: "user" } }, { info: { role: "assistant" }, parts: "x" }])).toEqual([]);
});

test("Kilo reads the same document shape", async () => {
  const events = await parse([user("m1", [text("p", "kilo task")])], undefined, kiloHandoffEvents);
  expect(events).toEqual([{ kind: "user", text: "kilo task", genuine: true, at: "m1" }]);
});
