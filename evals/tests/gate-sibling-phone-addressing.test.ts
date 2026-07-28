import { test, expect } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  allocatePort,
  generateEvalAuth,
  spawnAgent,
  startRelay,
  startFakeLicenseApi,
  type AgentHandle,
  type FakeLicenseApi,
  type RelayHandle,
} from "../helpers/harness";
import { RelayClient, type PhoneIdentity } from "../helpers/relay-client";
import { createTestProject } from "../helpers/fixtures";
import { createMessage } from "../../bridge/src/protocol";

/**
 * Regression for the Phase A two-phone mis-addressing bug (spec 2026-07-24
 * single-active-phone): with two phones signed into ONE account, a bare
 * `peer-online` for the sibling used to overwrite the agent's `_peerId`, so the
 * agent sealed replies with the ACTIVE phone's keys but addressed them `to:` the
 * sibling. The active phone went deaf. Post-fix, only a verified handshake
 * repoints the address, so the active phone keeps receiving; a sibling's real
 * handshake then hands the session over.
 */

/** Generate a local Ed25519 identity for an app RelayClient (mirrors
 *  gate-account-trust.test.ts — the app key the agent pins via inventory). */
async function generateAppIdentity(): Promise<PhoneIdentity & { deviceId: string }> {
  const deviceId = crypto.randomUUID();
  const keyPair = await crypto.subtle.generateKey("Ed25519", true, ["sign", "verify"]);
  const pubRaw = await crypto.subtle.exportKey("raw", keyPair.publicKey as CryptoKey);
  const publicKeyBase64 = Buffer.from(pubRaw).toString("base64");
  const pkcs8Der = Buffer.from(await crypto.subtle.exportKey("pkcs8", keyPair.privateKey as CryptoKey));
  const privateKeySeed = Buffer.from(pkcs8Der.subarray(pkcs8Der.length - 32));
  return { deviceId, publicKeyBase64, privateKey: keyPair.privateKey as CryptoKey, privateKeySeed };
}

/** Drive the E2E handshake with NO pair-request (account-trust). Retries absorb
 *  the trusted-peers cache-warm and presence-fan-out startup races. */
async function handshakeWithoutPairing(app: RelayClient, agentDeviceId: string, agentEd25519Pub: string): Promise<void> {
  let lastErr: unknown;
  for (let i = 0; i < 25; i++) {
    try {
      app.setPeerId(agentDeviceId);
      await app.performE2EHandshake(agentDeviceId, 2_000, { agentEd25519Pub });
      return;
    } catch (err) {
      lastErr = err;
      await Bun.sleep(300);
    }
  }
  throw new Error(`pair-free handshake with ${agentDeviceId} failed: ${String(lastErr)}`);
}

/** Round-trip the control-plane state.snapshot RPC and assert ok:true. Throws
 *  (via waitFor timeout) if the agent addressed the reply to a different phone. */
async function assertSnapshot(app: RelayClient, label: string): Promise<void> {
  const requestId = `gate-sibling-${label}`;
  const responseP = app.waitFor((m: any) => m.type === "response" && m.requestId === requestId, 8_000);
  app.sendEncrypted(createMessage("request", { requestId, method: "state.snapshot", params: { types: ["*"] } }));
  const res = (await responseP) as { ok?: boolean };
  expect(res.ok).toBe(true);
}

test("a same-account sibling's presence does not steal addressing from the active phone; its handshake hands the session over", async () => {
  const port = allocatePort();
  const abDir = mkdtempSync(join(tmpdir(), "antgrid-gate-sibling-"));
  const phone1 = await generateAppIdentity();
  const phone2 = await generateAppIdentity();

  const relay: RelayHandle = await startRelay({ port });
  const licenseApi: FakeLicenseApi = startFakeLicenseApi({
    accountDevices: [
      { deviceId: phone1.deviceId, ed25519Pub: phone1.publicKeyBase64 },
      { deviceId: phone2.deviceId, ed25519Pub: phone2.publicKeyBase64 },
    ],
  });
  const auth = generateEvalAuth();
  const project = createTestProject("basic", { "__RELAY_URL__": `ws://localhost:${port}` });

  let agent: AgentHandle | undefined;
  let app1: RelayClient | undefined;
  let app2: RelayClient | undefined;
  try {
    agent = await spawnAgent({
      relayUrl: relay.url,
      licenseApiUrl: licenseApi.url,
      abDir,
      projectDir: project.dir,
      auth,
      env: { ANTGRID_EVAL_TEST: "1" },
    });
    const agentDeviceId = auth.deviceUuid;

    // Phone 1 becomes the active phone.
    app1 = await RelayClient.connectAndAuth(relay.url, {
      deviceType: "app", name: "gate-sibling-phone1", deviceId: phone1.deviceId, identity: phone1,
    });
    await handshakeWithoutPairing(app1, agentDeviceId, auth.ed25519Pub);
    await assertSnapshot(app1, "baseline"); // agent addresses phone 1

    // Phone 2 (same account) connects but does NOT handshake — pure presence.
    // The agent receives peer-online(phone2).
    app2 = await RelayClient.connectAndAuth(relay.url, {
      deviceType: "app", name: "gate-sibling-phone2", deviceId: phone2.deviceId, identity: phone2,
    });
    // Wait for all three sockets, then let the presence frame settle at the agent.
    const deadline = Date.now() + 10_000;
    while (Date.now() < deadline && relay.connectionCount() < 3) await Bun.sleep(100);
    expect(relay.connectionCount()).toBeGreaterThanOrEqual(3);
    await Bun.sleep(500);

    // CORE ASSERTION: phone 1 still receives its reply. Pre-fix this times out
    // (the agent addressed the sealed reply to phone 2).
    await assertSnapshot(app1, "after-sibling-presence");

    // Handoff: phone 2 now performs its own verified handshake and becomes the
    // active, addressed phone.
    await handshakeWithoutPairing(app2, agentDeviceId, auth.ed25519Pub);
    await assertSnapshot(app2, "handoff");
  } finally {
    await app1?.disconnect();
    await app2?.disconnect();
    await agent?.kill();
    relay.stop();
    licenseApi.stop();
    project.cleanup();
    try { rmSync(abDir, { recursive: true, force: true }); } catch {}
  }
}, 90_000);
