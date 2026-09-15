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
//   5. Turn the switch OFF over the loopback control plane → E2E keys are
//      retired and remote commands stop. Re-enable requires fresh E2E.
//
// Step 5 is the negative this file exists for. There is no per-project axis left
// to deny along: a phone either reaches this machine or it doesn't.
//
// Known Windows test noise (NOT failures): fs.watch EPERM/EBUSY on teardown.
import { test, expect } from "bun:test";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { handshakeWithoutPairing, setMobileAccess, setupTestEnv } from "../helpers/harness";
import { TERMINAL_PROTOCOL_VERSION } from "../../bridge/src/terminal-frames/protocol";
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
  app.sendOnStream(
    streamId,
    createMessage("terminal:start", {
      terminalId,
      name: terminalId,
      command: "node",
      args: ["-e", `console.log('${marker}');setTimeout(()=>{},1000)`],
    } as never),
  );
  await app.waitFor((m: any) => m.type === "terminal:started" && m.terminalId === terminalId, 5_000);
  await subscribe(app, streamId, terminalId);
  const outputs = await collectOutput(app, streamId, terminalId, 6_000);
  return outputs.join("");
}

async function subscribe(app: RelayClient, streamId: string, terminalId: string): Promise<void> {
  const requestId = crypto.randomUUID();
  app.sendOnStream(streamId, createMessage("terminal:subscribe", { terminalId, requestId, version: TERMINAL_PROTOCOL_VERSION }));
  await app.waitFor((m: any) => m.type === "terminal:subscribed" && m.requestId === requestId, 5_000);
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

/** Collect acknowledged terminal frames for `terminalId` on `streamId` until `want` frames
 *  arrive or the window closes. Returns everything seen — the caller decides
 *  whether a non-empty result is the pass or the failure. */
async function collectOutput(
  app: RelayClient,
  streamId: string,
  terminalId: string,
  windowMs: number,
  want = Number.POSITIVE_INFINITY,
): Promise<string[]> {
  const out: string[] = [];
  const deadline = Date.now() + windowMs;
  while (Date.now() < deadline && out.length < want) {
    try {
      const m = await app.waitForStreamAbType(streamId, "terminal:frame", deadline - Date.now());
      app.sendOnStream(streamId, createMessage("terminal:ack", { terminalId: m.terminalId,
        runId: m.runId, attachmentId: m.attachmentId, sequence: m.sequence }));
      if (m.terminalId === terminalId) out.push(m.ansi);
    } catch {
      break; // window closed with nothing more to read
    }
  }
  return out;
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

// The switch has to gate the stream in BOTH directions. Dropping inbound only
// stops the phone DRIVING a project; a core it cold-started keeps pushing
// terminal output, the file tree and git status at it, because a remote-mode
// core holds no PromotionHandle for `demoteAllPromoted` to tear down.
test("outbound rides the machine switch: output stops while off and resumes only after fresh E2E hydration", async () => {
  const env = await setupTestEnv({ fixtureName: "basic" });
  const projBdir = createTestProject("basic", { "__RELAY_URL__": env.relay.url.replace(/\/ws$/, "") });

  try {
    const cp = env.app;
    const projB = computeProjectId(projBdir.dir);
    writeFileSync(join(projBdir.dir, "ticker.cjs"), "let i=0;setInterval(()=>console.log('TICK_'+ ++i),100);process.stdin.on('data',data=>require('node:fs').appendFileSync('input.log',data));");

    // Production shape: projB is in the host catalog but NOT running, so the
    // phone's project:start takes host-server's `!entry` branch and opens a
    // mode:"remote" core. A promoted (desktop-opened) core would prove less —
    // that one demoteAllPromoted does tear down.
    expect((await loopbackControl(env.abDir, { id: "open-b", type: "project:open", projectId: projB, projectPath: projBdir.dir, mode: "remote" })).ok).toBe(true);
    await resolveOnFreshAdvert(cp, projB);
    expect((await loopbackControl(env.abDir, { id: "stop-b", type: "project:stop", projectId: projB })).ok).toBe(true);
    const streamB = await cp.openProjectStream(projB, 12_000);

    // A terminal that keeps emitting on its own, so "did anything arrive?" is a
    // question about the STREAM, not about whether the phone could ask again.
    cp.sendOnStream(streamB, createMessage("terminal:start", {
      terminalId: "ticker",
      name: "ticker",
      command: "node", args: ["ticker.cjs"],
    } as never));
    await cp.waitFor((m: any) => m.type === "terminal:started" && m.terminalId === "ticker", 5_000);
    await subscribe(cp, streamB, "ticker");

    // === Switch ON: output flows ===
    // The control. Without it the silence below would pass for a terminal that
    // never started.
    const whileOn = await collectOutput(cp, streamB, "ticker", 15_000, 3);
    expect(whileOn.join("")).toContain("TICK_");

    // === Switch OFF: the same bound stream goes quiet ===
    await setMobileAccess(env.abDir, false);
    cp.drainQueued("terminal:frame"); // in-flight frames sent before the flip
    cp.sendOnStream(streamB, createMessage("terminal:input", { terminalId: "ticker", data: "FORBIDDEN_INPUT\r" }));
    const whileOff = await collectOutput(cp, streamB, "ticker", 6_000);
    expect(whileOff).toEqual([]);
    expect(existsSync(join(projBdir.dir, "input.log"))).toBe(false);

    // Re-enabling cannot resurrect old keys or replay denied input.
    await setMobileAccess(env.abDir, true);
    expect(await collectOutput(cp, streamB, "ticker", 500)).toEqual([]);
    await handshakeWithoutPairing(cp, env.agentDeviceId, env.agent.ed25519Pubkey);
    const freshStream = await cp.openProjectStream(projB, 12_000);
    await subscribe(cp, freshStream, "ticker");
    const whileOnAgain = await collectOutput(cp, freshStream, "ticker", 15_000, 2);
    expect(whileOnAgain.join("")).toContain("TICK_");
    expect(existsSync(join(projBdir.dir, "input.log"))).toBe(false);
    cp.sendOnStream(freshStream, createMessage("terminal:input", { terminalId: "ticker", data: "ALLOWED_INPUT\r" }));
    for (let i = 0; i < 100 && !existsSync(join(projBdir.dir, "input.log")); i++) await Bun.sleep(20);
    const deliveredInput = readFileSync(join(projBdir.dir, "input.log"), "utf8");
    expect(deliveredInput).toContain("ALLOWED_INPUT");
    expect(deliveredInput).not.toContain("FORBIDDEN_INPUT");
  } finally {
    await env.teardown();
    try { projBdir.cleanup(); } catch { /* Windows EBUSY teardown race */ }
  }
}, 180_000);

test("machine switch on exposes the catalog; switch off retires E2E and never replays a project start", async () => {
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

    expect((await loopbackControl(env.abDir, { id: "stop-c", type: "project:stop", projectId: projC })).ok).toBe(true);
    // === STEP 5: turn the machine off → keys retire and starts cannot dispatch ===
    await setMobileAccess(env.abDir, false);

    // projC is stopped, so a dispatched start would be visible in the host list.
    cp.drainQueued("control:result");
    cp.sendEncrypted(createMessage("project:start", { projectId: projC }));
    expect(await cp.waitForAbType("control:result", 1_000).catch(() => null)).toBeNull();
    const projectIsRunning = async () => (await loopbackControl(env.abDir, { id: "list", type: "project:list" }))
      .projects.some((project: any) => project.projectId === projC && project.running);
    expect(await projectIsRunning()).toBe(false);
    await setMobileAccess(env.abDir, true);
    await handshakeWithoutPairing(cp, env.agentDeviceId, env.agent.ed25519Pubkey);
    await cp.pullStateSnapshot();
    expect(await projectIsRunning()).toBe(false);
    await cp.openProjectStream(projC, 12_000);
    expect(await projectIsRunning()).toBe(true);
  } finally {
    await env.teardown();
    try { projBdir.cleanup(); } catch { /* Windows EBUSY teardown race */ }
    try { projCdir.cleanup(); } catch { /* Windows EBUSY teardown race */ }
  }
}, 120_000);
