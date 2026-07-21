import { afterEach, describe, expect, test } from "bun:test";
import { mkdtempSync, rmSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { SessionManager } from "../src/session-manager";

function makeTm() {
  const live = new Set<string>();
  const spawns: any[] = [];
  return {
    has: (id: string) => live.has(id),
    kill: (id: string) => { live.delete(id); },
    spawn: (cfg: any) => { live.add(cfg.terminalId); spawns.push(cfg); return cfg.terminalId; },
    __spawns: spawns,
  } as any;
}

const dirs: string[] = [];
function newStore() { const d = mkdtempSync(join(tmpdir(), "ab-sm-resume-")); dirs.push(d); return d; }
afterEach(() => { for (const d of dirs.splice(0)) try { rmSync(d, { recursive: true, force: true }); } catch {} });

// `extra` lets later tests inject opts (e.g. an isolated `codexHome` so the
// codex resume pre-flight can't read the dev machine's real ~/.codex).
function mk(storeDir: string, tm = makeTm(), extra: Record<string, unknown> = {}) {
  return new SessionManager({
    projectId: "p1", storeDir, projectPath: storeDir,
    terminalManager: tm,
    agentSpec: { command: "claude", name: "claude" },
    sendMessage: () => {},
    ...extra,
  });
}

describe("setAgentSession persistence", () => {
  test("overwrite-latest stores id + transcript and survives reload", () => {
    const store = newStore();
    const sm = mk(store);
    const s = sm.create("Slot", { tool: "claude-code" });
    sm.setAgentSession(s.id, "sess-aaa", "/t/a.jsonl");
    sm.setAgentSession(s.id, "sess-bbb", "/t/b.jsonl"); // latest wins
    sm.flushNow();

    const raw = JSON.parse(readFileSync(join(store, "agents", "p1", "sessions.json"), "utf8"));
    const row = raw.sessions.find((r: any) => r.id === s.id);
    expect(row.agentSessionId).toBe("sess-bbb");
    expect(row.agentTranscriptPath).toBe("/t/b.jsonl");
  });

  test("setAgentSession is a no-op for unknown ids", () => {
    const sm = mk(newStore());
    expect(() => sm.setAgentSession("nope", "x")).not.toThrow();
  });

  // Was asserted absent when the id was bridge-internal (resume args only).
  // The app now gates chat-transcript hydration on it, so the wire entry must
  // carry it — withholding it renders an empty transcript for a session started
  // on another device. agentTranscriptPath stays internal: a local FS path no
  // client consumes.
  test("agentSessionId is exposed on the wire entry; the transcript path is not", () => {
    const sm = mk(newStore());
    const s = sm.create("Slot", { tool: "claude-code" });
    sm.setAgentSession(s.id, "sess-aaa", "/t/a.jsonl");
    expect((sm.get(s.id) as any).agentSessionId).toBe("sess-aaa");
    expect((sm.list(true)[0] as any).agentSessionId).toBe("sess-aaa");
    expect((sm.get(s.id) as any).agentTranscriptPath).toBeUndefined();
  });
});

describe("start() resume wiring", () => {
  test("claude resume appends --resume to the spawn args", () => {
    const store = newStore();
    const tm = makeTm();
    const sm = mk(store, tm);
    const s = sm.create("Slot", { tool: "claude-code" });
    // Stored id + a transcript that exists → resumable.
    const tp = join(store, "tx.jsonl"); writeFileSync(tp, "{}");
    sm.setAgentSession(s.id, "sess-xyz", tp);
    sm.start(s.id);
    const spawn = tm.__spawns.at(-1);
    expect(spawn.args).toContain("--resume");
    expect(spawn.args).toContain("sess-xyz");
  });

  test("codex resume appends the subcommand AFTER the global -c flags", () => {
    const store = newStore();
    const tm = makeTm();
    // Isolated, non-existent codexHome so the resume pre-flight is deterministic:
    // codexThreadExistsSync returns null (undeterminable) → optimistic resume.
    // WITHOUT this, the test reads the dev machine's real ~/.codex, where
    // "uuid-1" is not a real thread → false → resume refused → test fails.
    const sm = mk(store, tm, { codexHome: join(store, "no-such-codex") });
    const s = sm.create("Slot", { tool: "codex" });
    sm.setAgentSession(s.id, "uuid-1"); // no transcript path → codex preflight via codexHome
    sm.start(s.id);
    const spawn = tm.__spawns.at(-1);
    const args: string[] = spawn.args;
    expect(args).toContain("resume");
    expect(args.at(-2)).toBe("resume");
    expect(args.at(-1)).toBe("uuid-1");
    // global -c flags precede the subcommand
    expect(args.indexOf("-c")).toBeLessThan(args.indexOf("resume"));
  });

  test("a stale id (transcript gone) is cleared and the session starts fresh", () => {
    const store = newStore();
    const tm = makeTm();
    const sm = mk(store, tm);
    const s = sm.create("Slot", { tool: "claude-code" });
    sm.setAgentSession(s.id, "sess-dead", "/no/such/file.jsonl");
    sm.start(s.id);
    const spawn = tm.__spawns.at(-1);
    expect(spawn.args).not.toContain("--resume");
    sm.flushNow();
    const raw = JSON.parse(readFileSync(join(store, "agents", "p1", "sessions.json"), "utf8"));
    expect(raw.sessions.find((r: any) => r.id === s.id).agentSessionId).toBeUndefined();
  });

  test("resume args fold into the command line when per-session args are set", () => {
    const store = newStore();
    const tm = makeTm();
    const sm = mk(store, tm);
    const s = sm.create("Slot", { tool: "claude-code", args: "--model opus" });
    const tp = join(store, "tx.jsonl"); writeFileSync(tp, "{}");
    sm.setAgentSession(s.id, "sess-fold", tp);
    sm.start(s.id);
    const spawn = tm.__spawns.at(-1);
    // folded path: everything in `command`, spawnArgs empty
    expect(spawn.command).toContain("--resume sess-fold");
    expect(spawn.command).toContain("--model opus");
    expect(spawn.args).toEqual([]);
  });

  test("codex resume subcommand lands AFTER per-session args in the folded path", () => {
    const store = newStore();
    const tm = makeTm();
    const sm = mk(store, tm, { codexHome: join(store, "no-such-codex") });
    const s = sm.create("Slot", { tool: "codex", args: "--model gpt-5" });
    sm.setAgentSession(s.id, "uuid-1"); // no path → preflight via codexHome (null → optimistic)
    sm.start(s.id);
    const cmd: string = tm.__spawns.at(-1).command;
    // codex requires `… <global flags> <user flags> resume <uuid>`: the
    // subcommand must be last, never followed by the user's flags.
    expect(cmd.indexOf("--model gpt-5")).toBeLessThan(cmd.indexOf("resume uuid-1"));
    expect(cmd.trimEnd().endsWith("resume uuid-1")).toBe(true);
    expect(tm.__spawns.at(-1).args).toEqual([]);
  });
});

describe("setAgentSession transcript-path retention", () => {
  test("a later path-less report keeps the captured path for the same session", () => {
    const store = newStore();
    const sm = mk(store);
    const s = sm.create("Slot", { tool: "claude-code" });
    sm.setAgentSession(s.id, "sess-1", "/t/real.jsonl");
    sm.setAgentSession(s.id, "sess-1"); // SessionStart-style, no path
    sm.flushNow();
    const raw = JSON.parse(readFileSync(join(store, "agents", "p1", "sessions.json"), "utf8"));
    const row = raw.sessions.find((r: any) => r.id === s.id);
    expect(row.agentSessionId).toBe("sess-1");
    expect(row.agentTranscriptPath).toBe("/t/real.jsonl"); // retained, not wiped
  });

  test("a new session id resets the path", () => {
    const store = newStore();
    const sm = mk(store);
    const s = sm.create("Slot", { tool: "claude-code" });
    sm.setAgentSession(s.id, "sess-1", "/t/real.jsonl");
    sm.setAgentSession(s.id, "sess-2"); // switched conversations, no path yet
    sm.flushNow();
    const raw = JSON.parse(readFileSync(join(store, "agents", "p1", "sessions.json"), "utf8"));
    const row = raw.sessions.find((r: any) => r.id === s.id);
    expect(row.agentSessionId).toBe("sess-2");
    expect(row.agentTranscriptPath).toBeUndefined();
  });
});
