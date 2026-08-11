import { test, expect } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  allocatePort,
  generateAppIdentity,
  generateEvalAuth,
  handshakeWithoutPairing,
  RELAY_INTERNAL_SECRET,
  spawnAgent,
  startFakeLicenseApi,
  startRelay,
  type AgentHandle,
  type FakeLicenseApi,
} from "../helpers/harness";
import { startRestartableRelay } from "../helpers/restartable-relay";
import { RelayClient } from "../helpers/relay-client";
import { createTestProject } from "../helpers/fixtures";
import { createMessage } from "../../bridge/src/protocol";
import { loadPairedPhones } from "../../bridge/src/paired-phones";

/**
 * Proves the bridge's account-trust admission path end-to-end: a full E2E
 * session — connect, handshake, control-plane round trip — surviving a relay
 * restart with no re-pair. There is no other admission path: the app signs
 * the E2E transcript as its own `kind:"app"` `DeviceRecord`, and the bridge
 * resolves it from the account peers inventory (`TrustedPeersProvider`/
 * `resolvePhoneEd25519PubB64`), authorized on the wire by the relay's
 * same-account routing (`mayRoute`, `authz.ts`).
 *
 * Choreography copied from `gate-relay-restart.test.ts` (same
 * `startRestartableRelay` force-close-and-fresh-port technique — harness.ts's
 * `RelayHandle.stop()` is a GRACEFUL stop that leaves existing WebSockets
 * open, so the agent never redials): the app's Ed25519 identity is generated
 * locally (mirroring `RelayClient.connectAndAuth`'s own key generation) and
 * served back to the agent via the fake license API's
 * `GET /account/devices/me/peers` route (`devices[]`).
 *
 * The handshake frames this file drives are inside `handshakeWithoutPairing`
 * (imported from `../helpers/harness.ts`, shared with `TestApp`/
 * `waitAgentReachable` so the retry constants stay in lockstep): it calls
 * `setPeerId` + `performE2EHandshake` in a retry loop, so the E2E handshake's
 * `handshake:client-hello`/`agent-hello` frames route through the relay's
 * generic authenticated-message path (server.ts's `handleBinaryFrame`),
 * authorized by `mayRoute`'s same-account check — the SAME authorization
 * every other route frame in this file uses.
 */

/** Round-trip the control-plane `state.snapshot` RPC and assert a sane
 *  (`ok:true`) response — the cheap project verb the brief calls for,
 *  mirroring `gate-relay-restart.test.ts`'s own baseline/post checks (which
 *  use this exact RPC, not a project stream). */
async function assertSnapshot(app: RelayClient, label: string): Promise<void> {
  const requestId = `gate-account-trust-${label}`;
  const responseP = app.waitFor((m: any) => m.type === "response" && m.requestId === requestId, 8_000);
  app.sendEncrypted(createMessage("request", { requestId, method: "state.snapshot", params: { types: ["*"] } }));
  const res = (await responseP) as { ok?: boolean };
  expect(res.ok).toBe(true);
}

/** Bound to an OS-assigned port (0) so each (re)start avoids the same-port
 *  EADDRINUSE rebind window: on this dev box a just-closed listen socket stays
 *  bound (a LISTENING `netstat` entry for the old PID) for tens of seconds
 *  after `stop(true)` resolves. The stable client-facing address is the
 *  TcpForwarder's, wired up by `startRestartableRelay`. */
const RELAY_CONFIG = {
  port: 0,
  maxConnections: 100,
  rateLimitConnPerIp: 10,
  rateLimitMsgPerSec: 100,
  jsonRateLimitPerSec: 100,
  maxStreamsPerConnection: 1024,
  jsonRateLimitBurst: 200,
  clockSkewMs: 120_000,
  replayTtlMs: 300_000,
  pingIntervalMs: 30_000,
  pongTimeoutMs: 10_000,
  trustedProxyIps: [],
  logLevel: "error" as const,
  licenseApiUrl: "http://license-api.eval",
  relayInternalSecret: RELAY_INTERNAL_SECRET,
  licenseCacheMaxEntries: 1000,
};

