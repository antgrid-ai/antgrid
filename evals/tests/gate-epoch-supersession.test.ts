import { describe, test, expect, beforeAll, afterAll } from "bun:test";
import { allocatePort, startRelay, setupTestEnv, type RelayHandle, type TestEnv } from "../helpers/harness";
import { RelayClient } from "../helpers/relay-client";
import { createMessage } from "../../bridge/src/protocol";

/**
 * HELPER GAP (relay-client.ts, read-only for this phase): `openProjectStream`
 * only resolves on a `stream-ready` frame. `firstProject` is opened by the
 * agent itself at boot (mode "remote", host-server.ts's index.ts bootstrap),
 * so by the time a phone sends `project:start` for it, the agent takes the
 * ALREADY-remote "idempotent" branch of `handleControlPlaneVerb`.
 *
 * Corrected: this comment previously claimed that branch "never emits
 * stream-ready". As of host-server.ts's "make a lost reply fail honestly
 * instead of hanging" fix (bridge commit 01cb42e4, 2026-07-22 — this comment
 * predates it, from 7ffc36ea on 2026-07-16), the idempotent branch DOES
 * republish `stream-ready` (dedup-immune, unlike the advert) whenever the
 * project's relay slot is already registered — see
 * `multi-stream-coexistence.test.ts`, which relies on exactly that republish
 * for its own already-open-project case. What remains true: the republish is
 * gated on `core.isRelayRegistered()`, so a `project:start` that lands in the
 * narrow window before that project's OWN relay slot finishes registering
 * still gets only the `agent:projects` re-advert, no `stream-ready` —
 * `dispatchAbMessage` only populates `streamByProject` from `stream-ready`,
 * so a plain `openProjectStream` could still hang in that window. Kept the
 * dual-listener workaround below (also reading the streamId out of the
 * `agent:projects` advert) as defensive belt-and-suspenders for that
 * remaining window, even though the common case is now covered by the
 * bridge-side republish.
 */
async function drillIntoProject(app: RelayClient, projectId: string, timeoutMs = 10_000): Promise<string> {
  const cached = (app as any).streamByProject.get(projectId);
  if (cached) return cached;
  return new Promise<string>((resolve, reject) => {
    let settled = false;
    const finish = (streamId: string) => {
      if (settled) return;
      settled = true;
      (app as any).streamByProject.set(projectId, streamId);
      resolve(streamId);
    };
    app
      .waitFor((m: any) => m.type === "stream-ready" && m.projectId === projectId, timeoutMs)
      .then((m: any) => finish(m.streamId))
      .catch(() => {});
    app
      .waitFor(
        (m: any) => m.type === "agent:projects" && (m.projects ?? []).some((p: any) => p.projectId === projectId && p.streamId),
        timeoutMs,
      )
      .then((m: any) => finish(m.projects.find((p: any) => p.projectId === projectId).streamId))
      .catch(() => {});
    app.sendEncrypted(createMessage("project:start", { projectId } as any));
    setTimeout(() => {
      if (!settled) {
        settled = true;
        reject(new Error(`drillIntoProject(${projectId}) timed out after ${timeoutMs}ms`));
      }
    }, timeoutMs);
  });
}

/**
 * Merge-gate item 4: epochs replace the old 60s
 * ACTIVE_THRESHOLD_MS liveness heuristic. Two halves:
 *
 *  1. A focused, low-level relay-only test using RelayClient AS a fake agent
 *     (two connections, same deviceId, distinct epochs) — this is the only way
 *     to directly observe the OLD connection's own `error{SUPERSEDED}` frame.
 *     `spawnAgent` (harness.ts) hardcodes `stdout:"ignore", stderr:"ignore"`
 *     for the real bridge process and exposes no hook onto the agent's own
 *     relay socket, so a real end-to-end restart can't show us that frame —
 *     documented gap, worked around here rather than left untested.
 *  2. An end-to-end restartAgent test measuring admission latency and
 *     verifying the phone recovers. The fake phone (`relay-client.ts`) has no
 *     built-in "peer-online after peer-offline ⇒ auto-rekey" trigger — that
 *     lives only in the real app (`app/lib/...MachineSession`), not in this
 *     TS test double — so the rekey step here is test-driven, clearly marked.
 */
