import { afterEach, describe, expect, test } from "bun:test";
import { Database } from "bun:sqlite";
import { mkdtempSync, rmSync, writeFileSync, mkdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { resolveCodexThreadName, resolveCodexThreadTitle } from "../src/agents/codex/title";
import { resolveClaudeTranscriptTitle } from "../src/agents/claude-code/title";
import {
  parseAntigravityRenames,
  readAntigravitySummaries,
  resolveAntigravityRename,
  resolveAntigravityTranscriptTitle,
} from "../src/agents/antigravity/title";
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
  test("reads Claude's own ai-title (the current spelling of the generated title)", async () => {
    const d = tmp(); const p = join(d, "t.jsonl");
    writeFileSync(p,
      `{"type":"user","message":{"content":"please fix the flaky login test on windows ci"}}\n` +
      `{"type":"ai-title","aiTitle":"Fix flaky Windows login test","sessionId":"s1"}\n`);
    expect(await resolveClaudeTranscriptTitle(p)).toEqual({ title: "Fix flaky Windows login test", kind: "generated" });
  });
  test("uses the LAST ai-title — a title can be revised over a long session", async () => {
    const d = tmp(); const p = join(d, "t.jsonl");
    writeFileSync(p,
      `{"type":"ai-title","aiTitle":"Early guess","sessionId":"s1"}\n` +
      `{"type":"user","message":{"content":"hi"}}\n` +
      `{"type":"ai-title","aiTitle":"Settled topic","sessionId":"s1"}\n`);
    expect(await resolveClaudeTranscriptTitle(p)).toEqual({ title: "Settled topic", kind: "generated" });
  });
  // Precedence is by TYPE, not file position: a renamed conversation restates
  // both records every turn and the ai-title is normally the LATER of the pair,
  // so this fixture uses the order that actually occurs on disk.
  test("a user's custom-title outranks Claude's ai-title even when written first", async () => {
    const d = tmp(); const p = join(d, "t.jsonl");
    writeFileSync(p,
      `{"type":"custom-title","customTitle":"Renamed by user","sessionId":"s1"}\n` +
      `{"type":"ai-title","aiTitle":"Claude's own name","sessionId":"s1"}\n`);
    expect(await resolveClaudeTranscriptTitle(p)).toEqual({ title: "Renamed by user", kind: "generated" });
  });
  test("ai-title outranks a compaction summary", async () => {
    const d = tmp(); const p = join(d, "t.jsonl");
    writeFileSync(p,
      `{"type":"summary","summary":"A summary"}\n` +
      `{"type":"ai-title","aiTitle":"Real title","sessionId":"s1"}\n`);
    expect(await resolveClaudeTranscriptTitle(p)).toEqual({ title: "Real title", kind: "generated" });
  });
  test("a blank ai-title does not suppress the first user message", async () => {
    const d = tmp(); const p = join(d, "t.jsonl");
    writeFileSync(p,
      `{"type":"user","message":{"content":"the real title"}}\n` +
      `{"type":"ai-title","aiTitle":"   ","sessionId":"s1"}\n`);
    expect(await resolveClaudeTranscriptTitle(p)).toEqual({ title: "the real title", kind: "first-message" });
  });
  test("a blank ai-title does not erase a real one seen earlier", async () => {
    const d = tmp(); const p = join(d, "t.jsonl");
    writeFileSync(p,
      `{"type":"ai-title","aiTitle":"Real title","sessionId":"s1"}\n` +
      `{"type":"ai-title","aiTitle":"   ","sessionId":"s1"}\n`);
    expect(await resolveClaudeTranscriptTitle(p)).toEqual({ title: "Real title", kind: "generated" });
  });
  test("missing file → null", async () => {
    expect(await resolveClaudeTranscriptTitle(join(tmp(), "nope.jsonl"))).toBeNull();
  });
});

