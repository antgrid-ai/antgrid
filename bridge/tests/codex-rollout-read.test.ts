// bridge/tests/codex-rollout-read.test.ts
import { test, expect } from "bun:test";
import { Database } from "bun:sqlite";
import { mkdtempSync, mkdirSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { findCodexRolloutPath, readLastCodexMessages } from "../../packages/antgrid-agents/src/agents/codex/rollout-read";

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

// Paginated rollouts (codex 0.16x) persist only item_completed for messages.
const completed = (item: object) => ({ timestamp: "t", type: "event_msg", payload: { type: "item_completed", thread_id: THREAD, turn_id: "turn", item } });
const pagedUser = (...parts: string[]) => completed({ type: "UserMessage", id: "u", content: parts.map((text) => ({ type: "text", text, text_elements: [] })) });
const pagedAgent = (text: string, phase = "final_answer") => completed({ type: "AgentMessage", id: "a", content: [{ type: "Text", text }], phase });

test("readLastCodexMessages reads paginated UserMessage/AgentMessage items", async () => {
  const { path } = makeHome([
    pagedUser("fix the bug"),
    completed({ type: "Reasoning", id: "r", summary_text: ["thinking"] }),
    pagedAgent("looking", "commentary"),
    completed({ type: "CommandExecution", id: "c", command: "rg bug" }),
    { type: "response_item", payload: { type: "message", role: "assistant", content: [{ type: "output_text", text: "done" }] } },
    pagedAgent("done"),
  ]);
  expect(await readLastCodexMessages(path, 10)).toEqual(["fix the bug", "looking", "done"]);
});

test("a paginated user message split across text parts is joined as written", async () => {
  const { path } = makeHome([
    pagedUser("first line\n", "> quoted\n", "last line"),
    completed({ type: "UserMessage", id: "u2", content: [{ type: "local_image", path: "/tmp/x.png" }, { type: "text", text: "see image", text_elements: [] }] }),
  ]);
  expect(await readLastCodexMessages(path, 10)).toEqual(["first line\n> quoted\nlast line", "see image"]);
});

// Current compaction checkpoint: `message` is empty and the recent turns ride
// in retained_context, user and assistant lists kept apart and keyed by order.
const retained = (order: number, text: string, extra: object = {}) => ({
  revision: `retained_019f8e9e-0000-7000-8000-${String(order).padStart(12, "0")}`,
  order,
  turn_id: "019f8e9e-1111-7000-8000-000000000001",
  message_id: `msg_${order}`,
  text,
  complete: true,
  ...extra,
});
const checkpoint = (user: object[], assistant: object[]) => ({
  timestamp: "t",
  type: "compacted",
  payload: {
    message: "",
    replacement_history: [
      { type: "message", id: "msg_rh", role: "user", content: [{ type: "input_text", text: "replayed context" }] },
      { type: "compaction", encrypted_content: "opaque" },
    ],
    replacement_history_metadata: {},
    retained_context: {
      user_messages: user,
      assistant_messages: assistant,
      user_messages_incomplete: false,
      assistant_messages_incomplete: true,
      next_order: 9,
      verified_answers: [],
      incomplete: false,
    },
    window_number: 2,
    window_id: "019f8e9e-2222-7000-8000-000000000001",
    compaction_response_id: "resp_synthetic",
    resume_metadata: {},
  },
});

test("an empty-summary compaction keeps its retained turns, interleaved by order", async () => {
  const { path } = makeHome([
    pagedUser("dropped"),
    checkpoint(
      [retained(0, "fix the bug", { complete: false }), retained(5, "<ctx>x</ctx>\n## My request for Codex: and add a test")],
      [retained(2, "looking", { phase: "commentary" }), retained(3, "fixed", { phase: "final_answer" }), retained(7, "  ", { phase: "commentary" })],
    ),
    completed({ type: "ContextCompaction", id: "cc" }),
    pagedAgent("test added"),
  ]);
  expect(await readLastCodexMessages(path, 10)).toEqual(["fix the bug", "looking", "fixed", "and add a test", "test added"]);
});

test("findCodexRolloutPath finds a rolled-back thread's revision file", async () => {
  const home = mkdtempSync(join(tmpdir(), "ab-codex-"));
  const dir = join(home, "sessions", "2026", "07", "28");
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, `rollout-2026-07-28T10-00-00-${THREAD}.jsonl`), "", "utf8");
  const revision = join(dir, `rollout-2026-07-28T11-00-00-${THREAD}_019f8e9e-0000-7000-8000-000000000001.jsonl`);
  writeFileSync(revision, "", "utf8");
  expect(await findCodexRolloutPath(THREAD, home)).toBe(revision);
});

test("findCodexRolloutPath prefers the rollout codex's state DB records", async () => {
  const { home } = makeHome([pagedUser("hi")]);
  const elsewhere = join(home, "sessions", "2026", "07", "29");
  mkdirSync(elsewhere, { recursive: true });
  const recorded = join(elsewhere, `rollout-2026-07-29T09-00-00-${THREAD}_rev.jsonl`);
  writeFileSync(recorded, "", "utf8");
  const db = new Database(join(home, "state_5.sqlite"));
  db.exec("CREATE TABLE threads (id TEXT PRIMARY KEY, rollout_path TEXT)");
  db.query("INSERT INTO threads VALUES (?, ?)").run(THREAD, recorded);
  db.close();
  expect(await findCodexRolloutPath(THREAD, home)).toBe(recorded);
});

test("findCodexRolloutPath falls back to the scan when the recorded file is gone", async () => {
  const { home, path } = makeHome([pagedUser("hi")]);
  const db = new Database(join(home, "state_5.sqlite"));
  db.exec("CREATE TABLE threads (id TEXT PRIMARY KEY, rollout_path TEXT)");
  db.query("INSERT INTO threads VALUES (?, ?)").run(THREAD, join(home, "compressed-away.jsonl"));
  db.close();
  expect(await findCodexRolloutPath(THREAD, home)).toBe(path);
});

test("readLastCodexMessages returns [] for a missing file", async () => {
  expect(await readLastCodexMessages(join(tmpdir(), "ab-none", "x.jsonl"), 5)).toEqual([]);
});
