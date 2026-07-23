// E2E v3 multi-STREAM coexistence (design §7 — one socket, project multiplexing):
//   ONE phone holds ONE relay socket and ONE sealed session. The machine control
//   plane plus two project data planes are STREAMS inside that single session
//   (`{ s, m }` envelopes), not separate sockets. This replaces the v2 "one phone
//   pubkey, N per-registration sockets via sub-deviceIds" model — sub-deviceIds
//   and compound `deviceUuid.projectId` registrations are gone (design §7.4).
//
// Asserts: (1) traffic on each project stream comes back tagged with THAT stream's
// id — the streams are isolated; (2) exactly ONE relay connection exists per side
// (agent + phone = 2 total) — the whole point of v3 multiplexing.
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
import { firstProjectStream } from "../support/stream";

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

test("one phone socket carries control + two project streams, isolated, on a single relay connection", async () => {
  const accountKp = generateKeyPairSync("ed25519");
  const accountPubB64 = rawEdPubB64(accountKp.publicKey);
  const env = await setupPairFlowTestEnv({ accountPeerKeys: [accountPubB64] });
  // projA is the firstProject (opened remote at boot). projB is a second project.
  const projBdir = createTestProject("basic", { "__RELAY_URL__": env.relay.url.replace(/\/ws$/, "") });
  let app: RelayClient | null = null;
  try {
    const relayUrl = env.relay.url;
    const deviceUuid = env.agent.deviceId;
    const agentEd25519Pub = env.agent.ed25519Pubkey;
    const projA = env.projectId;
    const projB = computeProjectId(projBdir.dir);

    // Open projB remote so it's in the host catalog, then STOP it so the later
    // project:start exercises the genuine drill-in path (a fresh remote open +
    // register), not the idempotent already-running branch. Both branches emit
    // stream-ready — the idempotent one re-publishes it because the re-advert
    // can be dedup-suppressed for a reconnecting phone.
    expect((await loopbackControl(env.abDir, {
      id: "open-b", type: "project:open", projectId: projB, projectPath: projBdir.dir, mode: "remote",
    })).ok).toBe(true);
    expect((await loopbackControl(env.abDir, { id: "stop-b", type: "project:stop", projectId: projB })).ok).toBe(true);

    // ONE socket, ONE session — pair via the QR-less account-membership proof.
    app = await RelayClient.connectAndAuth(relayUrl, { deviceType: "app", name: "eval-phone" });
    const phoneIdentity = app.exportIdentity();
    for (let i = 0; i < 50; i++) {
      try {
        const r = await app.pairWith(deviceUuid, { timeoutMs: 8_000, accountKey: { pubB64: accountPubB64, privateKey: accountKp.privateKey } });
        app.setPeerId(r.peerId);
        await app.performE2EHandshake(deviceUuid, 10_000, { agentEd25519Pub });
        break;
      } catch {
        if (app.isClosed) await app.reconnectAndAuth(relayUrl);
        await Bun.sleep(150);
      }
    }

    // Allow both projects for this phone (fail-closed allowlist), then let the
    // host's fs.watch reload.
    const store = loadPairedPhones(env.abDir);
    store.allowProject(phoneIdentity.publicKeyBase64, projA);
    store.allowProject(phoneIdentity.publicKeyBase64, projB);
    await Bun.sleep(400);
    await app.pullStateSnapshot();

    // projA (already running) → streamId from the advert; projB → project:start
    // opens its stream (design §7.4). Both streams live in the ONE session.
    const streamA = await firstProjectStream(app, projA, 10_000);
    const streamB = await app.openProjectStream(projB, 12_000);
    expect(streamA).not.toBe(streamB);

    // Isolation: a verb on each stream returns tagged with THAT stream's id.
    app.sendOnStream(streamA, createMessage("file:read", { projectId: projA, path: "README.md" }));
    app.sendOnStream(streamB, createMessage("file:read", { projectId: projB, path: "README.md" }));
    const contentA = await app.waitForStreamAbType(streamA, "file:content", 8_000);
    const contentB = await app.waitForStreamAbType(streamB, "file:content", 8_000);
    expect((contentA as { _streamId?: string })._streamId).toBe(streamA);
    expect((contentB as { _streamId?: string })._streamId).toBe(streamB);
    expect(contentA.path).toBe("README.md");
    expect(contentB.path).toBe("README.md");

    // The v3 point: exactly ONE relay connection per side (agent + phone = 2),
    // even though three logical planes (control + projA + projB) are in flight.
    expect(env.relay.connectionCount()).toBe(2);
    // The agent multiplexes both project streams over its single socket.
    expect(env.relay.streamCount()).toBeGreaterThanOrEqual(2);
  } finally {
    await app?.disconnect();
    await env.teardown();
    try { projBdir.cleanup(); } catch { /* Windows EBUSY teardown race */ }
  }
}, 120_000);
