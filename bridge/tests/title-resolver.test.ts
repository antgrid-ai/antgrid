import { afterEach, describe, expect, test } from "bun:test";
import { Database } from "bun:sqlite";
import { mkdtempSync, rmSync, writeFileSync, mkdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { resolveCodexThreadTitle } from "../src/agents/codex/title";
import { resolveClaudeTranscriptTitle } from "../src/agents/claude-code/title";
import {
  parseAntigravityRenames,
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

describe("resolveCodexThreadTitle", () => {
  // A divergent `title` is the Codex DESKTOP app naming the thread for itself.
  // We name sessions ourselves, so first_user_message is the column that counts.
  test("ignores a desktop-written title and reads first_user_message", async () => {
    const home = tmp();
    writeStateDb(home, 5, [{ id: "t1", title: "My title", first_user_message: "do the thing" }]);
    expect(await resolveCodexThreadTitle("t1", home)).toEqual({ title: "do the thing", kind: "first-message" });
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
    writeStateDb(home, 4, [{ id: "t1", first_user_message: "old schema" }]);
    writeStateDb(home, 12, [{ id: "t1", first_user_message: "new schema" }]);
    expect(await resolveCodexThreadTitle("t1", home)).toEqual({ title: "new schema", kind: "first-message" });
  });
  test("missing DB → null", async () => {
    expect(await resolveCodexThreadTitle("t1", tmp())).toBeNull();
  });
  test("unknown id → null", async () => {
    const home = tmp();
    writeStateDb(home, 5, [{ id: "t1", first_user_message: "x" }]);
    expect(await resolveCodexThreadTitle("nope", home)).toBeNull();
  });
});

describe("resolveClaudeTranscriptTitle", () => {
  test("reports the manual /rename custom-title, outranking the user message", async () => {
    const d = tmp(); const p = join(d, "t.jsonl");
    writeFileSync(p,
      `{"type":"custom-title","customTitle":"Renamed by user","sessionId":"s1"}\n` +
      `{"type":"user","message":{"content":"first message text"}}\n`);
    expect(await resolveClaudeTranscriptTitle(p)).toEqual({ title: "Renamed by user", kind: "manual" });
  });
  test("uses the LAST custom-title when renamed more than once", async () => {
    const d = tmp(); const p = join(d, "t.jsonl");
    writeFileSync(p,
      `{"type":"custom-title","customTitle":"Old name","sessionId":"s1"}\n` +
      `{"type":"user","message":{"content":"hi"}}\n` +
      `{"type":"custom-title","customTitle":"New name","sessionId":"s1"}\n`);
    expect(await resolveClaudeTranscriptTitle(p)).toEqual({ title: "New name", kind: "manual" });
  });
  test("a blank custom-title falls through to the first user message", async () => {
    const d = tmp(); const p = join(d, "t.jsonl");
    writeFileSync(p,
      `{"type":"custom-title","customTitle":"   ","sessionId":"s1"}\n` +
      `{"type":"user","message":{"content":"the real content"}}\n`);
    expect(await resolveClaudeTranscriptTitle(p)).toEqual({ title: "the real content", kind: "first-message" });
  });
  test("falls back to the first user message", async () => {
    const d = tmp(); const p = join(d, "t.jsonl");
    writeFileSync(p, `{"type":"user","message":{"content":"do the thing"}}\n`);
    expect(await resolveClaudeTranscriptTitle(p)).toEqual({ title: "do the thing", kind: "first-message" });
  });
  test("handles array content (first text part)", async () => {
    const d = tmp(); const p = join(d, "t.jsonl");
    writeFileSync(p, `{"type":"user","message":{"content":[{"type":"text","text":"hello there"}]}}\n`);
    expect(await resolveClaudeTranscriptTitle(p)).toEqual({ title: "hello there", kind: "first-message" });
  });
  // Claude's OWN name for the conversation. Both spellings are deliberately not
  // read — we generate our own rather than depend on whether Claude wrote one,
  // which it does in the interactive TUI and never in a headless/SDK run.
  test("ignores Claude's ai-title", async () => {
    const d = tmp(); const p = join(d, "t.jsonl");
    writeFileSync(p,
      `{"type":"user","message":{"content":"please fix the flaky login test on windows ci"}}\n` +
      `{"type":"ai-title","aiTitle":"Fix flaky Windows login test","sessionId":"s1"}\n`);
    expect(await resolveClaudeTranscriptTitle(p))
      .toEqual({ title: "please fix the flaky login test on windows ci", kind: "first-message" });
  });
  test("ignores a compaction summary", async () => {
    const d = tmp(); const p = join(d, "t.jsonl");
    writeFileSync(p,
      `{"type":"user","message":{"content":"do the thing"}}\n` +
      `{"type":"summary","summary":"A summary"}\n`);
    expect(await resolveClaudeTranscriptTitle(p)).toEqual({ title: "do the thing", kind: "first-message" });
  });
  // The two records coexist — a renamed conversation restates both every turn,
  // with the ai-title normally the LATER of the pair — so dropping ai-title must
  // not take the rename with it.
  test("a rename still resolves when Claude's own title follows it", async () => {
    const d = tmp(); const p = join(d, "t.jsonl");
    writeFileSync(p,
      `{"type":"custom-title","customTitle":"Renamed by user","sessionId":"s1"}\n` +
      `{"type":"ai-title","aiTitle":"Claude's own name","sessionId":"s1"}\n`);
    expect(await resolveClaudeTranscriptTitle(p)).toEqual({ title: "Renamed by user", kind: "manual" });
  });
  test("an ai-title alone leaves the session unresolved rather than named", async () => {
    const d = tmp(); const p = join(d, "t.jsonl");
    writeFileSync(p, `{"type":"ai-title","aiTitle":"Claude's own name","sessionId":"s1"}\n`);
    expect(await resolveClaudeTranscriptTitle(p)).toBeNull();
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
    ).toEqual({ title: "my chat", kind: "manual" });
  });
  test("antigravity falls back to the first user message with no rename", async () => {
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


  test("codex via sessionId reads the CLI state DB", async () => {
    const home = tmp();
    writeStateDb(home, 5, [{ id: "abc", first_user_message: "From state DB" }]);
    expect(await resolveStructuredTitle("codex", { sessionId: "abc" }, { codexHome: home }))
      .toEqual({ title: "From state DB", kind: "first-message" });
  });
  // session_index.jsonl is written only by the Codex DESKTOP app, and every
  // name in it is one that app generated — so it is not consulted at all now.
  test("codex ignores the desktop session_index", async () => {
    const home = tmp();
    writeFileSync(join(home, "session_index.jsonl"),
      `{"id":"abc","thread_name":"Rich desktop title","updated_at":"z"}\n`);
    writeStateDb(home, 5, [{ id: "abc", first_user_message: "what the user asked" }]);
    expect(await resolveStructuredTitle("codex", { sessionId: "abc" }, { codexHome: home }))
      .toEqual({ title: "what the user asked", kind: "first-message" });
  });
  test("claude via transcriptPath", async () => {
    const d = tmp(); const p = join(d, "t.jsonl");
    writeFileSync(p, `{"type":"custom-title","customTitle":"Claude title","sessionId":"x"}\n`);
    expect(await resolveStructuredTitle("claude", { sessionId: "x", transcriptPath: p })).toEqual({ title: "Claude title", kind: "manual" });
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
