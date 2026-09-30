// Gate: stream admission. One PeerStreamAcceptor decides every open on the
// phone's single native connection, and a project stream is the one kind
// admitted with no upstream project-stream gate of its own (no `{ s, m }`
// envelope, no bridge-minted streamId — the eval handle IS the projectId).
// This is the one seam bridge-tests' fakes cannot cover: a real binding, a
// real acceptor and real QUIC streams on a real connection.
// Known Windows test noise (NOT failures): fs.watch EPERM/EBUSY on teardown.
import { test, expect } from "bun:test";
import { randomBytes } from "node:crypto";
import { join } from "node:path";
import { encodeStreamOpen, decodeStreamRefused, PEER_ALPN, type StreamRefusedCode } from "antgrid-wire";
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
 *  `ok:true` — proof the session survived whatever stream under test just did. */
async function assertSessionAlive(app: RelayClient, label: string): Promise<void> {
  const requestId = `gate-stream-admission-${label}`;
  const responseP = app.waitFor((m: any) => m.type === "response" && m.requestId === requestId, 8_000);
  app.sendEncrypted(createMessage("request", { requestId, method: "state.snapshot", params: { types: ["*"] } }));
  const res = (await responseP) as { ok?: boolean };
  expect(res.ok).toBe(true);
}

/** A raw-stream refusal is in-band: exactly one `stream:refused` record, then FIN. */
function expectRawRefusal(
  result: { records: Uint8Array[]; ended: "fin" | "error" | "timeout" },
  code: StreamRefusedCode,
): void {
  expect(result.ended).toBe("fin");
  expect(result.records).toHaveLength(1);
  expect(decodeStreamRefused(result.records[0]!)?.code).toBe(code);
}

test("a malformed open frame — unparseable JSON, then an oversized length prefix — is refused INVALID in-band and the session stays up", async () => {
  const env = await setupTestEnv({ fixtureName: "basic" });
  try {
    const before = env.app.nativeConnectionId;
    expectRawRefusal(await env.app.openNativeStreamRaw(Buffer.from("{not json", "utf8")), "INVALID");
    // A bare 4-byte length prefix, well past STREAM_OPEN_MAX_BYTES (4096); the
    // acceptor must refuse without ever reading a body this large.
    const oversizePrefix = Buffer.from([0x00, 0x10, 0x00, 0x00]);
    expectRawRefusal(await env.app.openNativeStreamRaw(oversizePrefix, { framed: false }), "INVALID");
    expect(env.app.nativeConnectionId).toBe(before);
    await assertSessionAlive(env.app, "malformed-open");
  } finally {
    await env.teardown();
  }
});

test("a project open before project:start is NOT_READY and opens no core; project:start then admits with a bare stream-ready", async () => {
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
    await assertSessionAlive(env.app, "project-not-ready");

    // project:start publishes stream-ready on the SESSION stream, naming only
    // the project — there is no bridge-minted id left to carry.
    const readyP = env.app.waitFor((m: any) => m.type === "stream-ready" && m.projectId === projB, 8_000);
    env.app.sendEncrypted(createMessage("project:start", { projectId: projB }));
    const ready = await readyP;
    expect(ready.streamId).toBeUndefined();

    const streamB = await env.app.openProjectStream(projB, 10_000);
    expect(streamB).toBe(projB); // the eval handle is the literal projectId
    const frames = await streamSnapshot(env.app, streamB, 8_000);
    expect(frames.some((f) => f.type === "agent:status")).toBe(true);
  } finally {
    await env.teardown();
    try { projBdir.cleanup(); } catch { /* Windows EBUSY teardown race */ }
  }
}, 60_000);

test("an uncatalogued id and an unsafe id are refused NOT_ALLOWED, a second session-kind stream is INVALID, and the session stays up", async () => {
  const env = await setupTestEnv({ fixtureName: "basic" });
  try {
    const before = env.app.nativeConnectionId;

    const uncatalogued = await env.app.openProjectStreamRaw(randomBytes(8).toString("hex"), 5_000);
    expect(uncatalogued.refusal?.code).toBe("NOT_ALLOWED");
    expect(await uncatalogued.ended).toBe("fin");

    const unsafe = await env.app.openProjectStreamRaw("../x", 5_000);
    expect(unsafe.refusal?.code).toBe("NOT_ALLOWED");
    expect(await unsafe.ended).toBe("fin");

    expectRawRefusal(await env.app.openNativeStreamRaw(encodeStreamOpen({ kind: "session" })), "INVALID");

    expect(env.app.nativeConnectionId).toBe(before);
    await assertSessionAlive(env.app, "not-allowed");
  } finally {
    await env.teardown();
  }
});

