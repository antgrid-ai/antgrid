// Stage A wave A4 gate: project streams replace the mux. Each project gets its
// OWN QUIC stream on the phone's single native connection — there is no
// shared session-stream envelope (`{s, m}`) and no bridge-minted `streamId`;
// the eval handle IS the projectId (D-8). The frozen contract is
// docs/iroh-reduction/stage-A-A4-contract.md; this file is its §6
// `gate-project-streams` rows 1-6.
//
// Known Windows test noise (NOT failures): fs.watch EPERM/EBUSY on teardown.
import { test, expect } from "bun:test";
import { randomBytes } from "node:crypto";
import { join } from "node:path";
import {
  setupTestEnv,
  openLoopbackProject,
  establishNativeSession,
  setMobileAccess,
} from "../helpers/harness";
import { RelayClient } from "../helpers/relay-client";
import { createTestProject } from "../helpers/fixtures";
import { computeProjectId } from "../../bridge/src/project-id";
import { readHostFile } from "../../bridge/src/host-discovery";
import { createMessage } from "../../bridge/src/protocol";
import { resolveOnFreshAdvert, streamSnapshot } from "../support/stream";
import { TERMINAL_PROTOCOL_VERSION } from "../../bridge/src/terminal-frames/protocol";

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

/** Round-trips `state.snapshot` on the (still-open) session stream and asserts
 *  `ok:true` — proof the session survived whatever project stream under test
 *  just did. Mirrors gate-stream-admission.test.ts. */
async function assertSessionAlive(app: RelayClient, label: string): Promise<void> {
  const requestId = `gate-project-streams-${label}`;
  const responseP = app.waitFor((m: any) => m.type === "response" && m.requestId === requestId, 8_000);
  app.sendEncrypted(createMessage("request", { requestId, method: "state.snapshot", params: { types: ["*"] } }));
  const res = (await responseP) as { ok?: boolean };
  expect(res.ok).toBe(true);
}

test("hazard J: a raw open before project:start is NOT_READY, project:start's stream-ready carries no streamId, and openProjectStream then admits", async () => {
  const env = await setupTestEnv({ fixtureName: "basic" });
  const projBdir = createTestProject("basic", { "__RELAY_URL__": env.relay.url.replace(/\/ws$/, "") });
  try {
    const projB = computeProjectId(projBdir.dir);
    // Catalogued but never started, so the open below hits the genuine
    // no-live-entry path rather than an "already open" INVALID.
    await openLoopbackProject(env.abDir, { projectId: projB, projectPath: projBdir.dir, mode: "local" });

    const before = env.app.nativeConnectionId;
    const raw = await env.app.openProjectStreamRaw(projB, 8_000);
    expect(raw.refusal?.code).toBe("NOT_READY");
    expect(await raw.ended).toBe("fin");
    expect(env.app.nativeConnectionId).toBe(before);
    await assertSessionAlive(env.app, "hazard-j-pre-start");

    // project:start publishes stream-ready on the SESSION stream, naming only
    // the project — there is no bridge-minted id left to carry.
    const readyP = env.app.waitFor((m: any) => m.type === "stream-ready" && m.projectId === projB, 8_000);
    env.app.sendEncrypted(createMessage("project:start", { projectId: projB }));
    const ready = await readyP;
    expect(ready.streamId).toBeUndefined();

    const streamB = await env.app.openProjectStream(projB, 10_000);
    expect(streamB).toBe(projB); // D-8: the handle is the literal projectId
    const frames = await streamSnapshot(env.app, streamB, 8_000);
    expect(frames.some((f) => f.type === "agent:status")).toBe(true);
  } finally {
    await env.teardown();
    try { projBdir.cleanup(); } catch { /* Windows EBUSY teardown race */ }
  }
}, 60_000);

test("openProjectStreamRaw refuses NOT_ALLOWED for an uncatalogued id and for an unsafe id, and the session stays up", async () => {
  const env = await setupTestEnv({ fixtureName: "basic" });
  try {
    const before = env.app.nativeConnectionId;

    const uncatalogued = await env.app.openProjectStreamRaw(randomBytes(8).toString("hex"), 5_000);
    expect(uncatalogued.refusal?.code).toBe("NOT_ALLOWED");
    expect(await uncatalogued.ended).toBe("fin");

    const unsafe = await env.app.openProjectStreamRaw("../x", 5_000);
    expect(unsafe.refusal?.code).toBe("NOT_ALLOWED");
    expect(await unsafe.ended).toBe("fin");

    expect(env.app.nativeConnectionId).toBe(before);
    await assertSessionAlive(env.app, "not-allowed");
  } finally {
    await env.teardown();
  }
});

