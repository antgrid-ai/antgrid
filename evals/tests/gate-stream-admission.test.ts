import { test, expect } from "bun:test";
import { encodeStreamOpen, decodeStreamRefused, PEER_ALPN, type StreamRefusedCode } from "antgrid-wire";
import { setupTestEnv, openLoopbackProject } from "../helpers/harness";
import { RelayClient } from "../helpers/relay-client";
import { createMessage } from "../../bridge/src/protocol";
import { createTestProject } from "../helpers/fixtures";
import { computeProjectId } from "../../bridge/src/project-id";

/**
 * Stage A wave A1: later streams (anything after the first, session-declaring
 * one) are admitted by `PeerStreamAcceptor`. A1 registered no handlers, so
 * every well-formed non-session open from an established peer was refused
 * `NOT_ALLOWED`, and a malformed or duplicate-session open is refused
 * `INVALID` — both in-band, followed by FIN (D4), never by tearing down the
 * connection (D3). This is the one seam bridge-tests' fakes cannot cover: a
 * real binding, a real `PeerStreamAcceptor` and a real second QUIC stream on
 * the SAME connection the session stream is live on.
 *
 * Stage A wave A4 wires the `"project"` handler into that acceptor, so the
 * project-kind case below now exercises real admission (`gate-project-streams`
 * covers the admitted path end to end).
 */

/** Round-trips `state.snapshot` on the (still-open) session stream and asserts
 *  `ok:true` — proof the session survived whatever the last stream did.
 *  Deliberately not `pullStateSnapshot`, which resolves silently on a dead
 *  session. */
async function assertSessionAlive(app: RelayClient, label: string): Promise<void> {
  const requestId = `gate-stream-admission-${label}`;
  const responseP = app.waitFor((m: any) => m.type === "response" && m.requestId === requestId, 8_000);
  app.sendEncrypted(createMessage("request", { requestId, method: "state.snapshot", params: { types: ["*"] } }));
  const res = (await responseP) as { ok?: boolean };
  expect(res.ok).toBe(true);
}

/** A refusal is in-band: exactly one `stream:refused` record, then FIN. */
function expectRefusal(
  result: { records: Uint8Array[]; ended: "fin" | "error" | "timeout" },
  code: StreamRefusedCode,
): void {
  expect(result.ended).toBe("fin");
  expect(result.records).toHaveLength(1);
  const refused = decodeStreamRefused(result.records[0]!);
  expect(refused?.code).toBe(code);
}

test("an unparseable open frame is refused INVALID in-band and the session stays up", async () => {
  const env = await setupTestEnv({ fixtureName: "basic" });
  try {
    const before = env.app.nativeConnectionId;
    const result = await env.app.openNativeStreamRaw(Buffer.from("{not json", "utf8"));
    expectRefusal(result, "INVALID");
    expect(env.app.nativeConnectionId).toBe(before);
    await assertSessionAlive(env.app, "unparseable");
  } finally {
    await env.teardown();
  }
});

test("an oversized open-frame length prefix is refused INVALID and the session stays up", async () => {
  const env = await setupTestEnv({ fixtureName: "basic" });
  try {
    const before = env.app.nativeConnectionId;
    // A bare 4-byte length prefix, well past STREAM_OPEN_MAX_BYTES (4096); the
    // acceptor must refuse without ever reading a body this large.
    const oversizePrefix = Buffer.from([0x00, 0x10, 0x00, 0x00]);
    const result = await env.app.openNativeStreamRaw(oversizePrefix, { framed: false });
    expectRefusal(result, "INVALID");
    expect(env.app.nativeConnectionId).toBe(before);
    await assertSessionAlive(env.app, "oversize");
  } finally {
    await env.teardown();
  }
});

// A4: a project stream open never opens or promotes a core (§3.3 step 5) — it
// only looks up an entry `project:start` already attached. `env.projectId` is
// unsuitable here: `setupTestEnv` already drives its `project:start` and opens
// its stream, so a second raw open for it would hit "already open" (INVALID),
// not this row. A second, deliberately un-started project (catalogued via the
// loopback verb with mode:"local", never promoted) gives a real NOT_READY.
test("a project-kind open for a catalogued project with no project:start is refused NOT_READY and the session stays up", async () => {
  const env = await setupTestEnv({ fixtureName: "basic" });
  const projBdir = createTestProject("basic", { "__RELAY_URL__": env.relay.url.replace(/\/ws$/, "") });
  try {
    const projB = computeProjectId(projBdir.dir);
    await openLoopbackProject(env.abDir, { projectId: projB, projectPath: projBdir.dir, mode: "local" });
    const before = env.app.nativeConnectionId;
    const open = encodeStreamOpen({ kind: "project", projectId: projB });
    const result = await env.app.openNativeStreamRaw(open);
    expectRefusal(result, "NOT_READY");
    expect(env.app.nativeConnectionId).toBe(before);
    await assertSessionAlive(env.app, "project-kind-not-ready");
  } finally {
    await env.teardown();
    try { projBdir.cleanup(); } catch { /* Windows EBUSY teardown race */ }
  }
});

test("a second session-kind stream is refused INVALID", async () => {
  const env = await setupTestEnv({ fixtureName: "basic" });
  try {
    const before = env.app.nativeConnectionId;
    const open = encodeStreamOpen({ kind: "session" });
    const result = await env.app.openNativeStreamRaw(open);
    expectRefusal(result, "INVALID");
    expect(env.app.nativeConnectionId).toBe(before);
    await assertSessionAlive(env.app, "second-session");
  } finally {
    await env.teardown();
  }
});

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
