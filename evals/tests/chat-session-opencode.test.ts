import { describe, test, expect, beforeAll, afterAll } from "bun:test";
import { setupTestEnv, type TestEnv } from "../helpers/harness";
import { createMessage } from "../../bridge/src/protocol";
import { promptUntilTurnStart } from "../helpers/chat";
import { bindFirstProject } from "../support/stream";

// End-to-end proof that a chat-mode opencode session auto-names itself. opencode
// ships neither hooks nor a title we read (its own generated one is dropped —
// see ResolvedTitle), so this is the agent that proves the naming path which
// depends on no vendor integration at all: StructuredAgentManager's onUserPrompt
// tap hands the bridge the first message, which names the session through
// SessionNamer → applyAutoName → session:updated. We assert the default
// "Session N" name is replaced by a real title.
//
// Gated on a real `opencode` binary on PATH AND an explicit opt-in signalling
// that opencode auth (a configured model provider) is available: the turn this
// waits on has to actually run a model. The env opt-in avoids a spurious failure
// on binary-present-but-unauthenticated boxes (most CI), matching how
// chat-session-codex.test.ts skips when its prereqs are absent. Set
// ANTGRID_EVAL_OPENCODE_AUTH=1 on a box with opencode auth to run it.
const HAVE_OPENCODE =
  Bun.which("opencode") !== null && process.env.ANTGRID_EVAL_OPENCODE_AUTH === "1";

const DEFAULT_NAME = /^Session \d+$/;

describe.skipIf(!HAVE_OPENCODE)("chat-session opencode auto-title", () => {
  let env: TestEnv;
  // The project stream every chat verb rides — session:* and agent:* are
  // agent-core verbs, which the machine control plane does not dispatch.
  let streamId: string;
  let sessionId: string;

  beforeAll(async () => {
    env = await setupTestEnv({ fixtureName: "opencode-chat" });
    // Read core readiness out of the project snapshot rather than awaiting a
    // live `agent:hello`: it is a REPLAY_TYPE, and v3 dedups the welcome-replayed
    // burst, so a live wait races a push that may never be re-sent.
    const bound = await bindFirstProject(env.app, env.projectId, 10_000);
    streamId = bound.streamId;
    expect(bound.frames.some((f) => f.type === "agent:hello")).toBe(true);
  }, 60_000);

  afterAll(async () => {
    await env?.teardown();
  });

  test("a prompt turn auto-names the session from its title", async () => {
    // Create WITHOUT a name so the session gets a default "Session N" and stays
    // auto-nameable (session:create with a name sets manuallyRenamed, which
    // makes applyAutoName no-op — see session-manager.ts).
    const createReq = `create-${Date.now()}`;
    env.app.sendOnStream(streamId, createMessage("session:create", {
      requestId: createReq,
      tool: "opencode",
      mode: "chat",
    }));
    const created = await env.app.waitForStreamAbType(streamId, "session:result", 10_000);
    expect(created.ok).toBe(true);
    sessionId = created.session!.id;
    expect(created.session!.name).toMatch(DEFAULT_NAME);

    const startReq = `start-${Date.now()}`;
    env.app.sendOnStream(streamId, createMessage("session:start", {
      requestId: startReq,
      sessionId,
    }));
    const startRes = await env.app.waitForStreamAbType(streamId, "session:result", 15_000);
    expect(startRes.ok).toBe(true);

    // Warm-up race: session:result returns before startChat has spawned the
    // opencode server, so a too-early prompt answers agent:error. Retry.
    const turnStart = await promptUntilTurnStart(env.app, streamId, sessionId);
    expect(turnStart.sessionId).toBe(sessionId);

    // Drain the turn so opencode has a completed conversation to title.
    const turnDeadline = Date.now() + 60_000;
    let turnEnded = false;
    while (Date.now() < turnDeadline && !turnEnded) {
      const msg = await env.app
        .waitFor(
          (m: any) =>
            m._streamId === streamId &&
            m.sessionId === sessionId &&
            m.type === "agent:turn-end",
          10_000,
        )
        .catch(() => null);
      if (msg) turnEnded = true;
    }
    expect(turnEnded).toBe(true);

    // The title arrives on its own via session:updated once the naming spawn the
    // first prompt started comes back. Poll until this session's name stops
    // matching the default pattern.
    let renamed = false;
    const nameDeadline = Date.now() + 40_000;
    while (Date.now() < nameDeadline && !renamed) {
      const msg = await env.app
        .waitFor(
          (m: any) => m._streamId === streamId && m.type === "session:updated",
          10_000,
        )
        .catch(() => null);
      if (!msg) continue;
      const row = (msg.sessions as any[])?.find((s) => s.id === sessionId);
      if (row && !DEFAULT_NAME.test(row.name)) renamed = true;
    }
    expect(renamed).toBe(true);
  }, 150_000);
});
