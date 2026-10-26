import { afterEach, describe, expect, test } from "bun:test";
import { Database } from "bun:sqlite";
import { mkdtempSync, rmSync, writeFileSync, mkdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { resolveCodexThreadTitle } from "../../packages/antgrid-agents/src/agents/codex/title";
import { resolveClaudeTranscriptTitle } from "../../packages/antgrid-agents/src/agents/claude-code/title";
import {
  parseAntigravityRenames,
  resolveAntigravityRename,
  resolveAntigravityTranscriptTitle,
} from "../../packages/antgrid-agents/src/agents/antigravity/title";
import { resolveStructuredTitle } from "../../packages/antgrid-agents/src/agents/title-dispatch";
import { handoffPrompt } from "../src/handoff/handoff-prompt";

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
  // Records in the shape Claude Code 2.1.2xx-2.1.3xx writes ahead of, or in
  // place of, the user's own first prompt. None of them is the user talking.
  const caveat = `{"type":"user","isMeta":true,"message":{"role":"user","content":"<local-command-caveat>Caveat: The messages below were generated by the user while running local commands. DO NOT respond to these messages or otherwise consider them in your response unless the user explicitly asks you to.</local-command-caveat>"}}\n`;
  const localCommand =
    `{"type":"user","message":{"role":"user","content":"<command-name>/model</command-name>\\n            <command-message>model</command-message>\\n            <command-args></command-args>"}}\n` +
    `{"type":"user","message":{"role":"user","content":"<local-command-stdout>Set model to example-model</local-command-stdout>"}}\n`;
  test("skips a slash-command preamble to the first typed prompt", async () => {
    const d = tmp(); const p = join(d, "t.jsonl");
    writeFileSync(p, caveat + localCommand +
      `{"type":"user","message":{"role":"user","content":"rename the widget factory"}}\n`);
    expect(await resolveClaudeTranscriptTitle(p)).toEqual({ title: "rename the widget factory", kind: "first-message" });
  });
  // A prompt command with arguments echoes itself and then injects its
  // expanded body as an isMeta record; neither is a title. The session is
  // named by the next prompt typed after it, or not at all until one exists.
  test("a session opened by a prompt command with args takes the next typed prompt", async () => {
    const d = tmp(); const p = join(d, "t.jsonl");
    const command =
      `{"type":"user","message":{"role":"user","content":"<command-message>review</command-message>\\n<command-name>/review</command-name>\\n<command-args>src/widget.ts</command-args>"}}\n` +
      `{"type":"user","isMeta":true,"message":{"role":"user","content":[{"type":"text","text":"Review the file named in the arguments for bugs."}]}}\n`;
    writeFileSync(p, command);
    expect(await resolveClaudeTranscriptTitle(p)).toBeNull();
    writeFileSync(p, command +
      `{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_example","content":"ok"}]}}\n` +
      `{"type":"user","message":{"role":"user","content":"now fix what you found"}}\n`);
    expect(await resolveClaudeTranscriptTitle(p)).toEqual({ title: "now fix what you found", kind: "first-message" });
  });
  test("skips an injected inter-session message", async () => {
    const d = tmp(); const p = join(d, "t.jsonl");
    writeFileSync(p,
      `{"type":"user","isMeta":true,"message":{"role":"user","content":"Another Claude session sent a message: please check the build"}}\n` +
      `{"type":"user","message":{"role":"user","content":"tidy up the parser"}}\n`);
    expect(await resolveClaudeTranscriptTitle(p)).toEqual({ title: "tidy up the parser", kind: "first-message" });
  });
  test("skips the compact summary a continued session starts from", async () => {
    const d = tmp(); const p = join(d, "t.jsonl");
    writeFileSync(p,
      `{"type":"user","isCompactSummary":true,"isVisibleInTranscriptOnly":true,"message":{"role":"user","content":"This session is being continued from a previous conversation that ran out of context. Summary: example."}}\n` +
      `{"type":"user","message":{"role":"user","content":"carry on with the migration"}}\n`);
    expect(await resolveClaudeTranscriptTitle(p)).toEqual({ title: "carry on with the migration", kind: "first-message" });
  });
  test("a prompt that merely quotes a command wrapper is still a title", async () => {
    const d = tmp(); const p = join(d, "t.jsonl");
    writeFileSync(p,
      `{"type":"user","message":{"role":"user","content":"<command-name>/model</command-name> prints nothing, why?"}}\n`);
    expect(await resolveClaudeTranscriptTitle(p))
      .toEqual({ title: "<command-name>/model</command-name> prints nothing, why?", kind: "first-message" });
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

describe("resolveStructuredTitle on a handoff target", () => {
  // Built by the real template, so rewording it past the classifier fails here
  // rather than naming every handoff in the field after the handoff.
  const prompt = (extra?: string) => handoffPrompt({
    sourceLabel: "Codex",
    excerptPath: "C:\\repo\\.antgrid\\handoff\\h1\\excerpt.md",
    rawPath: "C:\\repo\\.antgrid\\handoff\\h1\\rollout.jsonl",
    ...(extra ? { extra } : {}),
  });
  const claudeTranscript = (...lines: object[]) => {
    const p = join(tmp(), "t.jsonl");
    writeFileSync(p, lines.map((line) => `${JSON.stringify(line)}\n`).join(""));
    return p;
  };

  test("the handoff prompt names nothing, so the row keeps its fork name", async () => {
    const p = claudeTranscript({ type: "user", message: { content: prompt() } });
    expect(await resolveStructuredTitle("claude", { sessionId: "x", transcriptPath: p })).toBeNull();
  });
  test("an instruction the user added to the handoff is the first message", async () => {
    const p = claudeTranscript({ type: "user", message: { content: prompt("migrate the schema") } });
    expect(await resolveStructuredTitle("claude", { sessionId: "x", transcriptPath: p }))
      .toEqual({ title: "migrate the schema", kind: "first-message" });
  });
  test("is dropped for every agent's resolver, not only Claude's", async () => {
    const home = tmp();
    writeStateDb(home, 5, [{ id: "abc", first_user_message: prompt() }]);
    expect(await resolveStructuredTitle("codex", { sessionId: "abc" }, { codexHome: home })).toBeNull();
  });
  test("a rename still wins", async () => {
    const p = claudeTranscript(
      { type: "user", message: { content: prompt() } },
      { type: "custom-title", customTitle: "Schema work", sessionId: "x" },
    );
    expect(await resolveStructuredTitle("claude", { sessionId: "x", transcriptPath: p }))
      .toEqual({ title: "Schema work", kind: "manual" });
  });
});