describe("resolveAntigravityTranscriptTitle", () => {
  test("strips the <USER_REQUEST> wrapper and trailing metadata blocks", async () => {
    const d = tmp(); const p = join(d, "transcript_full.jsonl");
    writeFileSync(p,
      `{"step_index":0,"source":"USER_EXPLICIT","type":"USER_INPUT","content":"<USER_REQUEST>\\nsay hi in one word\\n</USER_REQUEST>\\n<ADDITIONAL_METADATA>\\nirrelevant\\n</ADDITIONAL_METADATA>"}\n` +
      `{"step_index":2,"source":"MODEL","type":"PLANNER_RESPONSE","content":"Hello"}\n`);
    expect(await resolveAntigravityTranscriptTitle(p)).toBe("say hi in one word");
  });
  test("falls back to the raw content when there's no <USER_REQUEST> wrapper", async () => {
    const d = tmp(); const p = join(d, "transcript_full.jsonl");
    writeFileSync(p, `{"type":"USER_INPUT","content":"plain unwrapped text"}\n`);
    expect(await resolveAntigravityTranscriptTitle(p)).toBe("plain unwrapped text");
  });
  test("uses the FIRST USER_INPUT line", async () => {
    const d = tmp(); const p = join(d, "transcript_full.jsonl");
    writeFileSync(p,
      `{"type":"USER_INPUT","content":"first turn"}\n` +
      `{"type":"USER_INPUT","content":"second turn"}\n`);
    expect(await resolveAntigravityTranscriptTitle(p)).toBe("first turn");
  });
  test("missing file → null", async () => {
    expect(await resolveAntigravityTranscriptTitle(join(tmp(), "nope.jsonl"))).toBeNull();
  });
  test("garbage lines are skipped, not thrown", async () => {
    const d = tmp(); const p = join(d, "transcript_full.jsonl");
    writeFileSync(p, `not json\n{"type":"USER_INPUT","content":"real title"}\n{partial`);
    expect(await resolveAntigravityTranscriptTitle(p)).toBe("real title");
  });
});

/** Mirror the shape agy's conversation_summaries.db exposes (subset of columns
 *  we read): manual `title` and generated `preview` per conversation. */
function writeSummariesDb(
  home: string,
  rows: Array<{ id: string; title?: string; preview?: string }>,
) {
  const db = new Database(join(home, "conversation_summaries.db"));
  db.run("CREATE TABLE conversation_summaries (conversation_id TEXT PRIMARY KEY, title TEXT, preview TEXT)");
  const stmt = db.query("INSERT INTO conversation_summaries (conversation_id, title, preview) VALUES (?, ?, ?)");
  for (const r of rows) stmt.run(r.id, r.title ?? "", r.preview ?? "");
  db.close();
}

describe("readAntigravitySummaries", () => {
  test("maps a conversation to its generated preview", () => {
    const home = tmp();
    writeSummariesDb(home, [{ id: "c1", title: "", preview: "Casual Greeting And Introduction" }]);
    expect(readAntigravitySummaries(home).get("c1")).toBe("Casual Greeting And Introduction");
  });
  test("prefers the manual title over the generated preview", () => {
    const home = tmp();
    writeSummariesDb(home, [{ id: "c1", title: "renamed", preview: "generated name" }]);
    expect(readAntigravitySummaries(home).get("c1")).toBe("renamed");
  });
  test("omits a conversation with neither title nor preview", () => {
    const home = tmp();
    writeSummariesDb(home, [{ id: "c1", title: "", preview: "" }]);
    expect(readAntigravitySummaries(home).has("c1")).toBe(false);
  });
  test("missing db → empty map, no throw", () => {
    expect(readAntigravitySummaries(tmp()).size).toBe(0);
  });
});

describe("parseAntigravityRenames", () => {
  test("keeps the latest /rename per conversationId", () => {
    const raw =
      `{"display":"/rename first","conversationId":"c1","type":"slash_command"}\n` +
      `{"display":"/rename second","conversationId":"c1","type":"slash_command"}\n` +
      `{"display":"/rename other","conversationId":"c2","type":"slash_command"}\n`;
    const m = parseAntigravityRenames(raw);
    expect(m.get("c1")).toBe("second");
    expect(m.get("c2")).toBe("other");
  });
  test("ignores a bare /rename (no argument)", () => {
    const raw = `{"display":"/rename","conversationId":"c1","type":"slash_command"}\n`;
    expect(parseAntigravityRenames(raw).has("c1")).toBe(false);
  });
  test("a bare /rename after a named one does not clear the name", () => {
    const raw =
      `{"display":"/rename keep me","conversationId":"c1","type":"slash_command"}\n` +
      `{"display":"/rename","conversationId":"c1","type":"slash_command"}\n`;
    expect(parseAntigravityRenames(raw).get("c1")).toBe("keep me");
  });
  test("ignores non-slash_command lines and other slash commands", () => {
    const raw =
      `{"display":"hi","conversationId":"c1"}\n` +
      `{"display":"/logout","conversationId":"c1","type":"slash_command"}\n`;
    expect(parseAntigravityRenames(raw).has("c1")).toBe(false);
  });
  test("skips garbage lines without throwing", () => {
    const raw =
      `not json\n` +
      `{"display":"/rename good","conversationId":"c1","type":"slash_command"}\n` +
      `{partial`;
    expect(parseAntigravityRenames(raw).get("c1")).toBe("good");
  });
});

