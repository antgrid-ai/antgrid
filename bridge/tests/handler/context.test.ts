// bridge/tests/handler/context.test.ts
import { test, expect, describe, it } from "bun:test";
import { mkdtempSync, writeFileSync, mkdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Database } from "bun:sqlite";
import {
  stripAnsi, assembleContext,
  PTY_MAX_CHARS, PLAN_MAX_CHARS, DECIDE_MAX_CHARS,
} from "../../src/handler/context";
import { readLastClaudeMessages } from "../../src/agents/claude-code/transcript";

function writeJsonl(lines: object[]): string {
  const p = join(mkdtempSync(join(tmpdir(), "ab-ctx-")), "t.jsonl");
  writeFileSync(p, lines.map((l) => JSON.stringify(l)).join("\n"), "utf8");
  return p;
}

test("readLastClaudeMessages returns the last N message texts", async () => {
  const p = writeJsonl([
    { type: "user", message: { content: "first" } },
    { type: "assistant", message: { content: [{ type: "text", text: "second" }] } },
    { type: "user", message: { content: "third" } },
  ]);
  expect(await readLastClaudeMessages(p, 2)).toEqual(["second", "third"]);
});

test("stripAnsi removes escape sequences", () => {
  expect(stripAnsi("\x1b[31mred\x1b[0m")).toBe("red");
});

test("assembleContext uses the transcript for claude when a path is given", async () => {
  const p = writeJsonl([{ type: "user", message: { content: "hello" } }]);
  const c = await assembleContext({ tool: "claude-code", transcriptPath: p, recentPty: "ignored", purpose: "decide" });
  expect(c.source).toBe("transcript");
  expect(c.text).toContain("hello");
});

test("assembleContext falls back to stripped PTY otherwise", async () => {
  const c = await assembleContext({ tool: "codex", recentPty: "\x1b[32m$ build ok\x1b[0m", purpose: "decide", maxChars: 100 });
  expect(c.source).toBe("pty");
  expect(c.text).toContain("build ok");
  expect(c.text).not.toContain("\x1b");
});

describe("context budgets", () => {
  it("uses plan budgets for purpose=plan (transcript path)", async () => {
    // 60 numbered lines → transcript reader returns last PLAN_MAX_MSGS (50)
    const path = join(mkdtempSync(join(tmpdir(), "ab-ctx-")), "t.jsonl");
    const lines = Array.from({ length: 60 }, (_, i) =>
      JSON.stringify({ message: { content: `msg-${i}` } }));
    writeFileSync(path, lines.join("\n"), "utf8");
    const r = await assembleContext({ tool: "claude-code", transcriptPath: path, recentPty: "", purpose: "plan" });
    expect(r.source).toBe("transcript");
    expect(r.text).toContain("msg-59");
    expect(r.text).not.toContain("msg-9\n"); // 60-50=10 → msg-9 dropped
  });
  it("caps the pty fallback at PTY_MAX_CHARS regardless of purpose", async () => {
    const r = await assembleContext({ tool: "codex", recentPty: "x".repeat(20_000), purpose: "plan" });
    expect(r.source).toBe("pty");
    expect(r.text.length).toBe(PTY_MAX_CHARS);
  });
});

// A chat session's recentOutput is a RENDERED transcript snapshot, not noisy PTY
// scrollback. Capping it at PTY_MAX_CHARS pinned chat sessions to the PTY ceiling
// for every purpose, so a "plan" call could never reach its larger budget.
test("rendered recentKind gets the purpose budget, not the PTY cap", async () => {
  const big = "x".repeat(PLAN_MAX_CHARS + 5_000);
  const rendered = await assembleContext({
    tool: "codex", recentPty: big, purpose: "plan", recentKind: "rendered",
  });
  expect(rendered.text.length).toBe(PLAN_MAX_CHARS);

  const pty = await assembleContext({ tool: "codex", recentPty: big, purpose: "plan" });
  expect(pty.text.length).toBe(PTY_MAX_CHARS);
});

