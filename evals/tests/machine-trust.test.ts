// E2E machine-level authorization (v3 stream data planes):
//   1. setupTestEnv admits ONE app once against the CONTROL PLANE (bare
//      deviceUuid) with no pairing ceremony, and turns the machine's
//      mobile-access switch on.
//   2. Drive `terminal:start` on the projA AND projB STREAMS → both succeed.
//   3. projC — opened on the host but never singled out for the phone in any
//      way — is advertised and startable too: with the switch on, the phone
//      gets the machine's WHOLE catalog. That disclosure is the deliberate
//      consequence of collapsing authorization to one boolean.
//   4. Stop projB, then issue control-plane `project:start projB` → re-opens as a
//      fresh stream (stream-ready) and re-advertises running:true.
//   5. Turn the switch OFF over the loopback control plane → the advert goes
//      empty and control-plane `project:start` is rejected NOT_ALLOWED, for a
//      project the SAME phone was driving a moment earlier.
//
// Step 5 is the negative this file exists for. There is no per-project axis left
// to deny along: a phone either reaches this machine or it doesn't.
//
// Known Windows test noise (NOT failures): fs.watch EPERM/EBUSY on teardown.
import { test, expect } from "bun:test";
import { join } from "node:path";
import { setMobileAccess, setupTestEnv } from "../helpers/harness";
import type { RelayClient } from "../helpers/relay-client";
import { createTestProject } from "../helpers/fixtures";
import { computeProjectId } from "../../bridge/src/project-id";
import { loadPairedPhones } from "../../bridge/src/paired-phones";
import { readHostFile } from "../../bridge/src/host-discovery";
import { createMessage } from "../../bridge/src/protocol";
import { firstProjectStream, resolveOnFreshAdvert } from "../support/stream";

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
  app.drainQueued("agent:projects");
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

test("machine switch on: the whole catalog is drivable; switch off: the catalog empties and every start is refused", async () => {
  const env = await setupTestEnv({ fixtureName: "basic" });
  const projBdir = createTestProject("basic", { "__RELAY_URL__": env.relay.url.replace(/\/ws$/, "") });
  const projCdir = createTestProject("basic", { "__RELAY_URL__": env.relay.url.replace(/\/ws$/, "") });

  try {
    const cp = env.app;
    const projA = env.projectId;
    const projB = computeProjectId(projBdir.dir);
    const projC = computeProjectId(projCdir.dir);

    // projB + projC exist in the host catalog (opened remote via loopback).
    expect((await loopbackControl(env.abDir, { id: "open-b", type: "project:open", projectId: projB, projectPath: projBdir.dir, mode: "remote" })).ok).toBe(true);
    expect((await loopbackControl(env.abDir, { id: "open-c", type: "project:open", projectId: projC, projectPath: projCdir.dir, mode: "remote" })).ok).toBe(true);

    // === STEP 1: setupTestEnv already admitted ONE app against the control
    // plane (account trust, no pairing ceremony), and its identity row exists.
    // The row is bookkeeping, not authorization — assert it only as proof the
    // admission actually happened. ===
    expect(loadPairedPhones(env.abDir).has(env.appIdentity.publicKeyBase64)).toBe(true);

    // === STEP 2: drive terminal:start on the projA AND projB streams ===
    const streamA = await streamFor(cp, projA);
    const outA = await driveTerminal(cp, streamA, "tA", "ALLOW_A");
    expect(outA).toContain("ALLOW_A");

    const streamB = await resolveOnFreshAdvert(cp, projB);
    const outB = await driveTerminal(cp, streamB, "tB", "ALLOW_B");
    expect(outB).toContain("ALLOW_B");

    // === STEP 3: projC rides the same one switch ===
    // Nothing was ever done to grant projC specifically, and that is now
    // sufficient: the advert is the machine's whole catalog.
    const catalog = await resolveOnFreshAdvert(cp, projC, {
      resolve: async (app) => {
        const advert = await app.waitForAbType("agent:projects", 3_000);
        const ids = advert.projects.map((p: any) => p.projectId);
        if (!ids.includes(projC)) throw new Error(`projC absent from advert: ${ids.join(",")}`);
        return ids;
      },
    });
    expect(catalog).toContain(projA);
    expect(catalog).toContain(projB);

    // === STEP 4: stop projB, then control-plane project:start projB ===
    expect((await loopbackControl(env.abDir, { id: "stop-b", type: "project:stop", projectId: projB })).ok).toBe(true);
    const streamB2 = await cp.openProjectStream(projB, 12_000); // start-on-open → fresh stream-ready
    const outB2 = await driveTerminal(cp, streamB2, "tB2", "RESTART_B");
    expect(outB2).toContain("RESTART_B");

    // === STEP 5: turn the machine off → catalog empties, starts are refused ===
    await setMobileAccess(env.abDir, false);

    // projC was never started, so its start is not short-circuited by an
    // already-warm core — the rejection can only come from the switch.
    cp.drainQueued("control:result");
    cp.sendEncrypted(createMessage("project:start", { projectId: projC }));
    const denyC = await cp.waitForAbType("control:result", 8_000);
    expect(denyC.ok).toBe(false);
    expect((denyC as any).error.code).toBe("NOT_ALLOWED");

    cp.drainQueued("agent:projects");
    await cp.pullStateSnapshot();
    const finalAdvert = await cp.waitForAbType("agent:projects", 8_000);
    expect(finalAdvert.projects).toEqual([]);
  } finally {
    await env.teardown();
    try { projBdir.cleanup(); } catch { /* Windows EBUSY teardown race */ }
    try { projCdir.cleanup(); } catch { /* Windows EBUSY teardown race */ }
  }
}, 120_000);
