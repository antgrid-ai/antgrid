import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { Endpoint, EndpointAddr, EndpointId } from "@number0/iroh/index.js";
import {
  PEER_ALPN,
  STREAM_PROJECT_RECORD_MAX_BYTES,
  STREAM_TERMINAL_BRIDGE_RECORD_MAX_BYTES,
  decodePeerFrame,
  encodePeerFrame,
  encodeStreamOpen,
} from "antgrid-wire";
import { PeerRecords } from "../src/peer/records";
import { StreamRecordReader } from "../src/peer/stream-records";
import { createMessage } from "../src/protocol";
import { TERMINAL_PROTOCOL_VERSION } from "../src/terminal-frames/protocol";
import { device, startSmokeFixture } from "./iroh-smoke-fixture";

/** `[u32 BE len][bytes]` — the framing every stream-open frame and project/
 *  terminal-stream record uses (mirrors `evals/helpers/relay-client.ts`'s
 *  copy; this script has no shared home to pull it from). */
function prefixWithLength(bytes: Uint8Array): Uint8Array {
  const out = Buffer.alloc(4 + bytes.length);
  out.writeUInt32BE(bytes.length, 0);
  Buffer.from(bytes.buffer, bytes.byteOffset, bytes.length).copy(out, 4);
  return out;
}

