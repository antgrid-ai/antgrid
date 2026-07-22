import { describe, test, expect, beforeAll, afterAll } from "bun:test";
import { generateKeyPairSync } from "node:crypto";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  allocatePort,
  generateEvalAuth,
  spawnAgent,
  startFakeLicenseApi,
  startRelay,
  type AgentHandle,
  type FakeLicenseApi,
  type RelayHandle,
} from "../helpers/harness";
import { RelayClient, PairAgentOfflineError } from "../helpers/relay-client";
import { createTestProject } from "../helpers/fixtures";
import { createMessage } from "../../bridge/src/protocol";
import { loadPairedPhones } from "../../bridge/src/paired-phones";
import { readHostFile } from "../../bridge/src/host-discovery";
import { computeProjectId } from "../../bridge/src/project-id";

function rawEdPubB64(pub: import("node:crypto").KeyObject): string {
  const der = pub.export({ format: "der", type: "spki" });
  return Buffer.from(der.subarray(der.length - 32)).toString("base64");
}

/**
 * `store.allowProject` no-ops (skips its internal `flush()`, so no NEW
 * fs.watch event fires) once the project is already recorded — which makes a
 * naive "write, sleep, and if it didn't take, write again" retry useless: a
 * missed/coalesced first fs.watch event (observed in this sandbox — Bun's
 * fs.watch is occasionally lossy under load, e.g. right after a loopback
 * project:open HTTP round trip) leaves the agent's in-memory allowlist stale
 * forever, since every retry after the first is a silent no-op. `upsert`
 * unconditionally flushes, so it re-triggers the watcher on every call.
 */
async function allowProjectForPairedPhones(abDir: string, projectId: string): Promise<void> {
  const store = loadPairedPhones(abDir);
  for (const phone of store.list()) {
    const next = phone.allowedProjects.includes(projectId) ? phone.allowedProjects : [...phone.allowedProjects, projectId];
    store.upsert({ ...phone, allowedProjects: next });
  }
  await Bun.sleep(600); // fs.watch debounce on the agent's paired-phones.json watcher
}

/** Loopback call to the agent's own local control API (host.json), mirroring
 *  the pattern in evals/tests/multi-socket-coexistence.test.ts. */
async function loopbackControl(abDir: string, body: object): Promise<any> {
  const hf = readHostFile(join(abDir, "host.json"));
  if (!hf) throw new Error("no host.json for loopback control");
  const res = await fetch(`http://127.0.0.1:${hf.controlPort}/control`, {
    method: "POST",
    headers: { "content-type": "application/json", authorization: `Bearer ${hf.token}` },
    body: JSON.stringify(body),
  });
  return res.json();
}

/** See gate-epoch-supersession.test.ts for the full gap note: `openProjectStream`
 *  only recognizes `stream-ready`, but an already-remote project (like
 *  firstProject, auto-attached by the agent at boot) re-advertises its
 *  streamId via `agent:projects` on an idempotent `project:start`, which
 *  `dispatchAbMessage` never folds into `streamByProject`. */
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
    app.waitFor((m: any) => m.type === "stream-ready" && m.projectId === projectId, timeoutMs).then((m: any) => finish(m.streamId)).catch(() => {});
    app
      .waitFor((m: any) => m.type === "agent:projects" && (m.projects ?? []).some((p: any) => p.projectId === projectId && p.streamId), timeoutMs)
      .then((m: any) => finish(m.projects.find((p: any) => p.projectId === projectId).streamId))
      .catch(() => {});
    app.sendEncrypted(createMessage("project:start", { projectId } as any));
    setTimeout(() => {
      if (!settled) { settled = true; reject(new Error(`drillIntoProject(${projectId}) timed out after ${timeoutMs}ms`)); }
    }, timeoutMs);
  });
}

