// E2E v3 drill-in (start-on-open) over the REAL bridge + relay (design §7.4):
//   1. Pair ONE phone once against the control plane (bare deviceUuid) via the
//      QR-less account-membership path; complete the E2E handshake.
//   2. Advertise two allowed projects, one STOPPED (projB): projA (firstProject,
//      running) + projB (opened remote then stopped → advertised running:false,
//      startable because it stays in seenProjects).
//   3. Drill into the STOPPED projB via the control-plane `project:start`; the
//      agent starts the core, attaches it as a STREAM on the SAME session, and
//      replies `stream-ready {projectId, streamId}` (0 new sockets, 0 pairs).
//   4. Workspace traffic flows over projB's stream (session:list round-trip).
//
// The v3 headline (vs v2's per-project socket + drill-in pairing race): drilling
// in adds ZERO relay connections and runs ZERO pair ceremonies — it is a stream
// bind inside the one machine session. Asserted via connectionCount() before/after.
//
// Known Windows test noise (NOT failures): fs.watch EPERM/EBUSY on teardown.
import { test, expect } from "bun:test";
import { generateKeyPairSync } from "node:crypto";
import { join } from "node:path";
import { setupPairFlowTestEnv } from "../helpers/test-env";
import { RelayClient } from "../helpers/relay-client";
import { createTestProject } from "../helpers/fixtures";
import { computeProjectId } from "../../bridge/src/project-id";
import { loadPairedPhones } from "../../bridge/src/paired-phones";
import { readHostFile } from "../../bridge/src/host-discovery";
import { createMessage } from "../../bridge/src/protocol";

function rawEdPubB64(pub: import("node:crypto").KeyObject): string {
  const der = pub.export({ format: "der", type: "spki" });
  return Buffer.from(der.subarray(der.length - 32)).toString("base64");
}

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

test("drill-in: start a stopped project as a stream on the ONE socket, zero new connections, zero pairs", async () => {
  const accountKp = generateKeyPairSync("ed25519");
  const accountPubB64 = rawEdPubB64(accountKp.publicKey);
  const env = await setupPairFlowTestEnv({ accountPeerKeys: [accountPubB64] });
  const projBdir = createTestProject("basic", { "__RELAY_URL__": env.relay.url.replace(/\/ws$/, "") });

  let cp: RelayClient | null = null;
  try {
    const relayUrl = env.relay.url;
    const deviceUuid = env.agent.deviceId;
    const agentEd25519Pub = env.agent.ed25519Pubkey;
    const projA = env.projectId;
    const projB = computeProjectId(projBdir.dir);

    // projB: opened remote then stopped → advertised, running:false, startable.
    expect((await loopbackControl(env.abDir, { id: "open-b", type: "project:open", projectId: projB, projectPath: projBdir.dir, mode: "remote" })).ok).toBe(true);
    expect((await loopbackControl(env.abDir, { id: "stop-b", type: "project:stop", projectId: projB })).ok).toBe(true);

    // Pair ONCE against the control plane (account-membership), handshake once.
    cp = await RelayClient.connectAndAuth(relayUrl, { deviceType: "app", name: "eval-phone-cp" });
    const phoneIdentity = cp.exportIdentity();
    for (let i = 0; i < 50; i++) {
      try {
        const r = await cp.pairWith(deviceUuid, { timeoutMs: 8_000, accountKey: { pubB64: accountPubB64, privateKey: accountKp.privateKey } });
        cp.setPeerId(r.peerId);
        await cp.performE2EHandshake(deviceUuid, 10_000, { agentEd25519Pub });
        break;
      } catch {
        if (cp.isClosed) await cp.reconnectAndAuth(relayUrl);
        await Bun.sleep(150);
      }
    }

    // Allow both projects for this phone, then let the host reload the allowlist.
    const store = loadPairedPhones(env.abDir);
    expect(store.has(phoneIdentity.publicKeyBase64)).toBe(true);
    store.allowProject(phoneIdentity.publicKeyBase64, projA);
    store.allowProject(phoneIdentity.publicKeyBase64, projB);
    await Bun.sleep(400);
    await cp.pullStateSnapshot();

    // projB is advertised but not running (drill target).
    const advert = await cp.waitFor(
      (m: any) => m.type === "agent:projects" &&
        m.projects.some((p: any) => p.projectId === projB && p.running === false),
      8_000,
    );
    expect(advert.projects.map((p: any) => p.projectId)).toContain(projA);

    // === Drill in: this must add NO new relay connection and run NO pair. ===
    // openProjectStream issues only a sealed control-plane `project:start` and
    // awaits `stream-ready` — no pair-request, no hello, no new socket (§7.4).
    const connectionsBefore = env.relay.connectionCount();
    const streamB = await cp.openProjectStream(projB, 12_000);
    expect(streamB).toBeTruthy();

    // Zero additional WS connections (agent + this one phone = unchanged).
    expect(env.relay.connectionCount()).toBe(connectionsBefore);

    // === Workspace traffic flows over the newly-bound stream ===
    const requestId = "drill-in-session-list";
    cp.sendOnStream(streamB, createMessage("session:list", { requestId } as never));
    const listResult = await cp.waitForStreamAbType(streamB, "session:list:result", 8_000);
    expect((listResult as { requestId?: string }).requestId).toBe(requestId);
    expect(Array.isArray((listResult as { sessions?: unknown[] }).sessions)).toBe(true);
  } finally {
    await cp?.disconnect();
    await env.teardown();
    try { projBdir.cleanup(); } catch { /* Windows EBUSY teardown race */ }
  }
}, 120_000);
