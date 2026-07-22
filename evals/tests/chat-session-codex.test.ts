import { describe, test, expect, beforeAll, afterAll } from "bun:test";
import { setupTestEnv, type TestEnv } from "../helpers/harness";
import { createMessage } from "../../bridge/src/protocol";
import { promptUntilTurnStart } from "../helpers/chat";

// End-to-end proof that a chat-mode codex session auto-names itself from the
// conversation title. The codex driver spawns `codex app-server` with the
// top-level notify=[...] program injected (notify-only — app-server's -c parser
// rejects the interactive-TUI hooks.* args); after each turn codex fires
// notify.js, which POSTs /session-title, which flows through SessionNamer →
// applyAutoName → session:updated. We assert the default "Session N" name is
// replaced by a real title.
//
// Gated on a real `codex` binary + authenticated codex on PATH (app-server
// needs a free ~/.codex — only one per machine). Environments without it (most
// CI) skip cleanly rather than fail, matching chat-session.test.ts.
const HAVE_CODEX = Bun.which("codex") !== null;

const DEFAULT_NAME = /^Session \d+$/;

// TODO(evals,v3): frozen helpers/chat.ts sends chat verbs on the control plane; v3 routes
// project chat on the stream. Force-skipped until chat.ts is migrated (see chat-session-claude).
describe.skip("chat-session codex auto-title", () => {
  let env: TestEnv;
  let sessionId: string;

  beforeAll(async () => {
    env = await setupTestEnv({ fixtureName: "codex-chat" });
    await env.app.waitForAbType("agent:hello", 10_000);
  }, 60_000);

  afterAll(async () => {
    await env?.teardown();
  });

  test("a prompt turn auto-names the session from its title", async () => {
    // Create WITHOUT a name so the session gets a default "Session N" and stays
    // auto-nameable (session:create with a name sets manuallyRenamed, which
    // makes applyAutoName no-op — see session-manager.ts).
    const createReq = `create-${Date.now()}`;
    env.app.sendEncrypted(createMessage("session:create", {
      requestId: createReq,
      tool: "codex",
      mode: "chat",
    }));
    const created = await env.app.waitForAbType("session:result", 10_000);
    expect(created.ok).toBe(true);
    sessionId = created.session!.id;
    expect(created.session!.name).toMatch(DEFAULT_NAME);

    const startReq = `start-${Date.now()}`;
    env.app.sendEncrypted(createMessage("session:start", {
      requestId: startReq,
      sessionId,
    }));
    const startRes = await env.app.waitForAbType("session:result", 15_000);
    expect(startRes.ok).toBe(true);

    // Warm-up race: session:result returns before startChat has spawned codex,
    // so a too-early prompt answers agent:error. promptUntilTurnStart retries.
    const turnStart = await promptUntilTurnStart(env, sessionId);
    expect(turnStart.sessionId).toBe(sessionId);

    // Drain the turn so codex has a completed conversation to title, and so
    // notify.js fires (it runs on turn completion).
    const turnDeadline = Date.now() + 60_000;
    let turnEnded = false;
    while (Date.now() < turnDeadline && !turnEnded) {
      const msg = await env.app
        .waitFor(
          (m: any) => m.sessionId === sessionId && m.type === "agent:turn-end",
          10_000,
        )
        .catch(() => null);
      if (msg) turnEnded = true;
    }
    expect(turnEnded).toBe(true);

    // The title arrives on its own via session:updated once codex writes its
    // rollout and notify.js POSTs /session-title. Poll until this session's name
    // stops matching the default pattern.
    let renamed = false;
    const nameDeadline = Date.now() + 40_000;
    while (Date.now() < nameDeadline && !renamed) {
      const msg = await env.app
        .waitFor((m: any) => m.type === "session:updated", 10_000)
        .catch(() => null);
      if (!msg) continue;
      const row = (msg.sessions as any[])?.find((s) => s.id === sessionId);
      if (row && !DEFAULT_NAME.test(row.name)) renamed = true;
    }
    expect(renamed).toBe(true);
  }, 150_000);
});
