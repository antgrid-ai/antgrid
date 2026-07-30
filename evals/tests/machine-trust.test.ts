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
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { setMobileAccess, setupTestEnv } from "../helpers/harness";
import { generateEphemeralKeypair } from "../../bridge/src/key-exchange";
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

/** Fire a host-side notification through the per-core api-server's loopback
 *  `/notify`. Host-side on purpose: the phone-driven path is closed while the
 *  switch is off, so a phone-triggered notification could not tell "the gate
 *  refused the push" from "the gate refused the trigger". The bus publish
 *  happens before the HTTP response, so `ok` means the dispatcher ran. */
async function notify(abDir: string, notificationType: string, message: string): Promise<void> {
  const apiPort = Number(readFileSync(join(abDir, "api.port"), "utf8").trim());
  const res = await fetch(`http://127.0.0.1:${apiPort}/notify`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ type: notificationType, message }),
  });
  if (!res.ok) throw new Error(`/notify ${notificationType} failed: ${res.status}`);
}

async function waitForPushCount(relay: { pushDeliveries(): unknown[] }, want: number, timeoutMs: number): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (relay.pushDeliveries().length >= want) return;
    await Bun.sleep(50);
  }
}

// Push is the one path that reaches the phone without the phone asking, so the
// machine switch has to gate it too — a stale token on a machine you've marked
// unreachable must go quiet. The bridge unit test
// (bridge/tests/push/push-restart-targeting.test.ts) stubs `resolveTargets`;
// this proves the switch is actually wired to the real dispatcher, through a
// real relay, end to end.
test("push rides the machine switch: delivered while on, silent while off, and alive again after", async () => {
  const env = await setupTestEnv({ fixtureName: "basic" });

  try {
    const streamId = await firstProjectStream(env.app, env.projectId, 10_000);

    // A real X25519 key: `sealPush` derives against it, so a junk pubkey would
    // fail inside the dispatcher and read as a (wrong) passing negative.
    const pushKeys = generateEphemeralKeypair();
    const pushToken = "EVAL_PUSH_TOKEN";
    env.app.sendOnStream(
      streamId,
      createMessage("push:register", {
        pushToken,
        provider: "fcm",
        pushPubkey: pushKeys.publicKey.toString("base64"),
      } as never),
    );
    // Push is the FALLBACK path — it only fires when the phone can't receive
    // in-band. The app is connected here, so background it explicitly.
    env.app.sendOnStream(streamId, createMessage("client:focus-state", { paused: true } as never));
    await Bun.sleep(500); // both are fire-and-forget; let the core apply them

    // === Switch ON: the push actually lands ===
    // This half is the control. Without it a broken push pipeline would make
    // the negative below pass for the wrong reason.
    await notify(env.abDir, "task_complete", "on-switch");
    await waitForPushCount(env.relay, 1, 10_000);
    const afterOn = env.relay.pushDeliveries();
    expect(afterOn).toHaveLength(1);
    expect(afterOn[0].pushToken).toBe(pushToken);

    // === Switch OFF: the same registered token gets nothing ===
    // A DIFFERENT notificationType each time: reduceWorkStatus folds a repeat of
    // the previous type into "redundant" and the dispatcher skips it, which
    // would make this negative vacuous.
    await setMobileAccess(env.abDir, false);
    await notify(env.abDir, "permission_request", "off-switch");
    await Bun.sleep(2_500); // a push, if the gate leaked, would be out well inside this
    expect(env.relay.pushDeliveries()).toHaveLength(1);

    // === Switch back ON: it was the switch, not a dead pipeline ===
    await setMobileAccess(env.abDir, true);
    await notify(env.abDir, "error", "on-again");
    await waitForPushCount(env.relay, 2, 10_000);
    expect(env.relay.pushDeliveries()).toHaveLength(2);
  } finally {
    await env.teardown();
  }
}, 120_000);

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
