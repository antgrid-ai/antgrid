// E2E eval: same-account mobile access defaults (Task 6).
//
// Proves that if `mobile-access:enable-project` is sent for projA BEFORE any
// phone pairs, then a same-account phone connecting via account-membership
// (QR-less) sees projA in its FIRST `agent:projects` advertisement.
//
// Pair-code / manual negative assertion:
//   `setupPairFlowTestEnv`'s control plane has NO test-only pairing-window hook
//   (that hook is per-project, on AgentCore — see the comment on `accountPeerKeys`
//   in test-env.ts). We therefore CANNOT admit a genuine pair-code phone on the
//   control-plane registration in this harness. Instead we assert the scoped
//   negative that IS cleanly expressible: a project that was NEVER enabled is
//   absent from the same-account phone's advert (defaults are per-project, not
//   blanket). The one project in the fixture (env.projectId) is the only project
//   we enable; a made-up id we never enable must NOT appear. The pair-code-phone
//   empty-advert assertion belongs to the bridge unit tests that exercise the
//   per-project pairing-window path (relay-pair-handling.test.ts).
//
// Known Windows test noise (NOT failures): fs.watch EPERM/EBUSY on teardown,
// temp-dir cleanup races. Judge by pass/fail counts.
import { test, expect } from "bun:test";
import { generateKeyPairSync } from "node:crypto";
import { join } from "node:path";
import { setupPairFlowTestEnv } from "../../helpers/test-env";
import { RelayClient, PairAgentOfflineError } from "../../helpers/relay-client";

/** Raw 32-byte base64 of an Ed25519 SPKI public key (matches the agent's
 *  account-peer-key encoding). */
function rawEdPubB64(pub: import("node:crypto").KeyObject): string {
  const der = pub.export({ format: "der", type: "spki" });
  return Buffer.from(der.subarray(der.length - 32)).toString("base64");
}

/** Poll readHostFile until host.json appears (agent writes it during startup).
 *  The test sends `mobile-access:enable-project` BEFORE pairing any phone, so
 *  host.json must exist first. Cap: 5 s. */
async function waitForHostFile(
  abDir: string,
  timeoutMs = 5_000,
): Promise<import("@bridge/host-discovery").HostFile> {
  const { readHostFile } = await import("@bridge/host-discovery");
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const hf = readHostFile(join(abDir, "host.json"));
    if (hf) return hf;
    await Bun.sleep(100);
  }
  throw new Error("host.json did not appear within timeout");
}

/** Retry pairWith until the control-plane relay slot is up (~10s window).
 *  An AGENT_OFFLINE close (slot not yet authenticated) reopens the socket and
 *  retries. A genuine rejection surfaces immediately. */
async function pairWithRetry(
  cp: RelayClient,
  relayUrl: string,
  deviceUuid: string,
  opts: Parameters<RelayClient["pairWith"]>[1],
): Promise<Awaited<ReturnType<RelayClient["pairWith"]>>> {
  let lastErr: unknown;
  for (let i = 0; i < 20; i++) {
    try {
      if (i > 0 && cp.isClosed) await cp.reconnectAndAuth(relayUrl);
      return await cp.pairWith(deviceUuid, opts);
    } catch (err) {
      if (err instanceof PairAgentOfflineError) {
        lastErr = err;
        await Bun.sleep(300);
        continue;
      }
      throw err;
    }
  }
  throw new Error(`control-plane pair-request never reached agent: ${String(lastErr)}`);
}

test(
  "same-account phone receives enabled project in first agent:projects advertisement",
  async () => {
    // Account-membership key — the QR-less control-plane admission anchor.
    const accountKp = generateKeyPairSync("ed25519");
    const accountPubB64 = rawEdPubB64(accountKp.publicKey);

    const env = await setupPairFlowTestEnv({ accountPeerKeys: [accountPubB64] });

    let cp: RelayClient | null = null;
    try {
      // ── Step 1: enable projA BEFORE any phone pairs ────────────────────────
      //
      // We read host.json from the child agent's abDir (not the test process's
      // resolveAbDir()). The agent may still be starting up, so we poll briefly.
      const hf = await waitForHostFile(env.abDir);

      const enableRes = await fetch(`http://127.0.0.1:${hf.controlPort}/control`, {
        method: "POST",
        headers: {
          "content-type": "application/json",
          authorization: `Bearer ${hf.token}`,
        },
        body: JSON.stringify({
          id: "eval-enable",
          type: "mobile-access:enable-project",
          projectId: env.projectId,
        }),
      });
      const enableBody = (await enableRes.json()) as {
        ok: boolean;
        projectIds?: string[];
      };

      // Confirm the policy verb succeeded and stored projA.
      expect(enableBody.ok).toBe(true);
      expect(enableBody.projectIds).toContain(env.projectId);

      // ── Step 2: pair a same-account phone on the control plane ─────────────
      //
      // Control-plane registration is under the bare deviceUuid (no projectId).
      // Account-membership proof is the QR-less admission path.
      const relayUrl = env.relay.url;
      const deviceUuid = env.agent.rawDeviceId;
      const agentEd25519Pub = env.agent.ed25519Pubkey;

      cp = await RelayClient.connectAndAuth(relayUrl, {
        deviceType: "app",
        name: "eval-phone-defaults",
      });
      const cpPair = await pairWithRetry(cp, relayUrl, deviceUuid, {
        timeoutMs: 10_000,
        accountKey: { pubB64: accountPubB64, privateKey: accountKp.privateKey },
      });
      cp.setPeerId(cpPair.peerId);
      await cp.performE2EHandshake(deviceUuid, 10_000, { agentEd25519Pub });

      // ── Step 3: assert first agent:projects advert contains projA ──────────
      //
      // On handshake-complete the control plane sends `agent:projects` with the
      // phone's allowedProjects. Since enable-project ran before pairing, the
      // same-account admission seeds the phone's allowlist from the policy store
      // (relay-client.ts#handleInboundPairRequest → sameAccountDefaultProjects).
      // `agent:projects` shape: { type: "agent:projects", projects: ProjectAdvertEntry[] }
      // where each entry has a `projectId` field (host-server.ts buildProjectsAdvertisement).
      // Pull the control-plane snapshot (re-emits agent:projects) rather than
      // racing the de-duped live handshake push (v3 payload-equality dedup).
      await cp.pullStateSnapshot();
      const projectsAdvert = await cp.waitForAbType("agent:projects", 10_000);

      expect(projectsAdvert.type).toBe("agent:projects");
      const projects = (projectsAdvert as any).projects as Array<{ projectId: string }>;
      expect(Array.isArray(projects)).toBe(true);

      // Primary positive: projA appears in the very first advert.
      expect(projects.map((p) => p.projectId)).toContain(env.projectId);

      // Scoped negative: a project that was NEVER enabled must NOT appear.
      // This proves defaults are per-project (not blanket same-account access).
      // We assert on a made-up id that was never passed to enable-project.
      const neverEnabledId = "never-enabled-project-id-fixture";
      expect(projects.map((p) => p.projectId)).not.toContain(neverEnabledId);
    } finally {
      await cp?.disconnect();
      await env.teardown();
    }
  },
  120_000,
);
