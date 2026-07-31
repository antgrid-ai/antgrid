import { afterEach, describe, expect, test } from "bun:test";
import { Database } from "bun:sqlite";
import { mkdtempSync, rmSync, writeFileSync, mkdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  resolveCodexThreadName,
  resolveCodexThreadTitle,
  resolveClaudeTranscriptTitle,
} from "../src/title-resolver";
import { resolveStructuredTitle } from "../src/agents/title-dispatch";

const dirs: string[] = [];
function tmp() { const d = mkdtempSync(join(tmpdir(), "ab-tr-")); dirs.push(d); return d; }
afterEach(() => { for (const d of dirs.splice(0)) try { rmSync(d, { recursive: true, force: true }); } catch {} });

/** Mirror the shape Codex's CLI persists: a `state_<N>.sqlite` with a threads table. */
function writeStateDb(
  home: string,
  version: number,
  rows: Array<{ id: string; title?: string | null; first_user_message?: string | null }>,
) {
  const db = new Database(join(home, `state_${version}.sqlite`));
  db.run("CREATE TABLE threads (id TEXT PRIMARY KEY, title TEXT, first_user_message TEXT)");
  const stmt = db.query("INSERT INTO threads (id, title, first_user_message) VALUES (?, ?, ?)");
  for (const r of rows) stmt.run(r.id, r.title ?? null, r.first_user_message ?? null);
  db.close();
}

describe("resolveCodexThreadName", () => {
  test("returns the most recent thread_name for the id", async () => {
    const home = tmp();
    writeFileSync(join(home, "session_index.jsonl"),
      `{"id":"t1","thread_name":"Old","updated_at":"2024-01-01T00:00:00Z"}\n` +
      `{"id":"t2","thread_name":"Other","updated_at":"2024-01-01T00:00:00Z"}\n` +
      `{"id":"t1","thread_name":"New title","updated_at":"2024-01-02T00:00:00Z"}\n`);
    expect(await resolveCodexThreadName("t1", home)).toEqual({ title: "New title", kind: "generated" });
  });
  test("missing file → null", async () => {
    expect(await resolveCodexThreadName("t1", tmp())).toBeNull();
  });
  test("garbage lines are skipped, not thrown", async () => {
    const home = tmp();
    writeFileSync(join(home, "session_index.jsonl"),
      `not json\n{"id":"t1","thread_name":"Good","updated_at":"z"}\n{partial`);
    expect(await resolveCodexThreadName("t1", home)).toEqual({ title: "Good", kind: "generated" });
  });
  test("unknown id → null", async () => {
    const home = tmp();
    writeFileSync(join(home, "session_index.jsonl"),
      `{"id":"t1","thread_name":"Good","updated_at":"z"}\n`);
    expect(await resolveCodexThreadName("nope", home)).toBeNull();
  });
});

describe("resolveCodexThreadTitle", () => {
  test("reads title from the threads table", async () => {
    const home = tmp();
    writeStateDb(home, 5, [{ id: "t1", title: "My title", first_user_message: "do the thing" }]);
    expect(await resolveCodexThreadTitle("t1", home)).toEqual({ title: "My title", kind: "generated" });
  });
  test("falls back to first_user_message when title is blank", async () => {
    const home = tmp();
    writeStateDb(home, 5, [{ id: "t1", title: "   ", first_user_message: "first message" }]);
    expect(await resolveCodexThreadTitle("t1", home)).toEqual({ title: "first message", kind: "first-message" });
  });
  // The case that drives generation. Codex's CLI writes the first user message
  // INTO `title`, so a non-empty title is not evidence the thread was named —
  // only divergence from first_user_message is.
  test("a title that merely echoes first_user_message is reported as first-message", async () => {
    const home = tmp();
    writeStateDb(home, 5, [{ id: "t1", title: "add a retry to the uploader", first_user_message: "add a retry to the uploader" }]);
    expect(await resolveCodexThreadTitle("t1", home))
      .toEqual({ title: "add a retry to the uploader", kind: "first-message" });
  });
  test("picks the newest state_<N>.sqlite", async () => {
    const home = tmp();
    writeStateDb(home, 4, [{ id: "t1", title: "old schema" }]);
    writeStateDb(home, 12, [{ id: "t1", title: "new schema" }]);
    expect(await resolveCodexThreadTitle("t1", home)).toEqual({ title: "new schema", kind: "generated" });
  });
  test("missing DB → null", async () => {
    expect(await resolveCodexThreadTitle("t1", tmp())).toBeNull();
  });
  test("unknown id → null", async () => {
    const home = tmp();
    writeStateDb(home, 5, [{ id: "t1", title: "x" }]);
    expect(await resolveCodexThreadTitle("nope", home)).toBeNull();
  });
});

