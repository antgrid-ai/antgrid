import { afterEach, describe, expect, test } from "bun:test";
import { Database } from "bun:sqlite";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { agentSessionGone, resumeArgv, sessionResumable } from "../src/agent-resume";

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
  test("claude uses --resume <id>", () => {
    expect(resumeArgv("claude-code", "abc")).toEqual(["--resume", "abc"]);
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

function seedCodexThreads(home: string, ids: string[]) {
  const db = new Database(join(home, "state_5.sqlite"));
  db.run("CREATE TABLE threads (id TEXT PRIMARY KEY)");
  const insert = db.query("INSERT INTO threads (id) VALUES (?)");
  for (const id of ids) insert.run(id);
  db.close();
}

// agentSessionGone is NOT !sessionResumable: they agree on both certainties and
// split on the middle one, which is the only reason the spec verdict is
// tri-state. A caller that refuses work acts on this one.
describe("agentSessionGone", () => {
  test("a store that answers and lacks the id → gone", () => {
    const codexHome = newDir();
    seedCodexThreads(codexHome, ["other"]);
    expect(agentSessionGone({ tool: "codex", agentSessionId: "missing", codexHome })).toBe(true);
  });
  test("a store that answers and holds the id → not gone", () => {
    const codexHome = newDir();
    seedCodexThreads(codexHome, ["uuid-1"]);
    expect(agentSessionGone({ tool: "codex", agentSessionId: "uuid-1", codexHome })).toBe(false);
  });
  test("a store that cannot be read → not gone, where sessionResumable is also optimistic", () => {
    const codexHome = join(newDir(), "no-such-home");
    expect(agentSessionGone({ tool: "codex", agentSessionId: "uuid-1", codexHome })).toBe(false);
    expect(sessionResumable({ tool: "codex", agentSessionId: "uuid-1", codexHome })).toBe(true);
  });
  // github-copilot has the store check but has NOT claimed its store is what
  // `--resume` consults: its sessions outlive the local index, so a miss is a
  // stale index and the CLI is still asked. Deliberately divergent from
  // sessionResumable, which reports the same miss as a display hint.
  test("a store check alone is not authority — copilot is never gone", () => {
    const copilotHome = newDir();
    seedCopilotSessions(copilotHome, ["uuid-c"]);
    expect(agentSessionGone({ tool: "github-copilot", agentSessionId: "missing", copilotHome })).toBe(false);
    expect(sessionResumable({ tool: "github-copilot", agentSessionId: "missing", copilotHome })).toBe(false);
  });
  test("an agent with no store-existence check is never gone", () => {
    expect(agentSessionGone({ tool: "opencode", agentSessionId: "ses_1" })).toBe(false);
    expect(agentSessionGone({ tool: "claude-code", agentSessionId: "sess-x" })).toBe(false);
    expect(agentSessionGone({ tool: "some-future-agent", agentSessionId: "x" })).toBe(false);
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