test("two devices, one project: broadcasts reach both, an addressed reply reaches only its requester, and one closing leaves the other live", async () => {
  const env = await setupTestEnv({ fixtureName: "basic" });
  let b: RelayClient | undefined;
  try {
    const streamA = env.streamId;
    const second = await env.license.addAccountDevice();
    b = await env.connectNativeApp({
      name: "gate-project-streams-device-b",
      identity: second,
      accountDeviceId: second.deviceId,
    });
    await establishNativeSession(b, env.agentDeviceId, env.agent.ed25519Pubkey);
    const streamB = await b.openProjectStream(env.projectId, 12_000);

    // A broadcast (terminal:started) from A reaches both A and B's streams.
    const terminalId = `gate-project-streams-two-device-${Date.now()}`;
    const onA = env.app.waitForStreamAbType(streamA, "terminal:started", 8_000);
    const onB = b.waitForStreamAbType(streamB, "terminal:started", 8_000);
    env.app.sendOnStream(streamA, createMessage("terminal:start", {
      terminalId, name: terminalId, command: "node", args: ["-e", "setTimeout(() => {}, 5000)"],
    }));
    expect((await onA).terminalId).toBe(terminalId);
    expect((await onB).terminalId).toBe(terminalId);

    // An addressed reply on A's stream reaches A only — B's own stream is a
    // separate QUIC stream entirely, so this also guards against a broadcast
    // bug that writes an addressed reply onto every bound stream.
    const requestId = "gate-project-streams-two-device-snapshot";
    const replyOnA = env.app.waitFor((m: any) => m.type === "response" && m.requestId === requestId, 8_000);
    const strayOnB = b
      .waitFor((m: any) => m.type === "response" && m.requestId === requestId, 1_500)
      .then(() => true, () => false);
    env.app.sendOnStream(streamA, createMessage("request", { requestId, method: "state.snapshot", params: { types: ["*"] } }));
    expect((await replyOnA).ok).toBe(true);
    expect(await strayOnB).toBe(false);

    // A closes its project stream; B's binding is untouched and still gets
    // the next broadcast.
    await env.app.closeProjectStream(streamA);
    const terminalId2 = `gate-project-streams-two-device-after-close-${Date.now()}`;
    const onB2 = b.waitForStreamAbType(streamB, "terminal:started", 8_000);
    b.sendOnStream(streamB, createMessage("terminal:start", {
      terminalId: terminalId2, name: terminalId2, command: "node", args: ["-e", "setTimeout(() => {}, 1000)"],
    }));
    expect((await onB2).terminalId).toBe(terminalId2);
  } finally {
    await b?.disconnect();
    await env.teardown();
  }
}, 60_000);

test("switching the machine off under an open project stream closes the native connection and nothing further arrives on it", async () => {
  const env = await setupTestEnv({ fixtureName: "basic" });
  try {
    const streamId = env.streamId;
    // Captured before the flip: the registry entry is gone by the time
    // `ended` resolves, so a post-hoc lookup would throw instead of observing it.
    const ended = env.app.projectStreamEnded(streamId);

    await setMobileAccess(env.abDir, false);

    expect(await ended).toBe("error");
    expect(env.app.isProjectStreamOpen(streamId)).toBe(false);
    expect(() => env.app.sendOnStream(
      streamId,
      createMessage("terminal:start", { terminalId: "x", name: "x", command: "node", args: [] }),
    )).toThrow(/is not open/);
  } finally {
    await env.teardown();
  }
}, 30_000);

test("a terminal stream needs this peer's own project stream open first: NOT_ALLOWED before, admitted after", async () => {
  const env = await setupTestEnv({ fixtureName: "basic" });
  const projBdir = createTestProject("basic", { "__RELAY_URL__": env.relay.url.replace(/\/ws$/, "") });
  try {
    const projB = computeProjectId(projBdir.dir);
    // Running (mode:"remote", never stopped) — a live entry exists, so the
    // refusal below is the peer-scoped "no open project stream for THIS peer"
    // check, not the no-live-entry NOT_READY gate-stream-admission covers.
    expect((await loopbackControl(env.abDir, {
      id: "open-project-streams-row6-b", type: "project:open", projectId: projB, projectPath: projBdir.dir, mode: "remote",
    })).ok).toBe(true);
    await resolveOnFreshAdvert(env.app, projB, {
      resolve: (app) => app.waitFor(
        (m: any) => m.type === "agent:projects" && m.projects.some((p: any) => p.projectId === projB && p.running),
        3_000,
      ),
    });

    const before = env.app.nativeConnectionId;
    const requestId = crypto.randomUUID();
    const client = await env.app.openTerminalStream({ projectId: projB, requestId });
    const refusal = await client.next((r: any) => r.type === "stream:refused");
    expect(refusal.code).toBe("NOT_ALLOWED");
    expect(env.app.nativeConnectionId).toBe(before);
    await assertSessionAlive(env.app, "row6-no-project-stream");

    // Bind this peer's own project stream, then retry: admitted.
    await env.app.openProjectStream(projB, 10_000);
    const terminalId = `gate-project-streams-row6-${Date.now()}`;
    env.app.sendOnStream(projB, createMessage("terminal:start", {
      terminalId, name: terminalId, command: "node", args: ["-e", "setTimeout(() => {}, 5000)"],
    }));
    await env.app.waitFor(
      (m: any) => m.type === "terminal:started" && m._streamId === projB && m.terminalId === terminalId,
      5_000,
    );

    const requestId2 = crypto.randomUUID();
    const client2 = await env.app.openTerminalStream({ projectId: projB, requestId: requestId2 });
    await client2.send(createMessage("terminal:subscribe", {
      terminalId, version: TERMINAL_PROTOCOL_VERSION, requestId: requestId2,
    }));
    const subscribed = await client2.next((r: any) => r.type === "terminal:subscribed" && r.requestId === requestId2);
    expect(subscribed.terminalId).toBe(terminalId);
  } finally {
    await env.teardown();
    try { projBdir.cleanup(); } catch { /* Windows EBUSY teardown race */ }
  }
}, 60_000);
