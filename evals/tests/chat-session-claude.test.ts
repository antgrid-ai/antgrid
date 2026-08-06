import { describe, test, expect, beforeAll, afterAll } from "bun:test";
import { setupTestEnv, type TestEnv } from "../helpers/harness";
import { createMessage } from "../../bridge/src/protocol";
import { promptUntilTurnStart } from "../helpers/chat";
import { bindFirstProject } from "../support/stream";

// End-to-end chat-session turn over the REAL relay + the REAL installed
// `claude` binary via the claude-code structured driver
// (bridge/src/agents/claude-code/spawn.ts, pathToClaudeCodeExecutable). This is the
// installed-binary proof for the claude-code driver, mirroring
// chat-session.test.ts's codex coverage.
//
// Gated on a real `claude` binary being on PATH and logged in: environments
// without it (most CI) skip cleanly rather than fail — the same
// availability-gate style as chat-session.test.ts and
// plugin-notifications.test.ts's real-agent chain.
const HAVE_CLAUDE = Bun.which("claude") !== null;

const DEFAULT_NAME = /^Session \d+$/;

describe.skipIf(!HAVE_CLAUDE)("claude-code chat session (E2E, installed binary)", () => {
  let env: TestEnv;
  // The project stream every chat verb rides — session:* and agent:* are
  // agent-core verbs, which the machine control plane does not dispatch.
  let streamId: string;
  let sessionId: string;

  beforeAll(async () => {
    // `claude-code-chat` fixture declares `agent.tool: claude-code` and no
    // autoStart service, so nothing spawns until the eval creates a chat
    // session. setupTestEnv admits the app, turns the machine's mobile-access
    // switch on (the gate would otherwise silently drop every session verb),
    // and pulls the welcome snapshot.
    env = await setupTestEnv({ fixtureName: "claude-code-chat" });
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

  test("runs a text turn: prompt -> turn-start -> message item -> turn-end", async () => {
    // session:create (mode:'chat', tool:'claude-code') → session:result with the row.
    const createReq = `create-${Date.now()}`;
    env.app.sendOnStream(streamId, createMessage("session:create", {
      requestId: createReq,
      name: "chat-eval-claude",
      tool: "claude-code",
      mode: "chat",
    }));
    const created = await env.app.waitForStreamAbType(streamId, "session:result", 10_000);
    expect(created.requestId).toBe(createReq);
    expect(created.ok).toBe(true);
    expect(created.session?.mode).toBe("chat");
    sessionId = created.session!.id;

    // session:start → StructuredAgentManager spawns the claude-code driver,
    // which spawns the real `claude` binary via pathToClaudeCodeExecutable.
    const startReq = `start-${Date.now()}`;
    env.app.sendOnStream(streamId, createMessage("session:start", {
      requestId: startReq,
      sessionId,
    }));
    const startRes = await env.app.waitForStreamAbType(streamId, "session:result", 15_000);
    expect(startRes.ok).toBe(true);

    // session:result for a chat start returns synchronously, BEFORE the async
    // startChat has spawned claude and registered the driver — a prompt sent
    // too early answers `agent:error {message:"chat session not started"}`.
    // There is no distinct "driver ready" frame, so retry the prompt (ignoring
    // that transient) until the first turn opens.
    const turnStart = await promptUntilTurnStart(env.app, streamId, sessionId);
    expect(turnStart.sessionId).toBe(sessionId);
    expect(turnStart.turnId).toBeTruthy();

    // Collect frames until the turn ends (real LLM latency is high, hence the
    // generous window). Assert we saw a normalized message item containing
    // "PONG", and that the turn ended with stopReason "end_turn".
    let sawMessageWithPong = false;
    let turnEnd: any = null;
    const deadline = Date.now() + 60_000;
    while (Date.now() < deadline && !turnEnd) {
      const msg = await env.app
        .waitFor(
          (m: any) =>
            m._streamId === streamId &&
            m.sessionId === sessionId &&
            (m.type === "agent:item-added" || m.type === "agent:turn-end"),
          10_000,
        )
        .catch(() => null);
      if (!msg) break;
      if (msg.type === "agent:item-added") {
        const item = msg.item;
        if (item?.kind === "message" && typeof item.text === "string" && item.text.includes("PONG")) {
          sawMessageWithPong = true;
        }
      } else if (msg.type === "agent:turn-end") {
        turnEnd = msg;
      }
    }

    expect(sawMessageWithPong).toBe(true);
    expect(turnEnd).toBeTruthy();
    expect(turnEnd.stopReason).toBe("end_turn");
  }, 90_000);

  test("a prompt turn auto-names the session from its title", async () => {
    // Create WITHOUT a name so the session gets a default "Session N" and stays
    // auto-nameable (session:create with a name sets manuallyRenamed, which
    // makes applyAutoName no-op — see session-manager.ts). This proves the Stop
    // hook (post-title.js) fires in the SDK's headless query() run: SessionStart
    // fires with an empty transcript and chat mode has no OSC-2 fallback, so the
    // title can only resolve on a populated transcript at turn end.
    const createReq = `create-${Date.now()}`;
    env.app.sendOnStream(streamId, createMessage("session:create", {
      requestId: createReq,
      tool: "claude-code",
      mode: "chat",
    }));
    const created = await env.app.waitForStreamAbType(streamId, "session:result", 10_000);
    expect(created.ok).toBe(true);
    const nameSessionId = created.session!.id;
    expect(created.session!.name).toMatch(DEFAULT_NAME);

    const startReq = `start-${Date.now()}`;
    env.app.sendOnStream(streamId, createMessage("session:start", {
      requestId: startReq,
      sessionId: nameSessionId,
    }));
    const startRes = await env.app.waitForStreamAbType(streamId, "session:result", 15_000);
    expect(startRes.ok).toBe(true);

    // Warm-up race: session:result returns before startChat has spawned claude,
    // so a too-early prompt answers agent:error. promptUntilTurnStart retries.
    // The first user message becomes the resolved title.
    const turnStart = await promptUntilTurnStart(
      env.app,
      streamId,
      nameSessionId,
      "Say the single word PONG and nothing else.",
    );
    expect(turnStart.sessionId).toBe(nameSessionId);

    // Drain the turn so the transcript is populated and the Stop hook fires.
    const turnDeadline = Date.now() + 60_000;
    let turnEnded = false;
    while (Date.now() < turnDeadline && !turnEnded) {
      const msg = await env.app
        .waitFor(
          (m: any) =>
            m._streamId === streamId &&
            m.sessionId === nameSessionId &&
            m.type === "agent:turn-end",
          10_000,
        )
        .catch(() => null);
      if (msg) turnEnded = true;
    }
    expect(turnEnded).toBe(true);

    // The title arrives on its own via session:updated once post-title.js POSTs
    // /session-title. Poll until this session's name stops matching the default.
    let renamed = false;
    let resolvedName = "";
    const nameDeadline = Date.now() + 45_000;
    while (Date.now() < nameDeadline && !renamed) {
      const msg = await env.app
        .waitFor(
          (m: any) => m._streamId === streamId && m.type === "session:updated",
          10_000,
        )
        .catch(() => null);
      if (!msg) continue;
      const row = (msg.sessions as any[])?.find((s) => s.id === nameSessionId);
      if (row && row.name && !DEFAULT_NAME.test(row.name)) {
        renamed = true;
        resolvedName = row.name;
      }
    }
    expect(renamed).toBe(true);
    expect(resolvedName).not.toBe("");
    expect(resolvedName).not.toMatch(DEFAULT_NAME);
  }, 150_000);
});
