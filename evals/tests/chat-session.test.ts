import { describe, test, expect, beforeAll, afterAll } from "bun:test";
import { setupTestEnv, type TestEnv } from "../helpers/harness";
import { createMessage } from "../../bridge/src/protocol";
import { promptUntilTurnStart } from "../helpers/chat";
import { bindFirstProject } from "../support/stream";

// End-to-end chat-session lifecycle over the REAL relay + a REAL codex
// app-server: create → start → prompt → observe one normalized turn → stop →
// restart → the prior transcript rehydrates from the persisted agentSessionId.
// This is the local+relay parity proof for the structured (chat-mode) driver.
//
// Gated on a real `codex` binary being on PATH: the driver spawns
// `codex app-server` and drives a live turn (`bridge/src/codex/spawn-codex.ts`),
// which needs both the binary and an authenticated codex. Environments without
// it (most CI) skip cleanly rather than fail — the same availability-gate style
// as plugin-notifications.test.ts's real-agent chain. `describe.skipIf` keeps
// the assertions intact so the suite passes the moment codex is present.
const HAVE_CODEX = Bun.which("codex") !== null;

describe.skipIf(!HAVE_CODEX)("chat-session (codex)", () => {
  let env: TestEnv;
  // The project stream every chat verb rides — session:* and agent:* are
  // agent-core verbs, which the machine control plane does not dispatch.
  let streamId: string;
  // The bridge-assigned session id, shared across the lifecycle steps below.
  let sessionId: string;

  beforeAll(async () => {
    // `codex-chat` fixture declares `agent.tool: codex` and no autoStart
    // service, so nothing spawns until the eval creates a chat session.
    // setupTestEnv admits the app, turns the machine's mobile-access switch on
    // (the gate would otherwise silently drop every session verb), and pulls the
    // welcome snapshot.
    env = await setupTestEnv({ fixtureName: "codex-chat" });
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

  test("create → start → prompt drives one normalized turn", async () => {
    // session:create (mode:'chat', tool:'codex') → session:result with the row.
    const createReq = `create-${Date.now()}`;
    env.app.sendOnStream(streamId, createMessage("session:create", {
      requestId: createReq,
      name: "chat-eval",
      tool: "codex",
      mode: "chat",
    }));
    const created = await env.app.waitForStreamAbType(streamId, "session:result", 10_000);
    expect(created.requestId).toBe(createReq);
    expect(created.ok).toBe(true);
    expect(created.session?.mode).toBe("chat");
    sessionId = created.session!.id;

    // session:start → StructuredAgentManager spawns the codex driver and
    // captures its threadId (persisted for the restart step below).
    const startReq = `start-${Date.now()}`;
    env.app.sendOnStream(streamId, createMessage("session:start", {
      requestId: startReq,
      sessionId,
    }));
    const startRes = await env.app.waitForStreamAbType(streamId, "session:result", 15_000);
    expect(startRes.ok).toBe(true);

    // session:result for a chat start returns synchronously, BEFORE the async
    // startChat has spawned codex and registered the driver — a prompt sent too
    // early answers `agent:error {message:"chat session not started"}`. There is
    // no distinct "driver ready" frame, so retry the prompt (ignoring that
    // transient) until the first turn opens. This is the same warm-up race a
    // real app faces on start→immediate-send.
    const turnStart = await promptUntilTurnStart(env.app, streamId, sessionId);
    expect(turnStart.sessionId).toBe(sessionId);
    expect(turnStart.turnId).toBeTruthy();

    // Collect item-added frames until the turn ends (real LLM latency is high,
    // hence the generous window). At least one normalized item must arrive.
    let itemCount = 0;
    let turnEnded = false;
    const deadline = Date.now() + 60_000;
    while (Date.now() < deadline && !turnEnded) {
      try {
        const msg = await env.app.waitFor(
          (m: any) =>
            m._streamId === streamId &&
            m.sessionId === sessionId &&
            (m.type === "agent:item-added" || m.type === "agent:turn-end"),
          10_000,
        );
        if (msg.type === "agent:item-added") itemCount++;
        else if (msg.type === "agent:turn-end") turnEnded = true;
      } catch {
        break;
      }
    }
    expect(turnEnded).toBe(true);
    expect(itemCount).toBeGreaterThanOrEqual(1);
  }, 120_000);

  test("stop → restart rehydrates the prior transcript before the next prompt", async () => {
    // Let codex flush the just-completed turn to its own rollout store before we
    // kill it — thread/resume only rehydrates what was persisted, so an immediate
    // stop after turn-end can race the flush and resume to an empty transcript.
    await Bun.sleep(1_500);

    // session:stop → disposes the driver (kills the codex app-server).
    const stopReq = `stop-${Date.now()}`;
    env.app.sendOnStream(streamId, createMessage("session:stop", {
      requestId: stopReq,
      sessionId,
    }));
    const stopRes = await env.app.waitForStreamAbType(streamId, "session:result", 10_000);
    expect(stopRes.ok).toBe(true);

    // session:start again → the persisted agentSessionId (codex threadId) drives
    // thread/resume, whose rollout history is rehydrated for the prior transcript
    // BEFORE any new prompt is sent (codex-resume-replay.ts covers the
    // response-carried variant). We assert the rehydration surfaces at least one
    // prior item so the transcript is restored.
    const restartReq = `restart-${Date.now()}`;
    env.app.sendOnStream(streamId, createMessage("session:start", {
      requestId: restartReq,
      sessionId,
    }));

    // No new agent:prompt — the transcript arrives on its own. Poll to the outer
    // deadline (a per-wait timeout must NOT abort: the fast session:result and the
    // slower streamed rehydration can be many seconds apart).
    //
    // The replay is ONE batched `agent:transcript-replay` carrying the prior
    // frames, NOT a sequence of `agent:item-added`: per-frame replay exceeds the
    // relay's per-pair rate limit and silently truncates the transcript, so
    // drivers must go through `createTranscriptReplay` (protocol.ts). It returns
    // null for an empty history, so the frames inside are what proves restoration.
    let replayedItems = 0;
    let sawRestartResult = false;
    const deadline = Date.now() + 40_000;
    while (Date.now() < deadline && !(replayedItems > 0 && sawRestartResult)) {
      const remaining = deadline - Date.now();
      if (remaining <= 0) break;
      const msg = await env.app
        .waitFor(
          (m: any) =>
            m._streamId === streamId &&
            ((m.type === "agent:transcript-replay" && m.sessionId === sessionId) ||
              (m.type === "session:result" && m.requestId === restartReq)),
          Math.min(remaining, 10_000),
        )
        .catch(() => null);
      if (!msg) continue;
      if (msg.type === "agent:transcript-replay") {
        replayedItems += (msg.frames as { type?: string }[]).filter(
          (f) => f?.type === "agent:item-added",
        ).length;
      } else {
        expect(msg.ok).toBe(true);
        sawRestartResult = true;
      }
    }
    expect(sawRestartResult).toBe(true);
    expect(replayedItems).toBeGreaterThanOrEqual(1);
  }, 90_000);

  test("a model/effort selection survives stop → restart", async () => {
    // Read the live capabilities to pick a real, currently-unselected option.
    // Match on a POPULATED frame for this session, not on the type alone:
    // `session:stop` deliberately emits an empty `agent:capabilities
    // {sessionId}` to clear the selectors (structured-manager's trackTeardown),
    // and the previous test leaves one queued. Binding to that one makes every
    // branch below fall through to the `!key` early return, so the test passes
    // green while asserting nothing.
    const caps: any = await env.app.waitFor(
      (m: any) =>
        m._streamId === streamId &&
        m.type === "agent:capabilities" &&
        m.sessionId === sessionId &&
        Array.isArray(m.models) &&
        m.models.length > 0,
      15_000,
    );

    // Prefer flipping the model; fall back to effort. Both are validated
    // server-side, so we must pick an id the backend actually advertises. Wire
    // shape (protocol.ts:941): models is [{id, name, efforts?, ...}]; effort
    // options live under the CURRENT model's `efforts`, not a top-level list.
    let key: "model" | "effort" | null = null;
    let target: string | null = null;
    if (Array.isArray(caps.models) && caps.models.length >= 2) {
      target = caps.models
        .map((m: any) => m.id)
        .find((id: string) => id !== caps.currentModelId) ?? null;
      if (target) key = "model";
    }
    if (!key) {
      const efforts: string[] =
        caps.models?.find((m: any) => m.id === caps.currentModelId)?.efforts ?? [];
      if (efforts.length >= 2) {
        target = efforts.find((e) => e !== caps.currentEffortId) ?? null;
        if (target) key = "effort";
      }
    }
    // If this codex build advertises no alternative, there is nothing to prove.
    if (!key || !target) return;

    // Change the selection and wait for the driver's confirming echo.
    env.app.sendOnStream(streamId, createMessage("agent:set-config", {
      sessionId, key, value: target,
    }));
    const echoField = key === "model" ? "currentModelId" : "currentEffortId";
    await env.app.waitFor(
      (m: any) => m._streamId === streamId && m.type === "agent:capabilities" &&
        m.sessionId === sessionId && m[echoField] === target,
      15_000,
    );

    // Let codex flush before the kill (same race the rehydrate test guards).
    await Bun.sleep(1_500);

    // stop → start.
    env.app.sendOnStream(streamId, createMessage("session:stop", {
      requestId: `stop-cfg-${Date.now()}`, sessionId,
    }));
    await env.app.waitForStreamAbType(streamId, "session:result", 10_000);
    env.app.sendOnStream(streamId, createMessage("session:start", {
      requestId: `start-cfg-${Date.now()}`, sessionId,
    }));

    // After restart, the capabilities echo must report the restored selection —
    // not the backend default. Poll (the restored value arrives once the driver
    // flushes its replayed pendingConfig, which can trail session:result).
    const restored = await env.app.waitFor(
      (m: any) => m._streamId === streamId && m.type === "agent:capabilities" &&
        m.sessionId === sessionId && m[echoField] === target,
      40_000,
    );
    expect(restored[echoField]).toBe(target);
  }, 90_000);
});
