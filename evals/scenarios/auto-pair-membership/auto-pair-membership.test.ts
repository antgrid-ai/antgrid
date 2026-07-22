import { describe, test, expect } from "bun:test";
import { generateKeyPairSync, type KeyObject } from "node:crypto";
import {
  generateEvalAuth,
  spawnAgent,
  startFakeLicenseApi,
  startRelay,
  type AgentHandle,
  type FakeLicenseApi,
  type RelayHandle,
} from "../../helpers/harness";
import { createTestProject, type TestProject } from "../../helpers/fixtures";
import { RelayClient } from "../../helpers/relay-client";
import { mkdtempSync, rmSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

/**
 * Account-membership auto-pair E2E (Gap A regression).
 *
 * The bridge admits a QR-less ("same-account") pair-request ONLY when it carries
 * a cryptographic membership proof: an Ed25519 signature over the pair-request
 * transcript by an `accountDevicePubkey` that is BOTH (a) valid and (b) present
 * in the account's live enrolled-app-device key set, fetched by the agent over
 * its OWN Bearer/TLS channel (`GET /account/devices/me/peers`). The relay's
 * `sameAccount` stamp is no longer trusted — a malicious relay cannot forge the
 * proof (see `bridge/src/relay-client.ts#handleInboundPairRequest`).
 *
 * Option B harness wiring: rather than stand up a full Postgres-backed web, the
 * agent runs against the eval fake license API, which now also serves a KNOWN
 * `/account/devices/me/peers` key set (see `startFakeLicenseApi`).
 *
 * Two cases, each against its OWN fresh (unpaired) agent so the relay forwards
 * the pair-request and the agent's admission logic is what decides:
 *
 *   1. SUCCESS   — valid membership proof for a key the (fake) web returns →
 *                  auto-pair succeeds (pair-approval, NO pairCode used).
 *   2. REJECTION — a forged `sameAccount: true` with NO proof → the agent
 *                  rejects with `UNKNOWN_PHONE`. A forged same-account claim
 *                  MUST NOT auto-pair (the security regression for Gap A).
 */

interface Env {
  relay: RelayHandle;
  agent: AgentHandle;
  project: TestProject;
  abDir: string;
  licenseApi: FakeLicenseApi;
  registrationId: string;
  accountKey: { pubB64: string; privateKey: KeyObject };
  teardown(): Promise<void>;
}

let portCursor = 19_600 + Math.floor(Math.random() * 200);

/**
 * Spawn a fresh agent whose account enrolls a single app-device key (returned by
 * the fake `/account/devices/me/peers`). The matching private key signs the
 * membership proof.
 */
async function setupEnv(): Promise<Env> {
  const ed = generateKeyPairSync("ed25519");
  const accountPubB64 = Buffer.from(
    ed.publicKey.export({ format: "der", type: "spki" }).subarray(-32),
  ).toString("base64");
  const accountKey = { pubB64: accountPubB64, privateKey: ed.privateKey };

  const relayPort = portCursor++;
  const abDir = mkdtempSync(join(tmpdir(), "antgrid-eval-home-"));
  const relay = await startRelay({ port: relayPort, pairRequestTimeoutMs: 15_000 });
  const licenseApi = startFakeLicenseApi({ accountPeerKeys: [accountPubB64] });
  const auth = generateEvalAuth();
  const project = createTestProject("basic", {
    "__RELAY_URL__": `ws://localhost:${relayPort}`,
  });

  const agent = await spawnAgent({
    relayUrl: relay.url,
    licenseApiUrl: licenseApi.url,
    abDir,
    projectDir: project.dir,
    auth,
  });

  // v3: the agent registers ONE socket as the bare deviceUuid; the phone pairs
  // against it directly (compound deviceUuid.projectId registrations are gone).
  const registrationId = auth.deviceUuid;

  return {
    relay,
    agent,
    project,
    abDir,
    licenseApi,
    registrationId,
    accountKey,
    async teardown() {
      await agent.kill();
      relay.stop();
      licenseApi.stop();
      project.cleanup();
      try { rmSync(abDir, { recursive: true, force: true }); } catch {}
    },
  };
}

/**
 * Drive a pair-request with retry to absorb the agent-startup race. An early
 * pair-request (agent's per-project relay slot not yet authenticated) is routed
 * nowhere and the relay fail-fasts by CLOSING the app socket (`AGENT_OFFLINE`).
 * That close leaves the socket dead, so — like the harness `pairWithRetry` — we
 * must re-establish a live authenticated socket before retrying, or every retry
 * sends into the dead socket and never reaches the (now-up) agent. A real
 * admission rejection (UNKNOWN_PHONE) is NOT retryable and surfaces immediately.
 */
async function pairWithRetry(
  app: RelayClient,
  relayUrl: string,
  registrationId: string,
  opts: Parameters<RelayClient["pairWith"]>[1],
): Promise<any> {
  let lastErr: unknown;
  // ~10s window (fast-fails are cheap): the per-project relay slot can take
  // several seconds to authenticate under eval load, and the rejection path can
  // only surface UNKNOWN_PHONE once the slot is up to evaluate the proof.
  for (let i = 0; i < 20; i++) {
    try {
      if (i > 0 && app.isClosed) await app.reconnectAndAuth(relayUrl);
      return await app.pairWith(registrationId, opts);
    } catch (err) {
      const m = String(err);
      if (!m.includes("AGENT_OFFLINE") && !m.includes("closed") && !m.includes("Closed")) {
        throw err;
      }
      lastErr = err;
      await Bun.sleep(300);
    }
  }
  throw new Error(`pair-request never reached agent: ${String(lastErr)}`);
}

describe("auto-pair via account-membership proof", () => {
  test("valid membership proof auto-pairs without a pairCode", async () => {
    const env = await setupEnv();
    try {
      const app = await RelayClient.connectAndAuth(env.relay.url, {
        deviceType: "app",
        name: "member-phone",
      });
      try {
        const result = await pairWithRetry(app, env.relay.url, env.registrationId, {
          accountKey: env.accountKey,
          timeoutMs: 8_000,
        });
        // pairWith resolves only on `pair-approval`; reaching here proves the
        // agent admitted us via the membership proof (no pairCode presented).
        expect(result.peerId).toBe(env.registrationId);
      } finally {
        await app.disconnect();
      }
    } finally {
      await env.teardown();
    }
  }, 30_000);

  test("forged sameAccount with NO proof is rejected (UNKNOWN_PHONE)", async () => {
    const env = await setupEnv();
    try {
      const attacker = await RelayClient.connectAndAuth(env.relay.url, {
        deviceType: "app",
        name: "forged-phone",
      });
      try {
        // Forge `sameAccount: true` but present NO membership proof and NO
        // pairCode. The agent must reject with UNKNOWN_PHONE (it no longer trusts
        // the relay's sameAccount stamp). pairWith throws on `pair-rejected`.
        let caught: Error | undefined;
        try {
          await pairWithRetry(attacker, env.relay.url, env.registrationId, {
            forgeSameAccount: true,
            timeoutMs: 8_000,
          });
        } catch (err) {
          caught = err as Error;
        }

        expect(caught).toBeDefined();
        expect(caught!.message).toContain("rejected");
        expect(caught!.message).toContain("UNKNOWN_PHONE");
      } finally {
        await attacker.disconnect();
      }
    } finally {
      await env.teardown();
    }
  }, 30_000);
});