/**
 * Merge-gate item 6 (design §7.3, §12): `sessionLimit` is the paid axis,
 * capped relay-side at `stream-open` admission — agent-only, counted across
 * all live agent connections sharing a license `userId`.
 *
 *  1. A focused, low-level relay-only test driving `stream-open` directly as a
 *     fake agent — the ONLY way to see the raw `ref` field on the rejection,
 *     since `ref`/`SESSION_LIMIT_EXCEEDED` land on the AGENT's own socket and
 *     `spawnAgent` (harness.ts) hides real-bridge stdio/socket traffic.
 *  2. An end-to-end test through a real bridge agent, proving the
 *     phone-visible half: a project push that exceeds the cap surfaces
 *     `control:result{ok:false, error:{code:SESSION_LIMIT_EXCEEDED}}}` to the
 *     requesting phone (host-server.ts's `reportFirstRegister`), while the
 *     already-open project stream and the socket stay fully functional.
 *     `setupPairFlowTestEnv`/`setupTestEnv` don't forward a `sessionLimit`
 *     override (test-env.ts's `startRelay` call is hardcoded), so this test
 *     bootstraps directly (spawnAgent + startRelay({sessionLimit:1})) —
 *     mirroring harness.ts's setupTestEnv internals, which aren't exported.
 */
describe("gate: sessionLimit — relay admission (ref field)", () => {
  let relay: RelayHandle;

  beforeAll(async () => {
    relay = await startRelay({ port: allocatePort(), sessionLimit: 2 });
  });

  afterAll(() => {
    relay.stop();
  });

  test("third stream-open is rejected SESSION_LIMIT_EXCEEDED with ref=streamId; first two + socket stay alive", async () => {
    const agent = await RelayClient.connectAndAuth(relay.url, { deviceType: "agent", name: "gate-session-limit-agent" });
    try {
      const opened1 = agent.waitFor((m: any) => m.type === "stream-opened" && m.streamId === "s1", 5_000);
      agent.sendRaw({ type: "stream-open", streamId: "s1" });
      await opened1;

      const opened2 = agent.waitFor((m: any) => m.type === "stream-opened" && m.streamId === "s2", 5_000);
      agent.sendRaw({ type: "stream-open", streamId: "s2" });
      await opened2;

      const errorP = agent.waitFor((m: any) => m.type === "error" && m.code === "SESSION_LIMIT_EXCEEDED", 5_000);
      agent.sendRaw({ type: "stream-open", streamId: "s3" });
      const err = await errorP;
      expect(err.ref).toBe("s3");
      expect(err.retryable).toBe(false);

      // Socket + the first two admitted streams are untouched.
      expect(await agent.waitForClose(1_000)).toBe(false);
      expect(relay.streamCount()).toBe(2);

      // The first two streams remain independently closeable — proof they're
      // still tracked live server-side, not silently dropped alongside s3.
      const closed1 = agent.waitFor((m: any) => m.type === "stream-closed" && m.streamId === "s1", 3_000);
      agent.sendRaw({ type: "stream-close", streamId: "s1" });
      await closed1;
      expect(relay.streamCount()).toBe(1);
    } finally {
      await agent.disconnect();
    }
  }, 20_000);
});

