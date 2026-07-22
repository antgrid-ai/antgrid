import { afterEach, describe, expect, test } from "bun:test";
import { Database } from "bun:sqlite";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { resumeArgv, sessionResumable } from "../src/agent-resume";

const dirs: string[] = [];
function newDir() { const d = mkdtempSync(join(tmpdir(), "ab-resume-")); dirs.push(d); return d; }
afterEach(() => { for (const d of dirs.splice(0)) try { rmSync(d, { recursive: true, force: true }); } catch {} });

function seedCopilotSessions(home: string, ids: string[]) {
  const db = new Database(join(home, "session-store.db"));
  db.run("CREATE TABLE sessions (id TEXT PRIMARY KEY)");
  const insert = db.query("INSERT INTO sessions (id) VALUES (?)");
  for (const id of ids) insert.run(id);
  db.close();
}

describe("resumeArgv", () => {
  test("claude/gemini/qwen use --resume <id>", () => {
    expect(resumeArgv("claude-code", "abc")).toEqual(["--resume", "abc"]);
    expect(resumeArgv("gemini", "abc")).toEqual(["--resume", "abc"]);
    expect(resumeArgv("qwen", "abc")).toEqual(["--resume", "abc"]);
  });
  test("opencode uses --session <id>", () => {
    expect(resumeArgv("opencode", "ses_1")).toEqual(["--session", "ses_1"]);
  });
  test("codex uses the resume subcommand", () => {
    expect(resumeArgv("codex", "uuid-1")).toEqual(["resume", "uuid-1"]);
  });
  test("github-copilot uses equals-attached resume argument", () => {
    expect(resumeArgv("github-copilot", "uuid-c")).toEqual(["--resume=uuid-c"]);
  });
  test("cursor-agent uses --resume <id>", () => {
    expect(resumeArgv("cursor-agent", "uuid-cu")).toEqual(["--resume", "uuid-cu"]);
  });
  test("unknown / unsupported tool yields no resume args", () => {
    expect(resumeArgv("nope", "x")).toEqual([]);
  });
});

describe("sessionResumable", () => {
  test("transcript path that exists → resumable", () => {
    const d = newDir();
    const p = join(d, "t.jsonl");
    writeFileSync(p, "{}");
    expect(sessionResumable({ tool: "claude-code", agentSessionId: "x", agentTranscriptPath: p })).toBe(true);
  });
  test("transcript path that is gone → not resumable", () => {
    expect(sessionResumable({ tool: "claude-code", agentSessionId: "x", agentTranscriptPath: "/no/such.jsonl" })).toBe(false);
  });
  test("no transcript path and non-codex tool → optimistic true", () => {
    expect(sessionResumable({ tool: "opencode", agentSessionId: "ses_1" })).toBe(true);
  });
  test("codex with a non-existent codexHome → optimistic true (undeterminable)", () => {
    expect(sessionResumable({ tool: "codex", agentSessionId: "u", codexHome: "/no/such/dir" })).toBe(true);
  });
  test("github-copilot returns true for an existing session id", () => {
    const copilotHome = newDir();
    seedCopilotSessions(copilotHome, ["uuid-c"]);

    expect(sessionResumable({ tool: "github-copilot", agentSessionId: "uuid-c", copilotHome })).toBe(true);
  });
  test("github-copilot returns false for a missing session id", () => {
    const copilotHome = newDir();
    seedCopilotSessions(copilotHome, ["uuid-c"]);

    expect(sessionResumable({ tool: "github-copilot", agentSessionId: "missing", copilotHome })).toBe(false);
  });
  test("github-copilot returns optimistic true when home cannot be queried", () => {
    expect(
      sessionResumable({
        tool: "github-copilot",
        agentSessionId: "uuid-c",
        copilotHome: join(newDir(), "no-such-home"),
      }),
    ).toBe(true);
  });
});
