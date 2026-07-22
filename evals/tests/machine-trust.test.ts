// E2E machine-level trust (v3 stream data planes):
//   1. Pair ONE phone once against the CONTROL PLANE (bare deviceUuid).
//   2. Allow projA + projB for that phone (machine-level paired-phones store).
//   3. Drive `terminal:start` on the projA AND projB STREAMS → both succeed.
//   4. Drill into projC (NOT allowed) → control-plane project:start is rejected
//      NOT_ALLOWED; the phone gets no projC stream.
//   5. Stop projB, then issue control-plane `project:start projB` → re-opens as a
//      fresh stream (stream-ready) and re-advertises running:true.
//   6. Control-plane `project:start projC` (un-allowed) → control:result
//      `error.code === "NOT_ALLOWED"`; no core created, never advertised.
//
// v3 migration (behaviour unchanged, transport changed): there are no per-project
// relay sockets. The phone keeps ONE socket + ONE session; each project is a
// STREAM (design §7). The allowlist gate (paired-phones store) is byte-for-byte
// the v2 gate — this test only moves project verbs off dead compound
// `deviceUuid.projectId` sockets onto sealed `{ s, m }` stream envelopes.
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

/** Resolve the advertised streamId for `projectId` from a fresh advert. */
async function streamFor(app: RelayClient, projectId: string): Promise<string> {
  await app.pullStateSnapshot();
  return firstProjectStream(app, projectId, 8_000);
}

/** Drive a deterministic terminal ON A STREAM and collect output for a marker. */
async function driveTerminal(app: RelayClient, streamId: string, terminalId: string, marker: string): Promise<string> {
  const outputs: string[] = [];
  const collect = (async () => {
    const deadline = Date.now() + 6_000;
    while (Date.now() < deadline) {
      try {
        const m = await app.waitForStreamAbType(streamId, "terminal:output", deadline - Date.now());
        if ((m as any).terminalId === terminalId) outputs.push((m as any).data);
        if (outputs.join("").includes(marker)) return;
      } catch {
        return;
      }
    }
  })();
  app.sendOnStream(
    streamId,
    createMessage("terminal:start", {
      terminalId,
      name: terminalId,
      command: process.platform === "win32" ? "cmd.exe" : "bash",
      args: process.platform === "win32" ? ["/c", `echo ${marker}`] : ["-c", `echo ${marker}`],
    } as never),
  );
  await collect;
  return outputs.join("");
}

test("machine trust: pair once, allow two, drive two streams, reject a third, on-demand start", async () => {
  const accountKp = generateKeyPairSync("ed25519");
  const accountPubB64 = rawEdPubB64(accountKp.publicKey);
  const env = await setupPairFlowTestEnv({ accountPeerKeys: [accountPubB64] });

  const projBdir = createTestProject("basic", { "__RELAY_URL__": env.relay.url.replace(/\/ws$/, "") });
  const projCdir = createTestProject("basic", { "__RELAY_URL__": env.relay.url.replace(/\/ws$/, "") });

  let cp: RelayClient | null = null;
  try {
    const relayUrl = env.relay.url;
    const deviceUuid = env.agent.deviceId;
    const agentEd25519Pub = env.agent.ed25519Pubkey;

    const projA = env.projectId;
    const projB = computeProjectId(projBdir.dir);
    const projC = computeProjectId(projCdir.dir);

    // projB + projC exist in the host catalog (opened remote via loopback).
    expect((await loopbackControl(env.abDir, { id: "open-b", type: "project:open", projectId: projB, projectPath: projBdir.dir, mode: "remote" })).ok).toBe(true);
    expect((await loopbackControl(env.abDir, { id: "open-c", type: "project:open", projectId: projC, projectPath: projCdir.dir, mode: "remote" })).ok).toBe(true);

    // === STEP 1: pair ONCE against the control plane (account-membership) ===
    cp = await RelayClient.connectAndAuth(relayUrl, { deviceType: "app", name: "eval-phone-cp" });
    const phoneIdentity = cp.exportIdentity();
    const cpPair = await cp.pairWith(deviceUuid, { timeoutMs: 10_000, accountKey: { pubB64: accountPubB64, privateKey: accountKp.privateKey } });
    cp.setPeerId(cpPair.peerId);
    await cp.performE2EHandshake(deviceUuid, 10_000, { agentEd25519Pub });

    // === STEP 2: allow projA + projB (fail-closed store) ===
    const phonePubkey = phoneIdentity.publicKeyBase64;
    const store = loadPairedPhones(env.abDir);
    expect(store.has(phonePubkey)).toBe(true);
    store.allowProject(phonePubkey, projA);
    store.allowProject(phonePubkey, projB);
    await Bun.sleep(400);

    // === STEP 3: drive terminal:start on the projA AND projB streams ===
    const streamA = await streamFor(cp, projA);
    const outA = await driveTerminal(cp, streamA, "tA", "ALLOW_A");
    expect(outA).toContain("ALLOW_A");

    const streamB = await streamFor(cp, projB);
    const outB = await driveTerminal(cp, streamB, "tB", "ALLOW_B");
    expect(outB).toContain("ALLOW_B");

    // === STEP 4: projC (NOT allowed) → control-plane drill-in refused ===
    // projC is not on the allowlist, so the phone can't even open its stream:
    // project:start returns control:result NOT_ALLOWED, and projC never appears
    // in the (allowlist-filtered) advert.
    cp.sendEncrypted(createMessage("project:start", { projectId: projC }));
    const denyC = await cp.waitForAbType("control:result", 8_000);
    expect(denyC.ok).toBe(false);
    expect((denyC as any).error.code).toBe("NOT_ALLOWED");

    // === STEP 5: stop projB, then control-plane project:start projB ===
    expect((await loopbackControl(env.abDir, { id: "stop-b", type: "project:stop", projectId: projB })).ok).toBe(true);
    const streamB2 = await cp.openProjectStream(projB, 12_000); // start-on-open → fresh stream-ready
    const outB2 = await driveTerminal(cp, streamB2, "tB2", "RESTART_B");
    expect(outB2).toContain("RESTART_B");

    // === STEP 6: projC still never advertised ===
    await cp.pullStateSnapshot();
    const finalAdvert = await cp.waitForAbType("agent:projects", 8_000);
    expect(finalAdvert.projects.map((p: any) => p.projectId)).not.toContain(projC);
  } finally {
    await cp?.disconnect();
    await env.teardown();
    try { projBdir.cleanup(); } catch { /* Windows EBUSY teardown race */ }
    try { projCdir.cleanup(); } catch { /* Windows EBUSY teardown race */ }
  }
}, 120_000);
