import { describe, test, expect, beforeAll, afterAll } from "bun:test";
import { generateKeyPairSync } from "node:crypto";
import { allocatePort, startRelay, type RelayHandle } from "../helpers/harness";
import { setupPairFlowTestEnv, type TestEnv } from "../helpers/test-env";
import { RelayClient, PairAgentOfflineError } from "../helpers/relay-client";
import { createMessage } from "../../bridge/src/protocol";
import { loadPairedPhones } from "../../bridge/src/paired-phones";

/** Mirrors harness.ts's private `allowProjectForPairedPhones` (unexported, and
 *  helpers/* is read-only for this phase) — setupPairFlowTestEnv deliberately
 *  does no project-allowlisting itself (X4 needs restartAgent, which only
 *  that helper provides; setupTestEnv provides allowlisting but no restart).
 *  Uses `upsert` (unconditional flush), not `allowProject` (no-ops once
 *  already present) — Bun's fs.watch on paired-phones.json was observed to
 *  occasionally miss/coalesce the change event under load in this sandbox
 *  (see gate-session-limit.test.ts for the reproduction), and an `allowProject`
 *  no-op retry can never recover from that since it skips its own flush(). */
async function allowProjectForPairedPhones(abDir: string, projectId: string): Promise<void> {
  const store = loadPairedPhones(abDir);
  for (const phone of store.list()) {
    const next = phone.allowedProjects.includes(projectId) ? phone.allowedProjects : [...phone.allowedProjects, projectId];
    store.upsert({ ...phone, allowedProjects: next });
  }
  await Bun.sleep(600); // fs.watch debounce on the agent's paired-phones.json watcher
}

function rawEdPubB64(pub: import("node:crypto").KeyObject): string {
  const der = pub.export({ format: "der", type: "spki" });
  return Buffer.from(der.subarray(der.length - 32)).toString("base64");
}

/**
 * HELPER GAP (relay-client.ts, read-only for this phase): `openProjectStream`
 * only resolves on a `stream-ready` frame. But `firstProject` is opened by the
 * agent itself at boot (mode "remote", host-server.ts's index.ts bootstrap),
 * so by the time a phone sends `project:start` for it, the agent takes the
 * ALREADY-remote "idempotent" branch (host-server.ts:774-779), which only
 * re-advertises `agent:projects` (carrying the streamId per design §7.4) and
 * never emits `stream-ready`. `dispatchAbMessage` only populates
 * `streamByProject` from `stream-ready`, so `openProjectStream` hangs forever
 * on an already-open project. Worked around here by also listening for the
 * `agent:projects` advert and reading the streamId out of it directly.
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
 * Merge-gate item 4 (design §6.3, §12): epochs replace the old 60s
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

  test("lower/equal epoch is rejected: a stale process cannot displace a newer one", async () => {
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
  let accountKp: { publicKey: import("node:crypto").KeyObject; privateKey: import("node:crypto").KeyObject };
  let accountPubB64: string;
  let app: RelayClient;

  beforeAll(async () => {
    accountKp = generateKeyPairSync("ed25519");
    accountPubB64 = rawEdPubB64(accountKp.publicKey);
    env = await setupPairFlowTestEnv({ accountPeerKeys: [accountPubB64] });

    app = await RelayClient.connectAndAuth(env.relay.url, { deviceType: "app", name: "gate-epoch-app" });
    for (let i = 0; i < 30; i++) {
      try {
        const r = await app.pairWith(env.agent.deviceId, {
          timeoutMs: 8_000,
          accountKey: { pubB64: accountPubB64, privateKey: accountKp.privateKey },
        });
        app.setPeerId(r.peerId);
        break;
      } catch (err) {
        if (err instanceof PairAgentOfflineError) {
          if (app.isClosed) await app.reconnectAndAuth(env.relay.url);
          await Bun.sleep(200);
          continue;
        }
        throw err;
      }
    }
    await app.performE2EHandshake(env.agent.deviceId, 10_000, { agentEd25519Pub: env.agent.ed25519Pubkey });
    await allowProjectForPairedPhones(env.abDir, env.projectId);
  });

  afterAll(async () => {
    await app?.disconnect();
    await env?.teardown();
  });

  test("restartAgent mid-session: admitted fast, phone recovers, streams rebind, traffic flows", async () => {
    // Baseline: control-plane RPC and the project stream both work pre-restart.
    const baselineId = "gate-epoch-baseline";
    const baselineP = app.waitFor((m: any) => m.type === "response" && m.requestId === baselineId, 5_000);
    app.sendEncrypted(createMessage("request", { requestId: baselineId, method: "state.snapshot", params: { types: ["*"] } }));
    await baselineP;
    const preStreamId = await drillIntoProject(app, env.projectId, 8_000);
    expect(typeof preStreamId).toBe("string");

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
    await app.rekey(env.agent.deviceId, env.agent.ed25519Pubkey, 10_000);

    // Streams rebind: the pre-restart streamId is invalid — the relay closes
    // an agent's streams on disconnect (design §6.4) — so the cached entry
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