const RELAY_DEPS = {
  licenseGate: {
    async verify(token: string, deviceId: string, _publicKeyBase64: string) {
      if (!token) return { ok: false as const, code: "LICENSE_INVALID" as const };
      return {
        ok: true as const,
        entry: { jti: `eval-jti-${deviceId}`, deviceId, userId: "eval-user", tier: "pro" as const, pk: _publicKeyBase64, revoked: false },
      };
    },
    async verifyAppToken(token: string) {
      if (!token) return { ok: false as const, code: "LICENSE_INVALID" as const };
      return {
        ok: true as const,
        entry: { jti: "eval-jti-app", deviceId: "app-eval-user", userId: "eval-user", tier: "pro" as const, pk: "eval-fake-app-pk", revoked: false },
      };
    },
  },
};

test("pair-free session: E2E handshake + control-plane round trip with no pair-request ever sent", async () => {
  const abDir = mkdtempSync(join(tmpdir(), "antgrid-gate-account-trust-"));
  const appIdentity = await generateAppIdentity();

  const { startServer } = await import("../../relay/src/server");
  const relay = startRestartableRelay(() => startServer(RELAY_CONFIG, RELAY_DEPS));
  const relayWsUrl = relay.url;
  const licenseApi: FakeLicenseApi = startFakeLicenseApi({
    accountDevices: [{ deviceId: appIdentity.deviceId, ed25519Pub: appIdentity.publicKeyBase64 }],
  });
  const auth = generateEvalAuth();
  const project = createTestProject("basic", { "__RELAY_URL__": relayWsUrl.replace(/\/ws$/, "") });

  let agent: AgentHandle | undefined;
  let app: RelayClient | undefined;
  try {
    agent = await spawnAgent({
      relayUrl: relayWsUrl,
      licenseApiUrl: licenseApi.url,
      abDir,
      projectDir: project.dir,
      auth,
      env: { ANTGRID_EVAL_TEST: "1" },
    });
    const deviceUuid = auth.deviceUuid;

    app = await RelayClient.connectAndAuth(relayWsUrl, {
      deviceType: "app",
      name: "gate-account-trust-app",
      deviceId: appIdentity.deviceId,
      identity: appIdentity,
    });

    // NEVER called: app.pairWith / a raw "pair-request" frame. Admission is
    // entirely relay same-account routing (Task 1) + bridge inventory trust
    // (Tasks 5-6).
    await handshakeWithoutPairing(app, deviceUuid, auth.ed25519Pub);

    await assertSnapshot(app, "pair-free-baseline");
  } finally {
    await app?.disconnect();
    await agent?.kill();
    relay.stop();
    licenseApi.stop();
    project.cleanup();
    try { rmSync(abDir, { recursive: true, force: true }); } catch {}
  }
}, 60_000);

