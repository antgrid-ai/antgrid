import { describe, test, expect, beforeAll, afterAll } from "bun:test";
import { setupTestEnv, type TestEnv } from "../helpers/harness";
import { createMessage } from "../../bridge/src/protocol";
import { promptUntilTurnStart } from "../helpers/chat";

// End-to-end proof that a chat-mode opencode session auto-names itself from the
// conversation title. Unlike codex (notify.js) or claude (SDK), opencode's own
// server generates a title and pushes it on the session.updated event the
// OpencodeDriver already consumes; the driver's onTitle callback forwards it
// through SessionNamer → applyAutoName → session:updated. We assert the default
// "Session N" name is replaced by a real title.
//
// Gated on a real `opencode` binary on PATH AND an explicit opt-in signalling
// that opencode auth (a configured model provider) is available: a generated
// title requires the server to actually run a model, and without auth opencode
// leaves the title at a placeholder so the session never renames. The env
// opt-in avoids a spurious failure on binary-present-but-unauthenticated boxes
// (most CI), matching how chat-session-codex.test.ts skips when its prereqs are
// absent. Set ANTGRID_EVAL_OPENCODE_AUTH=1 on a box with opencode auth to run it.
const HAVE_OPENCODE =
  Bun.which("opencode") !== null && process.env.ANTGRID_EVAL_OPENCODE_AUTH === "1";

const DEFAULT_NAME = /^Session \d+$/;

// TODO(evals,v3): frozen helpers/chat.ts sends chat verbs on the control plane; v3 routes
// project chat on the stream. Force-skipped until chat.ts is migrated (see chat-session-claude).
describe.skip("chat-session opencode auto-title", () => {
  let env: TestEnv;
  let sessionId: string;

  beforeAll(async () => {
    env = await setupTestEnv({ fixtureName: "opencode-chat" });
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
      tool: "opencode",
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

    // Warm-up race: session:result returns before startChat has spawned the
    // opencode server, so a too-early prompt answers agent:error. Retry.
    const turnStart = await promptUntilTurnStart(env, sessionId);
    expect(turnStart.sessionId).toBe(sessionId);

    // Drain the turn so opencode has a completed conversation to title.
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

    // The title arrives on its own via session:updated once opencode's server
    // generates it and emits session.updated. Poll until this session's name
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
