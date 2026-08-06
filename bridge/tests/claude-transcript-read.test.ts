import { describe, it, expect, beforeEach, afterEach } from "bun:test";
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { claudeProjectSlug, readClaudeTranscript } from "../src/agents/claude-code/transcript-read";

// The reader targets ~/.claude/projects/<cwd-slug>/<session-id>.jsonl; tests
// point `root` at a temp dir so nothing touches the real home directory.
describe("claudeProjectSlug", () => {
  it("replaces every non-alphanumeric char with '-' (no dedup of runs)", () => {
    // C:\ -> C-- (colon AND backslash each map to a dash) — verified against
    // the real binary's on-disk layout.
    expect(claudeProjectSlug("C:\\Users\\bhara\\GitHub\\tide")).toBe("C--Users-bhara-GitHub-tide");
    expect(claudeProjectSlug("/home/x/proj")).toBe("-home-x-proj");
  });
});

describe("readClaudeTranscript", () => {
  let root: string;
  const cwd = "/home/x/proj";
  const slug = claudeProjectSlug(cwd);

  function seed(sessionId: string, lines: unknown[], dir = slug) {
    const projDir = join(root, dir);
    mkdirSync(projDir, { recursive: true });
    writeFileSync(join(projDir, `${sessionId}.jsonl`), lines.map((l) => JSON.stringify(l)).join("\n"), "utf8");
  }

  beforeEach(() => { root = mkdtempSync(join(tmpdir(), "ab-claude-transcript-")); });
  afterEach(() => { rmSync(root, { recursive: true, force: true }); });

  it("returns [] when the file does not exist", async () => {
    expect(await readClaudeTranscript(cwd, "missing", root)).toEqual([]);
  });

  it("reads user + assistant entries in order", async () => {
    seed("s1", [
      { type: "user", message: { role: "user", content: "hi" }, uuid: "u1" },
      { type: "assistant", message: { role: "assistant", content: [{ type: "text", text: "hello" }] }, uuid: "a1" },
    ]);
    const out = await readClaudeTranscript(cwd, "s1", root);
    expect(out.map((e) => e.type)).toEqual(["user", "assistant"]);
    expect(out[0].message.content).toBe("hi");
  });

  it("filters out sidechain, meta, and non-message rows", async () => {
    seed("s1", [
      { type: "queue-operation", operation: "add" },
      { type: "user", message: { role: "user", content: "main" }, uuid: "u1" },
      { type: "assistant", message: { role: "assistant", content: [{ type: "text", text: "sub" }] }, uuid: "a1", isSidechain: true },
      { type: "user", message: { role: "user", content: "meta" }, uuid: "u2", isMeta: true },
      { type: "attachment", data: {} },
    ]);
    const out = await readClaudeTranscript(cwd, "s1", root);
    expect(out).toHaveLength(1);
    expect(out[0].message.content).toBe("main");
  });

  it("drops local-command wrapper entries but keeps the surrounding conversation", async () => {
    // Claude Code writes a slash command's echo and output as string-content
    // user entries (verified on a real transcript). They carry no isMeta, so
    // without this filter each one reads as a user prompt.
    seed("s1", [
      { type: "user", message: { role: "user", content: "real prompt" }, uuid: "u1" },
      { type: "user", uuid: "u2", message: { role: "user", content:
        "<command-name>/model</command-name>\n            <command-message>model</command-message>\n            <command-args>opus[1m]</command-args>" } },
      { type: "user", uuid: "u3", message: { role: "user", content:
        "<local-command-stdout>Set model to opus[1m] (claude-opus-4-8[1m])</local-command-stdout>" } },
      { type: "assistant", message: { role: "assistant", content: [{ type: "text", text: "answer" }] }, uuid: "a1" },
    ]);
    const out = await readClaudeTranscript(cwd, "s1", root);
    expect(out.map((e) => e.uuid)).toEqual(["u1", "a1"]);
  });

  it("keeps a real prompt that merely mentions a command tag", async () => {
    // Only content that is ENTIRELY command wrappers is dropped — a prompt
    // quoting one is still the user talking.
    seed("s1", [
      { type: "user", uuid: "u1", message: { role: "user", content: "why does <command-name>/model</command-name> show up in my transcript?" } },
    ]);
    const out = await readClaudeTranscript(cwd, "s1", root);
    expect(out).toHaveLength(1);
  });

  it("handles an unterminated wrapper in a long entry without stalling", async () => {
    // Guards the filter against catastrophic backtracking: many well-formed
    // wrappers followed by an unclosed one is the pathological shape.
    const content = "<command-args>x</command-args>".repeat(400) + "<command-name>" + "a".repeat(20000);
    seed("s1", [{ type: "user", uuid: "u1", message: { role: "user", content } }]);
    const started = Date.now();
    const out = await readClaudeTranscript(cwd, "s1", root);
    expect(Date.now() - started).toBeLessThan(1000);
    expect(out).toHaveLength(1); // not entirely wrappers -> kept
  });

  it("skips malformed JSON and blank lines without throwing", async () => {
    const projDir = join(root, slug);
    mkdirSync(projDir, { recursive: true });
    writeFileSync(
      join(projDir, "s1.jsonl"),
      ['{"type":"user","message":{"role":"user","content":"ok"}}', "", "{ not json", "   "].join("\n"),
      "utf8",
    );
    const out = await readClaudeTranscript(cwd, "s1", root);
    expect(out).toHaveLength(1);
    expect(out[0].message.content).toBe("ok");
  });

  it("falls back to scanning project dirs when the cwd slug does not match", async () => {
    // File lives under a DIFFERENT project dir than cwd's slug (e.g. Claude
    // recorded a symlinked/case-different cwd). The unique session id still
    // locates it.
    seed("s9", [{ type: "user", message: { role: "user", content: "found" }, uuid: "u1" }], "some-other-slug");
    const out = await readClaudeTranscript(cwd, "s9", root);
    expect(out).toHaveLength(1);
    expect(out[0].message.content).toBe("found");
  });

  it("caps to the most recent entries", async () => {
    const many = Array.from({ length: 600 }, (_, i) => ({
      type: "user", message: { role: "user", content: `m${i}` }, uuid: `u${i}`,
    }));
    seed("s1", many);
    const out = await readClaudeTranscript(cwd, "s1", root);
    expect(out).toHaveLength(500);
    // Oldest dropped, newest kept.
    expect(out[0].message.content).toBe("m100");
    expect(out[out.length - 1].message.content).toBe("m599");
  });
});