test("relay restart, no re-pair: pair-free session re-establishes and the control-plane round trip succeeds again", async () => {
  const abDir = mkdtempSync(join(tmpdir(), "antgrid-gate-account-trust-restart-"));
  const appIdentity = await generateAppIdentity();

  const { startServer } = await import("../../relay/src/server");
  const relay = startRestartableRelay(() => startServer(RELAY_CONFIG, RELAY_DEPS));
  const relayWsUrl = relay.url; // stable forwarder URL, survives restarts
  const licenseApi: FakeLicenseApi = startFakeLicenseApi({
    accountDevices: [{ deviceId: appIdentity.deviceId, ed25519Pub: appIdentity.publicKeyBase64 }],
  });
  const auth = generateEvalAuth();
  const project = createTestProject("basic", { "__RELAY_URL__": relayWsUrl.replace(/\/ws$/, "") });

  let agent: AgentHandle | undefined;
  let app: RelayClient | undefined;
  try {
    agent = await spawnAgent({
      relayUrl: relayWsUrl,
      licenseApiUrl: licenseApi.url,
      abDir,
      projectDir: project.dir,
      auth,
      env: { ANTGRID_EVAL_TEST: "1" },
    });
    const deviceUuid = auth.deviceUuid;

    app = await RelayClient.connectAndAuth(relayWsUrl, {
      deviceType: "app",
      name: "gate-account-trust-restart-app",
      deviceId: appIdentity.deviceId,
      identity: appIdentity,
    });

    await handshakeWithoutPairing(app, deviceUuid, auth.ed25519Pub);
    await assertSnapshot(app, "restart-baseline");

    // Restart the relay on a FRESH port behind the same stable forwarder URL.
    // Neither the agent process nor `app` is touched here — the agent's own
    // bridge process notices the severed socket and redials the (unchanged)
    // forwarder URL on its jittered backoff entirely on its own.
    relay.restart();

    // Agent side, fully unattended: poll (no event exposed for "an agent
    // reconnected") until the restarted relay sees a live connection.
    const deadline = Date.now() + 30_000;
    let agentBack = false;
    while (Date.now() < deadline) {
      if (relay.connectionCount() >= 1) {
        agentBack = true;
        break;
      }
      await Bun.sleep(200);
    }
    expect(agentBack).toBe(true);

    // Phone side (mirrors gate-relay-restart.test.ts's HELPER GAP 2): the
    // eval RelayClient double has no built-in auto-reconnect, so this is a
    // deliberate, explicit stand-in for the app's own reconnect logic — still
    // no pair-request anywhere in this path.
    await app.reconnectAndAuth(relayWsUrl);
    await handshakeWithoutPairing(app, deviceUuid, auth.ed25519Pub);

    await assertSnapshot(app, "restart-post");
  } finally {
    await app?.disconnect();
    await agent?.kill();
    relay.stop();
    licenseApi.stop();
    project.cleanup();
    try { rmSync(abDir, { recursive: true, force: true }); } catch {}
  }
}, 90_000);

/**
 * Negative security control (restores coverage the deleted
 * auto-pair-membership.test.ts carried under the pairing ceremony: "a forged
 * sameAccount with no proof is rejected UNKNOWN_PHONE"). The account-trust
 * path that replaced pairing has the SAME requirement in different clothes: a
 * phone whose device id is absent from the account inventory has no proof of
 * membership at all, and admission must still be refused, not silently
 * granted.
 *
 * There is no typed rejection frame to await here — the relay's fake
 * `verifyAppToken` in this harness accepts any non-empty token and stamps
 * every device with the SAME account uid (see the file header comment), so
 * the WS connects and `mayRoute` authorizes routing regardless of inventory
 * membership; only the bridge's `TrustedPeersProvider`
 * (`resolvePhoneEd25519PubB64` in relay-client.ts) gates the E2E handshake,
 * and an unknown pubkey makes it drop the client-hello silently (no
 * agent-hello, no error frame) rather than reply with anything the phone
 * could distinguish from "not yet". So a bare handshake timeout on its own
 * would be indistinguishable from a startup race a retry would have absorbed
 * — the same race `handshakeWithoutPairing` exists to survive for a
 * genuinely-registered identity elsewhere in this file.
 *
 * That ambiguity is exactly what makes "no row was created" an insufficient
 * proof on its own: `spawnAgent` (harness.ts) only polls for the agent's
 * `api.port` file and returns — it does NOT wait for the agent's own relay
 * hello to land, so "no row" is equally consistent with "the agent's relay
 * slot wasn't even up yet" as with "this identity was refused". A CONTROL
 * identity — registered in the same account inventory, handshaked to
 * completion FIRST against this same agent process — rules that out: once the
 * control identity's row exists, the agent's relay slot is proven live and
 * admitting, so the forged identity's continued absence afterward can only be
 * refusal, not a slow agent. The control session is torn down before the
 * forged attempt starts (rather than left open) so there is no question of
 * the bridge's single-active-phone takeover (relay-client.ts's
 * `handleClientHello`, ~line 1123) confusing which identity's admission the
 * final assertions are about — the two attempts are sequenced, not
 * concurrent.
 *
 * The structural proof this is REJECTION rather than "the retry budget was
 * merely too short": the bridge creates a `paired-phones.json` row for a
 * phone ONLY after its transcript signature verifies against a KNOWN
 * identity (the `upsert` inside `handleClientHello`, gated behind the same
 * `resolved.pub` check that gaits agent-hello). An identity absent from every
 * trust source never reaches that line, no matter how many attempts land —
 * so asserting NO row was ever created, DURING a window when the SAME agent
 * demonstrably created one for a different identity, pins the failure to
 * admission, not to timing.
 */