test("rendered recentKind still respects the tighter decide budget", async () => {
  const big = "x".repeat(PLAN_MAX_CHARS + 5_000);
  const r = await assembleContext({
    tool: "codex", recentPty: big, purpose: "decide", recentKind: "rendered",
  });
  expect(r.text.length).toBe(DECIDE_MAX_CHARS);
});

// --- codex/opencode transcript dispatch ---

const CODEX_THREAD = "019f8e9e-acc9-78a2-8f61-803e7bbabac3";

function writeCodexHome(lines: object[]): string {
  const home = mkdtempSync(join(tmpdir(), "ab-ctx-cx-"));
  const dir = join(home, "sessions", "2026", "07", "28");
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, `rollout-x-${CODEX_THREAD}.jsonl`), lines.map((l) => JSON.stringify(l)).join("\n"), "utf8");
  return home;
}

function writeOpencodeDb(texts: string[]): string {
  const path = join(mkdtempSync(join(tmpdir(), "ab-ctx-oc-")), "opencode.db");
  const db = new Database(path);
  db.exec(`
    CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT, time_created INTEGER, time_updated INTEGER, data TEXT);
    CREATE TABLE part (id TEXT PRIMARY KEY, message_id TEXT, session_id TEXT, time_created INTEGER, time_updated INTEGER, data TEXT);
  `);
  texts.forEach((t, i) => {
    db.query("INSERT INTO message VALUES (?, ?, ?, ?, ?)").run(`msg_${i}`, "ses_1", i, i, JSON.stringify({ role: "user" }));
    db.query("INSERT INTO part VALUES (?, ?, ?, ?, ?, ?)").run(`prt_${i}`, `msg_${i}`, "ses_1", i, i, JSON.stringify({ type: "text", text: t }));
  });
  db.close();
  return path;
}

test("codex + agentSessionId reads the rollout and returns the resolved path", async () => {
  const home = writeCodexHome([{ type: "event_msg", payload: { type: "agent_message", message: "built it" } }]);
  const c = await assembleContext({
    tool: "codex", agentSessionId: CODEX_THREAD, recentPty: "ignored", purpose: "decide", codexHome: home,
  });
  expect(c.source).toBe("transcript");
  expect(c.text).toContain("built it");
  expect(c.transcriptPath).toContain(`${CODEX_THREAD}.jsonl`);
});

test("codex without agentSessionId, or with an unfindable thread, falls back to PTY", async () => {
  const noId = await assembleContext({ tool: "codex", recentPty: "tail", purpose: "decide" });
  expect(noId.source).toBe("pty");
  const home = mkdtempSync(join(tmpdir(), "ab-ctx-cx-"));
  const miss = await assembleContext({
    tool: "codex", agentSessionId: "not-there", recentPty: "tail", purpose: "decide", codexHome: home,
  });
  expect(miss.source).toBe("pty");
  expect(miss.transcriptPath).toBeUndefined();
});

test("opencode + agentSessionId reads the db; no transcriptPath is returned", async () => {
  const db = writeOpencodeDb(["question", "answer"]);
  const c = await assembleContext({
    tool: "opencode", agentSessionId: "ses_1", recentPty: "ignored", purpose: "decide", opencodeDbPath: db,
  });
  expect(c.source).toBe("transcript");
  expect(c.text).toBe("question\n---\nanswer");
  expect(c.transcriptPath).toBeUndefined();
});

test("opencode with a missing db falls back to PTY", async () => {
  const c = await assembleContext({
    tool: "opencode", agentSessionId: "ses_1", recentPty: "tail", purpose: "decide",
    opencodeDbPath: join(tmpdir(), "ab-none", "opencode.db"),
  });
  expect(c.source).toBe("pty");
});

test("claude transcript result now echoes its input path", async () => {
  const p = writeJsonl([{ type: "user", message: { content: "hello" } }]);
  const c = await assembleContext({ tool: "claude-code", transcriptPath: p, recentPty: "", purpose: "decide" });
  expect(c.transcriptPath).toBe(p);
});