// Transport qualification only: HTTP authorization and central authentication
// are fixtures. The native connection, HostServer and project services run
// their production implementations; this is not backend-auth qualification.
// Both ends bind `@number0/iroh`, so this gate does not cross the Dart binding
// boundary — iroh-interop-smoke covers that.
const phone = device();
const appBuilder = Endpoint.builder();
appBuilder.applyMinimal();
appBuilder.bindAddr("127.0.0.1:0");
const app = await appBuilder.bind();
const fixture = await startSmokeFixture({
  appEndpointId: app.id().toString(),
  app: { id: phone.id, public: phone.public },
  label: "native-host-smoke",
});
const projects = fixture.projects;
let records: PeerRecords | undefined;
let connection: Awaited<ReturnType<Endpoint["connect"]>> | undefined;
const timeout = setTimeout(() => { console.error("native-host-smoke timed out"); process.exitCode = 1; void fixture.dispose(); }, 30_000);
try {
  const native = await fixture.nativeAddress();
  connection = await app.connect(new EndpointAddr(EndpointId.fromString(native.endpointId), undefined, native.addresses), Array.from(Buffer.from(PEER_ALPN)));
  const stream = await connection.openBi();
  records = new PeerRecords(stream, () => true, () => connection?.close(1n, []));
  // Every native bidi stream opens with a StreamOpen record before it
  // carries anything else, the session stream included.
  void records.send(encodeStreamOpen({ kind: "session" }));
  const attemptId = randomUUID();
  // A4: the session stream carries only machine control-plane frames now —
  // terminal:frame (and every other project/terminal record) rides its own
  // QUIC stream, so this loop needs no ack side-channel of its own.
  const send = (value: object) => records!.send(encodePeerFrame({ type: "message", channel: "control" }, Buffer.from(JSON.stringify(value), "utf8")));
  const read = async (predicate: (value: any) => boolean): Promise<any> => {
    for (;;) {
      const frame = decodePeerFrame(await records!.read());
      const value = JSON.parse(Buffer.from(frame.payload).toString("utf8"));
      const message = value.m ?? value;
      if (predicate(message)) return message;
    }
  };
  // QUIC/TLS between the lease-authorized endpoints is the confidentiality
  // layer post Stage-B; the hello is plaintext and carries no transcript.
  await send({ type: "session:hello", attemptId, capabilities: { checkoutRouting: true, pullsTree: true, terminalFramesV1: true } });
  await read((value) => value.type === "established" && value.attemptId === attemptId);
  const nativeConnectionId = connection.stableId();
  fixture.takeCentralOffline();
  for (const project of projects) {
    // A4: `project:start` still rides the session stream, but the stream it
    // readies is the project's OWN QUIC stream — the `stream-ready` notice
    // carries no id to bind to, it only gates opening that stream (Hazard J).
    await send({ m: createMessage("project:start", { projectId: project.id }) });
    await read((value) => value.type === "stream-ready" && value.projectId === project.id);

    const pStream = await connection.openBi();
    await pStream.send.writeAll(Array.from(
      prefixWithLength(encodeStreamOpen({ kind: "project", projectId: project.id })),
    ));
    const pReader = new StreamRecordReader({ recv: pStream.recv }, STREAM_PROJECT_RECORD_MAX_BYTES, () => {});
    const pSend = (value: object) =>
      pStream.send.writeAll(Array.from(prefixWithLength(Buffer.from(JSON.stringify(value), "utf8"))));
    const pRead = async (predicate: (value: any) => boolean): Promise<any> => {
      for (;;) {
        const value = JSON.parse(Buffer.from(await pReader.read()).toString("utf8"));
        if (predicate(value)) return value;
      }
    };
    // D-1: the bridge's first record on an admitted project stream is its own
    // `stream-ready {projectId}` — this is what makes the bind observable.
    const bound = await pRead((value) => true);
    assert.equal(bound.type, "stream-ready");
    assert.equal(bound.projectId, project.id);

    await pSend(createMessage("file:read", { projectId: project.id, path: "proof.txt" }));
    const file = await pRead((value) => value.type === "file:content" && value.projectId === project.id);
    assert.equal(file.content, `${project.name}:native-host-proof`);
    if (project.name === "alpha") {
      const requestId = randomUUID();
      await pSend(createMessage("session:create", {
        requestId, name: "native-checkout", isolation: "worktree",
      }));
      const created = await pRead((value) => value.type === "session:result" && value.requestId === requestId);
      assert.equal(created.ok, true);
      assert.equal(created.session.checkoutKind, "managed-worktree");
      await pSend(createMessage("git:list-branches", {
        projectId: project.id, checkoutId: created.session.checkoutId,
      }));
      const branches = await pRead((value) => value.type === "git:branches" && value.checkoutId === created.session.checkoutId);
      assert.equal(branches.current, created.session.checkoutBranch);

      const terminalId = "native-echo";
      // terminal:start/:input/:stop stay on the project stream (A2); only
      // frame delivery (terminal:subscribe/:subscribed/:frame/:display:status)
      // moves to the terminal's own dedicated stream below.
      await pSend(createMessage("terminal:start", {
        terminalId, name: terminalId, command: "node", args: ["native-echo.cjs"],
      }));
      await pRead((value) => value.type === "terminal:started" && value.terminalId === terminalId);

      const subscribeId = randomUUID();
      const tStream = await connection.openBi();
      await tStream.send.writeAll(Array.from(
        prefixWithLength(encodeStreamOpen({ kind: "terminal", projectId: project.id, requestId: subscribeId })),
      ));
      const tReader = new StreamRecordReader({ recv: tStream.recv }, STREAM_TERMINAL_BRIDGE_RECORD_MAX_BYTES, () => {});
      const tSend = (value: object) =>
        tStream.send.writeAll(Array.from(prefixWithLength(Buffer.from(JSON.stringify(value), "utf8"))));
      const tRead = async (predicate: (value: any) => boolean): Promise<any> => {
        for (;;) {
          const value = JSON.parse(Buffer.from(await tReader.read()).toString("utf8"));
          if (value.type === "terminal:frame") {
            await tSend(createMessage("terminal:ack", { terminalId: value.terminalId,
              runId: value.runId, attachmentId: value.attachmentId, sequence: value.sequence,
              checkoutId: value.checkoutId }));
          }
          if (predicate(value)) return value;
        }
      };
      await tSend(createMessage("terminal:subscribe", {
        terminalId, version: TERMINAL_PROTOCOL_VERSION, requestId: subscribeId,
      }));
      await tRead((value) => value.type === "terminal:subscribed" && value.requestId === subscribeId);
      await pSend(createMessage("terminal:input", { terminalId, data: "native-roundtrip\r" }));
      const output = await tRead((value) => value.type === "terminal:frame" && value.terminalId === terminalId &&
        value.ansi.includes("NATIVE_ECHO:native-roundtrip"));
      assert.ok(output.sequence > 0);
      await pSend(createMessage("terminal:stop", { terminalId }));
      await tRead((value) => value.type === "terminal:display:status" && value.terminalId === terminalId && value.code === "ENDED");
    }
    assert.equal(connection.stableId(), nativeConnectionId);
  }
  await fixture.host.handleRemoteAccessVerb({ id: "disable", type: "mobile-access:set", enabled: false });
  await connection.closed();
  console.log(JSON.stringify({ result: "pass", authorization: "fixture", native: "real", host: "real", confidentiality: "quic-tls",
    projects: projects.length, sharedConnection: true, centralOutage: true, remoteAccessOffClosed: true,
    terminalInputOutput: true, terminalFramesAcknowledged: true, managedCheckoutGit: true }));
} finally {
  clearTimeout(timeout);
  records?.close();
  await app.close();
  await fixture.dispose();
}
