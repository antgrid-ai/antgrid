// E2E control-plane tool discovery (Task I2):
//   Prove that a paired app RECEIVES `agent:tools` over a real relay handshake,
//   on the control plane, WITHOUT opening any per-project data-plane session.
//
// Why this eval exists: the bridge unit tests use FakeAgentTransport (keys always
// present) and so never exercise the real E2E key-establishment timing over a
// relay transport. `agent:tools` is in REPLAY_TYPES (welcome-replay) and is
// re-emitted on re-advertise; this is the ONLY test that closes the
// delivery-timing risk by asserting a paired app actually receives the frame.
//
// `agent:tools` is MACHINE-LEVEL — it is not a project verb, so the Phase B
// allowlist gate does NOT apply. The phone receives it on handshake-complete
// without any `allowProject`. We therefore assert ONLY on `agent:tools` to keep
// the test focused and avoid the allowlist trap. The agent-under-test may or may
// not have a real KNOWN_AGENTS bin on PATH, so we assert the frame ARRIVES with
// an array payload rather than a specific tool being present.
//
// Known Windows test noise (NOT failures): fs.watch EPERM/EBUSY on teardown,
// temp-dir cleanup races. Judge by pass/fail counts.
import { test, expect } from "bun:test";
import { generateKeyPairSync } from "node:crypto";
import { setupPairFlowTestEnv } from "../helpers/test-env";
import { RelayClient } from "../helpers/relay-client";

/** Raw 32-byte base64 of an Ed25519 SPKI public key (matches the agent's
 *  account-peer-key encoding). */
function rawEdPubB64(pub: import("node:crypto").KeyObject): string {
  const der = pub.export({ format: "der", type: "spki" });
  return Buffer.from(der.subarray(der.length - 32)).toString("base64");
}

test("control plane delivers agent:tools to a paired app over a real relay handshake", async () => {
  // Account-membership key — the QR-less control-plane admission anchor.
  const accountKp = generateKeyPairSync("ed25519");
  const accountPubB64 = rawEdPubB64(accountKp.publicKey);

  const env = await setupPairFlowTestEnv({ accountPeerKeys: [accountPubB64] });

  let cp: RelayClient | null = null;
  try {
    const relayUrl = env.relay.url;
    const deviceUuid = env.agent.deviceId;        // control-plane regId (bare deviceUuid)
    const agentEd25519Pub = env.agent.ed25519Pubkey; // pinned agent key for E2E verify

    // Pair ONCE against the control plane (bare deviceUuid) via the account-
    // membership (QR-less) path, then complete the E2E handshake. No per-project
    // data plane is ever opened — discovery must happen on the control plane.
    cp = await RelayClient.connectAndAuth(relayUrl, { deviceType: "app", name: "eval-phone-cp" });
    // Retry the spawn race (agent writes api.port before its relay hello lands →
    // typed AGENT_OFFLINE, socket stays open).
    for (let i = 0; i < 50; i++) {
      try {
        const cpPair = await cp.pairWith(deviceUuid, {
          timeoutMs: 8_000,
          accountKey: { pubB64: accountPubB64, privateKey: accountKp.privateKey },
        });
        cp.setPeerId(cpPair.peerId);
        await cp.performE2EHandshake(deviceUuid, 10_000, { agentEd25519Pub });
        break;
      } catch {
        if (cp.isClosed) await cp.reconnectAndAuth(relayUrl);
        await Bun.sleep(150);
      }
    }

    // Pull the control-plane snapshot (re-emits agent:tools) rather than racing
    // the de-duped live handshake push (v3 MessageBus payload-equality dedup).
    await cp.pullStateSnapshot();
    const toolsAdvert = await cp.waitForAbType("agent:tools", 10_000);

    expect(toolsAdvert.type).toBe("agent:tools");
    expect(Array.isArray((toolsAdvert as any).tools)).toBe(true);
    // Each entry, when present, is { tool, path } — sanity-check the shape
    // without requiring any specific tool to be installed on the test machine.
    for (const t of (toolsAdvert as any).tools) {
      expect(typeof t.tool).toBe("string");
      expect(typeof t.path).toBe("string");
    }
  } finally {
    await cp?.disconnect();
    await env.teardown();
  }
}, 120_000);