describe("resolveAntigravityRename", () => {
  test("returns the latest rename for the conversation from history.jsonl", async () => {
    const home = tmp();
    writeFileSync(join(home, "history.jsonl"),
      `{"display":"/rename old","conversationId":"c1","type":"slash_command"}\n` +
      `{"display":"/rename new","conversationId":"c1","type":"slash_command"}\n`);
    expect(await resolveAntigravityRename("c1", home)).toBe("new");
  });
  test("null when the conversation was never renamed", async () => {
    const home = tmp();
    writeFileSync(join(home, "history.jsonl"),
      `{"display":"/rename x","conversationId":"other","type":"slash_command"}\n`);
    expect(await resolveAntigravityRename("c1", home)).toBeNull();
  });
  test("null when history.jsonl is missing", async () => {
    expect(await resolveAntigravityRename("c1", tmp())).toBeNull();
  });
});

describe("resolveStructuredTitle dispatch", () => {
  test("antigravity prefers a live /rename over the first user message", async () => {
    const home = tmp();
    const p = join(home, "transcript_full.jsonl");
    writeFileSync(p, `{"type":"USER_INPUT","content":"first turn"}\n`);
    writeFileSync(join(home, "history.jsonl"),
      `{"display":"/rename my chat","conversationId":"c1","type":"slash_command"}\n`);
    expect(
      await resolveStructuredTitle("antigravity", { sessionId: "c1", transcriptPath: p }, { antigravityHome: home }),
    ).toEqual({ title: "my chat", kind: "generated" });
  });
  test("antigravity prefers agy's generated preview over the first user message", async () => {
    const home = tmp();
    const p = join(home, "transcript_full.jsonl");
    writeFileSync(p, `{"type":"USER_INPUT","content":"hii"}\n`);
    writeSummariesDb(home, [{ id: "c1", preview: "Casual Greeting And Introduction" }]);
    expect(
      await resolveStructuredTitle("antigravity", { sessionId: "c1", transcriptPath: p }, { antigravityHome: home }),
    ).toEqual({ title: "Casual Greeting And Introduction", kind: "generated" });
  });
  test("antigravity prefers a live /rename over agy's generated preview", async () => {
    const home = tmp();
    const p = join(home, "transcript_full.jsonl");
    writeFileSync(p, `{"type":"USER_INPUT","content":"hii"}\n`);
    writeSummariesDb(home, [{ id: "c1", preview: "Casual Greeting And Introduction" }]);
    writeFileSync(join(home, "history.jsonl"),
      `{"display":"/rename my chat","conversationId":"c1","type":"slash_command"}\n`);
    expect(
      await resolveStructuredTitle("antigravity", { sessionId: "c1", transcriptPath: p }, { antigravityHome: home }),
    ).toEqual({ title: "my chat", kind: "generated" });
  });
  test("antigravity falls back to the first user message with no rename or preview", async () => {
    const home = tmp();
    const p = join(home, "transcript_full.jsonl");
    writeFileSync(p, `{"type":"USER_INPUT","content":"first turn"}\n`);
    expect(
      await resolveStructuredTitle("antigravity", { sessionId: "c1", transcriptPath: p }, { antigravityHome: home }),
    ).toEqual({ title: "first turn", kind: "first-message" });
  });
  test("antigravity ignores a rename that belongs to a different conversation", async () => {
    const home = tmp();
    const p = join(home, "transcript_full.jsonl");
    writeFileSync(p, `{"type":"USER_INPUT","content":"first turn"}\n`);
    writeFileSync(join(home, "history.jsonl"),
      `{"display":"/rename someone else","conversationId":"c2","type":"slash_command"}\n`);
    expect(
      await resolveStructuredTitle("antigravity", { sessionId: "c1", transcriptPath: p }, { antigravityHome: home }),
    ).toEqual({ title: "first turn", kind: "first-message" });
  });


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
  test("antigravity via transcriptPath", async () => {
    const d = tmp(); const p = join(d, "transcript_full.jsonl");
    writeFileSync(p, `{"type":"USER_INPUT","content":"Antigravity title"}\n`);
    expect(
      await resolveStructuredTitle("antigravity", { sessionId: "x", transcriptPath: p }),
    ).toEqual({ title: "Antigravity title", kind: "first-message" });
  });
  test("antigravity without transcriptPath → null", async () => {
    expect(await resolveStructuredTitle("antigravity", { sessionId: "x" })).toBeNull();
  });
});