describe("gate: sessionLimit — end-to-end phone-visible failure", () => {
  let relay: RelayHandle;
  let licenseApi: FakeLicenseApi;
  let agent: AgentHandle;
  let app: RelayClient;
  let abDir: string;
  let projectDir: string;
  let projectId: string;
  let deviceUuid: string;
  let accountKp: { publicKey: import("node:crypto").KeyObject; privateKey: import("node:crypto").KeyObject };
  let accountPubB64: string;

  beforeAll(async () => {
    const port = allocatePort();
    abDir = mkdtempSync(join(tmpdir(), "antgrid-gate-session-limit-"));
    accountKp = generateKeyPairSync("ed25519");
    accountPubB64 = rawEdPubB64(accountKp.publicKey);

    // sessionLimit:1 — firstProject's own boot-time remote attach exhausts it,
    // so the very next project:start is guaranteed to push the agent over cap.
    relay = await startRelay({ port, pairRequestTimeoutMs: 15_000, sessionLimit: 1 });
    licenseApi = startFakeLicenseApi({ accountPeerKeys: [accountPubB64] });
    const auth = generateEvalAuth();
    deviceUuid = auth.deviceUuid;
    const project = createTestProject("basic", { "__RELAY_URL__": `ws://localhost:${port}` });
    projectDir = project.dir;
    projectId = computeProjectId(project.dir);

    agent = await spawnAgent({
      relayUrl: relay.url, licenseApiUrl: licenseApi.url, abDir, projectDir: project.dir, auth,
      env: { ANTGRID_EVAL_TEST: "1" },
    });

    app = await RelayClient.connectAndAuth(relay.url, { deviceType: "app", name: "gate-session-limit-app" });
    for (let i = 0; i < 30; i++) {
      try {
        const r = await app.pairWith(deviceUuid, {
          timeoutMs: 8_000,
          accountKey: { pubB64: accountPubB64, privateKey: accountKp.privateKey },
        });
        app.setPeerId(r.peerId);
        break;
      } catch (err) {
        if (err instanceof PairAgentOfflineError) {
          if (app.isClosed) await app.reconnectAndAuth(relay.url);
          await Bun.sleep(200);
          continue;
        }
        throw err;
      }
    }
    await app.performE2EHandshake(deviceUuid, 10_000, { agentEd25519Pub: auth.ed25519Pub });
    await allowProjectForPairedPhones(abDir, projectId);
  });

  afterAll(async () => {
    await app?.disconnect();
    await agent?.kill();
    relay?.stop();
    licenseApi?.stop();
    try { rmSync(abDir, { recursive: true, force: true }); } catch {}
  });

  test("a project pushed over the cap surfaces control:result SESSION_LIMIT_EXCEEDED; firstProject stays usable", async () => {
    // firstProject already ate the only slot at boot — confirm it's actually
    // live and driving traffic before trying to exceed the cap.
    const streamId = await drillIntoProject(app, projectId, 10_000);
    const echoId = "gate-session-limit-baseline";
    const echoP = app.waitForStreamAbType(streamId, "response", 5_000);
    app.sendOnStream(streamId, createMessage("request", { requestId: echoId, method: "state.snapshot", params: { types: ["*"] } }));
    expect(((await echoP) as any).ok).toBe(true);

    // A second, distinct project — registered LOCAL-only via loopback (so
    // opening it doesn't itself attempt a stream) — then promoted to remote by
    // the phone's own project:start, which is what actually calls stream-open
    // and hits the cap.
    const project2 = createTestProject("basic", { "__RELAY_URL__": "ws://unused" });
    const project2Id = computeProjectId(project2.dir);
    try {
      const opened = await loopbackControl(abDir, {
        id: "open-project2", type: "project:open", projectId: project2Id, projectPath: project2.dir, mode: "local",
      });
      expect(opened.ok).toBe(true);
      await allowProjectForPairedPhones(abDir, project2Id);

      // The allowlist write and the agent's fs.watch reload of it are two
      // separate processes racing over the same file (this test process's
      // write vs. the agent's own occasional writes to the same
      // paired-phones.json); a single project:start can land on a not-yet-
      // reloaded view and get a stale NOT_ALLOWED. Retry a few times rather
      // than chase the exact race — same spirit as this file's pairWith
      // retries and harness.ts's documented fs.watch-debounce wait.
      let rejection: any;
      for (let attempt = 0; attempt < 5; attempt++) {
        const controlResultP = app.waitFor((m: any) => m.type === "control:result" && m.verb === "project:start", 5_000);
        app.sendEncrypted(createMessage("project:start", { projectId: project2Id } as any));
        rejection = await controlResultP;
        if (rejection.error?.code !== "NOT_ALLOWED") break;
        await allowProjectForPairedPhones(abDir, project2Id);
      }
      expect(rejection.ok).toBe(false);
      expect(rejection.error.code).toBe("SESSION_LIMIT_EXCEEDED");

      // The socket and the already-open firstProject stream remain unharmed.
      expect(await app.waitForClose(1_000)).toBe(false);
      const postId = "gate-session-limit-post";
      const postP = app.waitForStreamAbType(streamId, "response", 5_000);
      app.sendOnStream(streamId, createMessage("request", { requestId: postId, method: "state.snapshot", params: { types: ["*"] } }));
      expect(((await postP) as any).ok).toBe(true);
    } finally {
      project2.cleanup();
    }
  }, 30_000);
});