describe("resolveClaudeTranscriptTitle", () => {
  test("prefers the manual /rename custom-title over a summary and user message", async () => {
    const d = tmp(); const p = join(d, "t.jsonl");
    writeFileSync(p,
      `{"type":"custom-title","customTitle":"Renamed by user","sessionId":"s1"}\n` +
      `{"type":"user","message":{"content":"first message text"}}\n` +
      `{"type":"summary","summary":"A summary"}\n`);
    expect(await resolveClaudeTranscriptTitle(p)).toEqual({ title: "Renamed by user", kind: "generated" });
  });
  test("uses the LAST custom-title when renamed more than once", async () => {
    const d = tmp(); const p = join(d, "t.jsonl");
    writeFileSync(p,
      `{"type":"custom-title","customTitle":"Old name","sessionId":"s1"}\n` +
      `{"type":"user","message":{"content":"hi"}}\n` +
      `{"type":"custom-title","customTitle":"New name","sessionId":"s1"}\n`);
    expect(await resolveClaudeTranscriptTitle(p)).toEqual({ title: "New name", kind: "generated" });
  });
  test("a blank custom-title falls through to the summary", async () => {
    const d = tmp(); const p = join(d, "t.jsonl");
    writeFileSync(p,
      `{"type":"custom-title","customTitle":"   ","sessionId":"s1"}\n` +
      `{"type":"summary","summary":"Real summary"}\n`);
    expect(await resolveClaudeTranscriptTitle(p)).toEqual({ title: "Real summary", kind: "generated" });
  });
  test("prefers the last summary line", async () => {
    const d = tmp(); const p = join(d, "t.jsonl");
    writeFileSync(p,
      `{"type":"user","message":{"content":"first message text"}}\n` +
      `{"type":"summary","summary":"First summary"}\n` +
      `{"type":"summary","summary":"Latest summary"}\n`);
    expect(await resolveClaudeTranscriptTitle(p)).toEqual({ title: "Latest summary", kind: "generated" });
  });
  test("falls back to first user message when no summary", async () => {
    const d = tmp(); const p = join(d, "t.jsonl");
    writeFileSync(p, `{"type":"user","message":{"content":"do the thing"}}\n`);
    expect(await resolveClaudeTranscriptTitle(p)).toEqual({ title: "do the thing", kind: "first-message" });
  });
  test("an empty/blank summary does not suppress the first user message", async () => {
    const d = tmp(); const p = join(d, "t.jsonl");
    writeFileSync(p,
      `{"type":"user","message":{"content":"the real title"}}\n` +
      `{"type":"summary","summary":"   "}\n`);
    expect(await resolveClaudeTranscriptTitle(p)).toEqual({ title: "the real title", kind: "first-message" });
  });
  test("handles array content (first text part)", async () => {
    const d = tmp(); const p = join(d, "t.jsonl");
    writeFileSync(p, `{"type":"user","message":{"content":[{"type":"text","text":"hello there"}]}}\n`);
    expect(await resolveClaudeTranscriptTitle(p)).toEqual({ title: "hello there", kind: "first-message" });
  });
  test("missing file → null", async () => {
    expect(await resolveClaudeTranscriptTitle(join(tmp(), "nope.jsonl"))).toBeNull();
  });
});

describe("resolveStructuredTitle dispatch", () => {
  test("codex via sessionId (desktop session_index)", async () => {
    const home = tmp();
    writeFileSync(join(home, "session_index.jsonl"),
      `{"id":"abc","thread_name":"Codex title","updated_at":"z"}\n`);
    expect(await resolveStructuredTitle("codex", { sessionId: "abc" }, { codexHome: home })).toEqual({ title: "Codex title", kind: "generated" });
  });
  test("codex falls back to the CLI state DB when session_index lacks the thread", async () => {
    const home = tmp();
    writeStateDb(home, 5, [{ id: "abc", title: "From state DB" }]);
    expect(await resolveStructuredTitle("codex", { sessionId: "abc" }, { codexHome: home })).toEqual({ title: "From state DB", kind: "generated" });
  });
  test("codex prefers the desktop session_index over the state DB when both have the thread", async () => {
    const home = tmp();
    writeFileSync(join(home, "session_index.jsonl"),
      `{"id":"abc","thread_name":"Rich desktop title","updated_at":"z"}\n`);
    writeStateDb(home, 5, [{ id: "abc", title: "CLI first-message title" }]);
    expect(await resolveStructuredTitle("codex", { sessionId: "abc" }, { codexHome: home })).toEqual({ title: "Rich desktop title", kind: "generated" });
  });
  test("claude via transcriptPath", async () => {
    const d = tmp(); const p = join(d, "t.jsonl");
    writeFileSync(p, `{"type":"summary","summary":"Claude title"}\n`);
    expect(await resolveStructuredTitle("claude", { sessionId: "x", transcriptPath: p })).toEqual({ title: "Claude title", kind: "generated" });
  });
  test("claude without transcriptPath → null", async () => {
    expect(await resolveStructuredTitle("claude", { sessionId: "x" })).toBeNull();
  });
});