test("two devices, two projects: each device's own stream is isolated by project and by peer, closing one leaves the others live, and each device still holds one relay connection", async () => {
  const env = await setupTestEnv({ fixtureName: "basic" });
  const projBdir = createTestProject("basic", { "__RELAY_URL__": env.relay.url.replace(/\/ws$/, "") });
  let b: RelayClient | undefined;
  try {
    const projA = env.projectId;
    const streamA = env.streamId;
    const projB = computeProjectId(projBdir.dir);

    // projB: open remote (catalogued), stop, then let project:start take the
    // fresh-open path — a genuine second registration, not the idempotent
    // republish `setupTestEnv`'s own project already exercises.
    expect((await loopbackControl(env.abDir, {
      id: "gate-stream-admission-open-b", type: "project:open", projectId: projB, projectPath: projBdir.dir, mode: "remote",
    })).ok).toBe(true);
    expect((await loopbackControl(env.abDir, { id: "gate-stream-admission-stop-b", type: "project:stop", projectId: projB })).ok).toBe(true);
    const streamB = await resolveOnFreshAdvert(env.app, projB, {
      attempts: 3,
      resolve: (a) => a.openProjectStream(projB, 12_000),
    });
    expect(streamA).not.toBe(streamB);

    // A second device, bound to projA only.
    const second = await env.license.addAccountDevice();
    b = await env.connectNativeApp({
      name: "gate-stream-admission-device-b",
      identity: second,
      accountDeviceId: second.deviceId,
    });
    await establishNativeSession(b, env.agentDeviceId, env.agent.ed25519Pubkey);
    const streamA2 = await b.openProjectStream(projA, 12_000);

    // A broadcast on projA reaches every stream bound to projA (device A's and
    // device B's) and never device A's own projB stream — isolation by
    // project AND by peer in one shot.
    const terminalId = `gate-stream-admission-two-device-${Date.now()}`;
    const onA = env.app.waitForStreamAbType(streamA, "terminal:started", 8_000);
    const onA2 = b.waitForStreamAbType(streamA2, "terminal:started", 8_000);
    const strayOnB = env.app
      .waitForStreamAbType(streamB, "terminal:started", 1_500)
      .then(() => true, () => false);
    env.app.sendOnStream(streamA, createMessage("terminal:start", {
      terminalId, name: terminalId, command: "node", args: ["-e", "setTimeout(() => {}, 5000)"],
    }));
    expect((await onA).terminalId).toBe(terminalId);
    expect((await onA2).terminalId).toBe(terminalId);
    expect(await strayOnB).toBe(false);

    // An addressed reply on device A's projA stream reaches only that stream:
    // not device B's own stream to the SAME project, and not device A's own
    // stream to a DIFFERENT project.
    const requestId = "gate-stream-admission-two-device-snapshot";
    const replyOnA = env.app.waitFor((m: any) => m.type === "response" && m.requestId === requestId, 8_000);
    const strayOnA2 = b
      .waitFor((m: any) => m.type === "response" && m.requestId === requestId, 1_500)
      .then(() => true, () => false);
    env.app.sendOnStream(streamA, createMessage("request", { requestId, method: "state.snapshot", params: { types: ["*"] } }));
    expect((await replyOnA).ok).toBe(true);
    expect(await strayOnA2).toBe(false);

    // Closing device A's projA stream leaves device B's projA stream, and
    // device A's own projB stream, both untouched.
    await env.app.closeProjectStream(streamA);
    const terminalId2 = `${terminalId}-after-close`;
    const onA2Again = b.waitForStreamAbType(streamA2, "terminal:started", 8_000);
    b.sendOnStream(streamA2, createMessage("terminal:start", {
      terminalId: terminalId2, name: terminalId2, command: "node", args: ["-e", "setTimeout(() => {}, 1000)"],
    }));
    expect((await onA2Again).terminalId).toBe(terminalId2);
    env.app.sendOnStream(streamB, createMessage("file:read", { projectId: projB, path: "README.md" }));
    expect((await env.app.waitForStreamAbType(streamB, "file:content", 8_000)).path).toBe("README.md");

    // The multiplexing point: three project streams are open across the two
    // devices, yet each device still holds exactly one relay connection.
    expect(env.relay.connectionCount()).toBe(3); // agent + device A + device B
  } finally {
    await b?.disconnect();
    await env.teardown();
    try { projBdir.cleanup(); } catch { /* Windows EBUSY teardown race */ }
  }
}, 120_000);

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
    // check, not the no-live-entry NOT_READY row above.
    expect((await loopbackControl(env.abDir, {
      id: "gate-stream-admission-terminal-needs-project-b", type: "project:open", projectId: projB, projectPath: projBdir.dir, mode: "remote",
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
    await assertSessionAlive(env.app, "no-project-stream");

    // Bind this peer's own project stream, then retry: admitted.
    await env.app.openProjectStream(projB, 10_000);
    const terminalId = `gate-stream-admission-terminal-needs-project-${Date.now()}`;
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

test("a dial on the stale ALPN antgrid/peer/1 is refused", async () => {
  const env = await setupTestEnv({ fixtureName: "basic" });
  try {
    expect(PEER_ALPN).not.toBe("antgrid/peer/1");
    const outcome = await env.app.probeNativeAlpn("antgrid/peer/1");
    expect(outcome).toBe("refused");
    await assertSessionAlive(env.app, "stale-alpn");
  } finally {
    await env.teardown();
  }
});
