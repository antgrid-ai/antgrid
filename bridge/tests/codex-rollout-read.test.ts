// bridge/tests/codex-rollout-read.test.ts
import { test, expect } from "bun:test";
import { mkdtempSync, mkdirSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { findCodexRolloutPath, readLastCodexMessages } from "../src/codex/codex-rollout-read";

const THREAD = "019f8e9e-acc9-78a2-8f61-803e7bbabac3";

// Fixture home with sessions/<Y>/<M>/<D>/rollout-<ts>-<id>.jsonl, mirroring
// codex-rs recorder.rs layout (local-time date dirs, thread id as filename tail).
function makeHome(lines: object[] | string, day = "2026/07/28"): { home: string; path: string } {
  const home = mkdtempSync(join(tmpdir(), "ab-codex-"));
  const dir = join(home, "sessions", ...day.split("/"));
  mkdirSync(dir, { recursive: true });
  const path = join(dir, `rollout-2026-07-28T10-00-00-${THREAD}.jsonl`);
  const raw = typeof lines === "string" ? lines : lines.map((l) => JSON.stringify(l)).join("\n");
  writeFileSync(path, raw, "utf8");
  return { home, path };
}

const userMsg = (text: string) => ({ timestamp: "t", type: "event_msg", payload: { type: "user_message", message: text } });
const agentMsg = (text: string) => ({ timestamp: "t", type: "event_msg", payload: { type: "agent_message", message: text } });

test("findCodexRolloutPath finds the file whose name ends with the thread id", async () => {
  const { home, path } = makeHome([userMsg("hi")]);
  expect(await findCodexRolloutPath(THREAD, home)).toBe(path);
});

test("findCodexRolloutPath returns undefined on miss and on a missing home", async () => {
  const { home } = makeHome([userMsg("hi")]);
  expect(await findCodexRolloutPath("0000-not-there", home)).toBeUndefined();
  expect(await findCodexRolloutPath(THREAD, join(home, "nope"))).toBeUndefined();
});

test("findCodexRolloutPath searches newest date dirs first", async () => {
  const home = mkdtempSync(join(tmpdir(), "ab-codex-"));
  for (const day of ["2026/07/01", "2026/07/28"]) {
    const dir = join(home, "sessions", ...day.split("/"));
    mkdirSync(dir, { recursive: true });
    writeFileSync(join(dir, `rollout-x-${THREAD}.jsonl`), "", "utf8");
  }
  expect(await findCodexRolloutPath(THREAD, home)).toContain(join("2026", "07", "28"));
});

test("readLastCodexMessages extracts event_msg user/agent text, last n, in order", async () => {
  const { path } = makeHome([userMsg("one"), agentMsg("two"), userMsg("three")]);
  expect(await readLastCodexMessages(path, 2)).toEqual(["two", "three"]);
});

test("strips the '## My request for Codex:' wrapper from user messages", async () => {
  const { path } = makeHome([userMsg("<user_instructions>stuff</user_instructions>\n\n## My request for Codex: fix the bug")]);
  expect(await readLastCodexMessages(path, 10)).toEqual(["fix the bug"]);
});

test("skips response_item twins, unknown types, and garbage lines", async () => {
  const { path } = makeHome(
    [
      JSON.stringify({ type: "response_item", payload: { type: "message", role: "user", content: [{ type: "input_text", text: "dup" }] } }),
      JSON.stringify(userMsg("dup")),
      JSON.stringify({ type: "world_state", payload: { full: true } }),
      "{not json",
      JSON.stringify(agentMsg("done")),
    ].join("\n"),
  );
  expect(await readLastCodexMessages(path, 10)).toEqual(["dup", "done"]);
});

test("a compacted line drops earlier messages and keeps a non-empty summary", async () => {
  const { path } = makeHome([
    userMsg("old"),
    { timestamp: "t", type: "compacted", payload: { message: "summary of old", replacement_history: [] } },
    agentMsg("new"),
  ]);
  expect(await readLastCodexMessages(path, 10)).toEqual(["summary of old", "new"]);
});

test("an empty compacted summary is not emitted as a message", async () => {
  const { path } = makeHome([
    userMsg("old"),
    { timestamp: "t", type: "compacted", payload: { message: "", replacement_history: [] } },
    agentMsg("new"),
  ]);
  expect(await readLastCodexMessages(path, 10)).toEqual(["new"]);
});

test("readLastCodexMessages returns [] for a missing file", async () => {
  expect(await readLastCodexMessages(join(tmpdir(), "ab-none", "x.jsonl"), 5)).toEqual([]);
});
