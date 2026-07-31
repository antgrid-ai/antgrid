import { describe, it, expect, beforeEach, afterEach } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { SessionManager } from "../src/session-manager";
import { createMessage, type AbMessage } from "../src/protocol";

// Per-session work status: the same reduction the project-level advert uses,
// scoped to one slot. What these assert is that a notification lands on the
// session that FIRED it and on no other — the project-level status can't answer
// "is THIS session mid-turn", which is the whole reason the field exists.

function makeTerm() {
  const live = new Set<string>();
  return {
    spawn: (cfg: { terminalId?: string }) => { live.add(cfg.terminalId!); return cfg.terminalId!; },
    kill: (_id: string) => {},
    has: (id: string) => live.has(id),
    exit: (id: string) => { live.delete(id); },
  };
}

function notify(sessionId: string | undefined, notificationType: string): AbMessage {
  return createMessage("notification:push", {
    notificationType: notificationType as never,
    sessionId,
    projectId: "p1",
  });
}

describe("per-session work status", () => {
  let dir: string;
  let term: ReturnType<typeof makeTerm>;
  let sm: SessionManager;

  beforeEach(() => {
    dir = mkdtempSync(join(tmpdir(), "antgrid-swork-"));
    term = makeTerm();
    sm = new SessionManager({
      projectId: "p1", storeDir: dir, projectPath: dir, terminalManager: term as any,
      agentSpec: { command: "codex", name: "codex" },
      sendMessage: () => {},
    });
  });
  afterEach(() => {
    sm.flushNow();
    rmSync(dir, { recursive: true, force: true });
  });

  it("a stopped session is done, a started one is working", () => {
    const s = sm.create("a", { tool: "codex" });
    expect(s.workStatus).toBe("done");
    sm.start(s.id);
    expect(sm.get(s.id)?.workStatus).toBe("working");
  });

  it("separates attention from working so the two can be worded differently", () => {
    const s = sm.create("a", { tool: "codex" });
    sm.start(s.id);
    sm.observeNotification(notify(s.id, "permission_request"));
    // Not merely "busy": killing an agent blocked here abandons the pending
    // tool call, and a resume does not re-ask it.
    expect(sm.get(s.id)?.workStatus).toBe("attention");

    sm.observeNotification(notify(s.id, "task_complete"));
    expect(sm.get(s.id)?.workStatus).toBe("done");
  });

  it("lands the notification only on the session that fired it", () => {
    const a = sm.create("a", { tool: "codex" });
    const b = sm.create("b", { tool: "codex" });
    sm.start(a.id);
    sm.start(b.id);
    sm.observeNotification(notify(a.id, "permission_request"));

    expect(sm.get(a.id)?.workStatus).toBe("attention");
    expect(sm.get(b.id)?.workStatus).toBe("working");
  });

  it("ignores a notification that names no session or an unknown one", () => {
    const s = sm.create("a", { tool: "codex" });
    sm.start(s.id);
    sm.observeNotification(notify(undefined, "permission_request"));
    sm.observeNotification(notify("service-pty", "permission_request"));
    expect(sm.get(s.id)?.workStatus).toBe("working");
  });

  it("a turn-start clears the previous turn's outcome", () => {
    const s = sm.create("a", { tool: "codex" });
    sm.start(s.id);
    sm.observeNotification(notify(s.id, "task_complete"));
    expect(sm.get(s.id)?.workStatus).toBe("done");

    sm.noteTurnStart(s.id);
    expect(sm.get(s.id)?.workStatus).toBe("working");
  });

  it("clears to done when the PTY exits while the agent was still blocked", () => {
    const s = sm.create("a", { tool: "codex" });
    sm.start(s.id);
    sm.observeNotification(notify(s.id, "permission_request"));
    term.exit(s.id);
    sm.noteExited(s.id);
    // A call-to-action for a session with no runtime is a lie.
    expect(sm.get(s.id)?.workStatus).toBe("done");
  });

  it("re-emits the session list when a notification moves a session's status", () => {
    const s = sm.create("a", { tool: "codex" });
    sm.start(s.id);
    let emits = 0;
    sm.onChange(() => { emits++; });
    sm.observeNotification(notify(s.id, "permission_request"));
    expect(emits).toBe(1);
    // Same notification again changes nothing, so nothing is re-advertised.
    sm.observeNotification(notify(s.id, "permission_request"));
    expect(emits).toBe(1);
  });
});
