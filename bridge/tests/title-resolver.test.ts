import { afterEach, describe, expect, test } from "bun:test";
import { Database } from "bun:sqlite";
import { mkdtempSync, rmSync, writeFileSync, mkdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  resolveCodexThreadName,
  resolveCodexThreadTitle,
  resolveClaudeTranscriptTitle,
  resolveStructuredTitle,
} from "../src/title-resolver";

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
    expect(await resolveCodexThreadName("t1", home)).toBe("New title");
  });
  test("missing file → null", async () => {
    expect(await resolveCodexThreadName("t1", tmp())).toBeNull();
  });
  test("garbage lines are skipped, not thrown", async () => {
    const home = tmp();
    writeFileSync(join(home, "session_index.jsonl"),
      `not json\n{"id":"t1","thread_name":"Good","updated_at":"z"}\n{partial`);
    expect(await resolveCodexThreadName("t1", home)).toBe("Good");
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
    expect(await resolveCodexThreadTitle("t1", home)).toBe("My title");
  });
  test("falls back to first_user_message when title is blank", async () => {
    const home = tmp();
    writeStateDb(home, 5, [{ id: "t1", title: "   ", first_user_message: "first message" }]);
    expect(await resolveCodexThreadTitle("t1", home)).toBe("first message");
  });
  test("picks the newest state_<N>.sqlite", async () => {
    const home = tmp();
    writeStateDb(home, 4, [{ id: "t1", title: "old schema" }]);
    writeStateDb(home, 12, [{ id: "t1", title: "new schema" }]);
    expect(await resolveCodexThreadTitle("t1", home)).toBe("new schema");
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
    expect(await resolveClaudeTranscriptTitle(p)).toBe("Renamed by user");
  });
  test("uses the LAST custom-title when renamed more than once", async () => {
    const d = tmp(); const p = join(d, "t.jsonl");
    writeFileSync(p,
      `{"type":"custom-title","customTitle":"Old name","sessionId":"s1"}\n` +
      `{"type":"user","message":{"content":"hi"}}\n` +
      `{"type":"custom-title","customTitle":"New name","sessionId":"s1"}\n`);
    expect(await resolveClaudeTranscriptTitle(p)).toBe("New name");
  });
  test("a blank custom-title falls through to the summary", async () => {
    const d = tmp(); const p = join(d, "t.jsonl");
    writeFileSync(p,
      `{"type":"custom-title","customTitle":"   ","sessionId":"s1"}\n` +
      `{"type":"summary","summary":"Real summary"}\n`);
    expect(await resolveClaudeTranscriptTitle(p)).toBe("Real summary");
  });
  test("prefers the last summary line", async () => {
    const d = tmp(); const p = join(d, "t.jsonl");
    writeFileSync(p,
      `{"type":"user","message":{"content":"first message text"}}\n` +
      `{"type":"summary","summary":"First summary"}\n` +
      `{"type":"summary","summary":"Latest summary"}\n`);
    expect(await resolveClaudeTranscriptTitle(p)).toBe("Latest summary");
  });
  test("falls back to first user message when no summary", async () => {
    const d = tmp(); const p = join(d, "t.jsonl");
    writeFileSync(p, `{"type":"user","message":{"content":"do the thing"}}\n`);
    expect(await resolveClaudeTranscriptTitle(p)).toBe("do the thing");
  });
  test("an empty/blank summary does not suppress the first user message", async () => {
    const d = tmp(); const p = join(d, "t.jsonl");
    writeFileSync(p,
      `{"type":"user","message":{"content":"the real title"}}\n` +
      `{"type":"summary","summary":"   "}\n`);
    expect(await resolveClaudeTranscriptTitle(p)).toBe("the real title");
  });
  test("handles array content (first text part)", async () => {
    const d = tmp(); const p = join(d, "t.jsonl");
    writeFileSync(p, `{"type":"user","message":{"content":[{"type":"text","text":"hello there"}]}}\n`);
    expect(await resolveClaudeTranscriptTitle(p)).toBe("hello there");
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
    expect(await resolveStructuredTitle("codex", { sessionId: "abc" }, { codexHome: home })).toBe("Codex title");
  });
  test("codex falls back to the CLI state DB when session_index lacks the thread", async () => {
    const home = tmp();
    writeStateDb(home, 5, [{ id: "abc", title: "From state DB" }]);
    expect(await resolveStructuredTitle("codex", { sessionId: "abc" }, { codexHome: home })).toBe("From state DB");
  });
  test("codex prefers the desktop session_index over the state DB when both have the thread", async () => {
    const home = tmp();
    writeFileSync(join(home, "session_index.jsonl"),
      `{"id":"abc","thread_name":"Rich desktop title","updated_at":"z"}\n`);
    writeStateDb(home, 5, [{ id: "abc", title: "CLI first-message title" }]);
    expect(await resolveStructuredTitle("codex", { sessionId: "abc" }, { codexHome: home })).toBe("Rich desktop title");
  });
  test("claude via transcriptPath", async () => {
    const d = tmp(); const p = join(d, "t.jsonl");
    writeFileSync(p, `{"type":"summary","summary":"Claude title"}\n`);
    expect(await resolveStructuredTitle("claude", { sessionId: "x", transcriptPath: p })).toBe("Claude title");
  });
  test("claude without transcriptPath → null", async () => {
    expect(await resolveStructuredTitle("claude", { sessionId: "x" })).toBeNull();
  });
});