describe("gate: epoch supersession — relay arbitration", () => {
  let relay: RelayHandle;

  beforeAll(async () => {
    relay = await startRelay({ port: allocatePort() });
  });

  afterAll(() => {
    relay.stop();
  });

  test("higher epoch supersedes: old connection gets SUPERSEDED, new one is admitted", async () => {
    const deviceId = crypto.randomUUID();
    const identityClient = await RelayClient.connectAndAuth(relay.url, {
      deviceType: "agent",
      name: "epoch-a",
      deviceId,
      epoch: 100,
    });
    const identity = identityClient.exportIdentity();

    const closeP = identityClient.waitForClose(5_000);
    const errorP = identityClient.waitFor((m: any) => m.type === "error", 5_000);

    const newer = await RelayClient.connectAndAuth(relay.url, {
      deviceType: "agent",
      name: "epoch-b",
      deviceId,
      identity,
      epoch: 200,
    });

    const errFrame = await errorP;
    expect(errFrame.code).toBe("SUPERSEDED");
    expect(errFrame.retryable).toBe(false);
    expect(await closeP).toBe(true);

    // The new (higher-epoch) connection stays live and usable.
    expect(await newer.waitForClose(1_000)).toBe(false);
    await newer.disconnect();
  }, 15_000);

  test("equal epoch under the same identity admits: a redial evicts its own zombie", async () => {
    const deviceId = crypto.randomUUID();
    // The half-open scenario: the client's watchdog closed this socket and
    // redialed with the SAME per-process epoch, but the relay hasn't reaped
    // the old connection yet (equal-epoch rule).
    const zombie = await RelayClient.connectAndAuth(relay.url, {
      deviceType: "agent",
      name: "epoch-zombie",
      deviceId,
      epoch: 300,
    });
    const identity = zombie.exportIdentity();
    const zombieCloseP = zombie.waitForClose(5_000);
    const zombieErrP = zombie.waitFor((m: any) => m.type === "error", 5_000);

    const redial = await RelayClient.connectAndAuth(relay.url, {
      deviceType: "agent",
      name: "epoch-redial",
      deviceId,
      identity,
      epoch: 300,
    });

    const errFrame = await zombieErrP;
    expect(errFrame.code).toBe("SUPERSEDED");
    expect(await zombieCloseP).toBe(true);

    // The redial is the live holder and stays usable.
    expect(await redial.waitForClose(1_000)).toBe(false);
    await redial.disconnect();
  }, 15_000);

  test("lower epoch is rejected: a stale process cannot displace a newer one", async () => {
    const deviceId = crypto.randomUUID();
    const current = await RelayClient.connectAndAuth(relay.url, {
      deviceType: "agent",
      name: "epoch-current",
      deviceId,
      epoch: 500,
    });
    const identity = current.exportIdentity();

    // A stale hello with a LOWER epoch must itself be rejected+closed, and the
    // CURRENT (higher-epoch) connection must be undisturbed.
    let staleRejected = false;
    try {
      await RelayClient.connectAndAuth(relay.url, {
        deviceType: "agent",
        name: "epoch-stale",
        deviceId,
        identity,
        epoch: 499,
      });
    } catch {
      staleRejected = true;
    }
    expect(staleRejected).toBe(true);
    expect(await current.waitForClose(1_500)).toBe(false);
    await current.disconnect();
  }, 15_000);
});

describe("gate: epoch supersession — agent restart end-to-end", () => {
  let env: TestEnv;

  beforeAll(async () => {
    // setupTestEnv already admits `env.app` with NO pairing ceremony and
    // allows the firstProject for it.
    env = await setupTestEnv({ fixtureName: "basic" });
  });

  afterAll(async () => {
    await env?.teardown();
  });

  test("restartAgent mid-session: admitted fast, phone recovers, streams rebind, traffic flows", async () => {
    const app = env.app;
    // Baseline: control-plane RPC and the project stream both work pre-restart.
    const baselineId = "gate-epoch-baseline";
    const baselineP = app.waitFor((m: any) => m.type === "response" && m.requestId === baselineId, 5_000);
    app.sendEncrypted(createMessage("request", { requestId: baselineId, method: "state.snapshot", params: { types: ["*"] } }));
    await baselineP;
    const preStreamId = await drillIntoProject(app, env.projectId, 8_000);
    expect(typeof preStreamId).toBe("string");

    // The same-account presence fan-out emits a peer-online to this phone at
    // the agent's INITIAL connect, which the client
    // queues. Drop it so the waiter below binds to the genuinely-fresh
    // post-restart peer-online (emitted when the new agent re-registers and is
    // routable), not the stale queued one — otherwise the one-shot rekey fires
    // before the restarted agent is reachable and its client-hello is dropped.
    app.drainQueued("peer-online");

    const t0 = Date.now();
    const peerOnlineP = app.waitForType("peer-online", 15_000);
    await env.restartAgent(); // kills the old process, spawns a fresh one reusing abDir (epoch increments)
    await peerOnlineP;
    const admittedMs = Date.now() - t0;

    // Kills the old 60s ACTIVE_THRESHOLD_MS heuristic — the new instance is
    // admitted (and its liveness observed by the phone) well under 5s.
    expect(admittedMs).toBeLessThan(5_000);

    // The fake phone has no "peer-online ⇒ auto-rekey" wiring (see file
    // header) — the real app does this itself; drive it explicitly here.
    await app.rekey(env.agentDeviceId, env.agent.ed25519Pubkey, 10_000);

    // Streams rebind: the pre-restart streamId is invalid — the relay closes
    // an agent's streams on disconnect — so the cached entry
    // must be dropped before re-drilling in (see drillIntoProject's gap note:
    // relay-client.ts never invalidates streamByProject on peer-offline/rekey).
    (app as any).streamByProject.delete(env.projectId);
    const streamId = await drillIntoProject(app, env.projectId, 10_000);
    expect(typeof streamId).toBe("string");
    expect(streamId).not.toBe(preStreamId);

    const echoId = "gate-epoch-post-restart";
    const echoP = app.waitForStreamAbType(streamId, "response", 5_000);
    app.sendOnStream(
      streamId,
      createMessage("request", { requestId: echoId, method: "state.snapshot", params: { types: ["*"] } }),
    );
    const echoRes = await echoP;
    expect((echoRes as any).requestId).toBe(echoId);
    expect((echoRes as any).ok).toBe(true);
  }, 40_000);
});