test("app whose device id is absent from the account inventory cannot establish an E2E session (identity rejection, not a mere timeout)", async () => {
  const abDir = mkdtempSync(join(tmpdir(), "antgrid-gate-account-trust-forged-"));
  // The CONTROL identity — registered and handshaked successfully first, to
  // prove the agent is live and admitting during this test's window.
  const controlIdentity = await generateAppIdentity();
  // Deliberately generated but NEVER registered with the fake account
  // inventory below — no `startFakeLicenseApi({ accountDevices })` entry
  // references this identity anywhere.
  const forgedIdentity = await generateAppIdentity();

  // Plain startRelay, not startRestartableRelay like this file's other two
  // tests: neither leg here restarts the relay, so the restart-survival
  // machinery would be unused ceremony.
  const relay = await startRelay({ port: allocatePort() });
  const licenseApi: FakeLicenseApi = startFakeLicenseApi({
    accountDevices: [{ deviceId: controlIdentity.deviceId, ed25519Pub: controlIdentity.publicKeyBase64 }],
  });
  const auth = generateEvalAuth();
  const project = createTestProject("basic", { "__RELAY_URL__": relay.url.replace(/\/ws$/, "") });

  let agent: AgentHandle | undefined;
  let controlApp: RelayClient | undefined;
  let forgedApp: RelayClient | undefined;
  try {
    agent = await spawnAgent({
      relayUrl: relay.url,
      licenseApiUrl: licenseApi.url,
      abDir,
      projectDir: project.dir,
      auth,
      env: { ANTGRID_EVAL_TEST: "1" },
    });
    const deviceUuid = auth.deviceUuid;

    // 1) CONTROL: a registered identity is admitted on this same agent —
    // default (generous) retry budget, same as the file's other tests, since
    // this leg's whole point is proving a legitimate handshake succeeds here.
    controlApp = await RelayClient.connectAndAuth(relay.url, {
      deviceType: "app",
      name: "control-phone",
      deviceId: controlIdentity.deviceId,
      identity: controlIdentity,
    });
    await handshakeWithoutPairing(controlApp, deviceUuid, auth.ed25519Pub);
    expect(loadPairedPhones(abDir).has(controlIdentity.publicKeyBase64)).toBe(true);
    // Sequence, don't coexist: tear the control session down before the
    // forged attempt starts (see file-header note on single-active-phone
    // takeover).
    await controlApp.disconnect();
    controlApp = undefined;

    // 2) FORGED: an unregistered identity, attempted against the SAME
    // now-proven-live agent. A short, bounded retry budget — long enough to
    // rule out the legitimate startup race handshakeWithoutPairing's default
    // budget absorbs elsewhere in this file, short enough to keep this a fast
    // negative test (the control leg above already paid that startup cost).
    forgedApp = await RelayClient.connectAndAuth(relay.url, {
      deviceType: "app",
      name: "forged-phone",
      deviceId: forgedIdentity.deviceId,
      identity: forgedIdentity,
    });

    let caught: unknown;
    try {
      await handshakeWithoutPairing(forgedApp, deviceUuid, auth.ed25519Pub, {
        attempts: 5,
        perAttemptTimeoutMs: 1_000,
        gapMs: 200,
      });
    } catch (err) {
      caught = err;
    }
    expect(caught).toBeDefined();

    // No trust row was ever created for the forged identity — the handshake
    // never got far enough to be admitted, on any attempt. The control row
    // from step 1 still stands, so this absence means refusal, not "the
    // agent wasn't ready yet".
    expect(loadPairedPhones(abDir).has(forgedIdentity.publicKeyBase64)).toBe(false);
    expect(loadPairedPhones(abDir).has(controlIdentity.publicKeyBase64)).toBe(true);
  } finally {
    await controlApp?.disconnect();
    await forgedApp?.disconnect();
    await agent?.kill();
    relay.stop();
    licenseApi.stop();
    project.cleanup();
    try { rmSync(abDir, { recursive: true, force: true }); } catch {}
  }
}, 30_000);
