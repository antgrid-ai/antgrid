import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { Endpoint, EndpointAddr, EndpointId } from "@number0/iroh/index.js";
import { decodePeerFrame, encodePeerFrame } from "antgrid-wire";
import { PeerRecords } from "../src/peer/records";
import { createMessage } from "../src/protocol";
import { TERMINAL_PROTOCOL_VERSION } from "../src/terminal-frames/protocol";
import { device, startSmokeFixture } from "./iroh-smoke-fixture";

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
  connection = await app.connect(new EndpointAddr(EndpointId.fromString(native.endpointId), undefined, native.addresses), Array.from(Buffer.from("antgrid/peer/1")));
  const stream = await connection.openBi();
  records = new PeerRecords(stream, () => true, () => connection?.close(1n, []));
  const attemptId = randomUUID();
  const send = (value: object) => records!.send(encodePeerFrame({ type: "message", channel: "control" }, Buffer.from(JSON.stringify(value), "utf8")));
  const read = async (predicate: (value: any) => boolean): Promise<any> => {
    for (;;) {
      const frame = decodePeerFrame(await records!.read());
      const value = JSON.parse(Buffer.from(frame.payload).toString("utf8"));
      const message = value.m ?? value;
      if (message.type === "terminal:frame") {
        await send({ s: value.s, m: createMessage("terminal:ack", { terminalId: message.terminalId,
          runId: message.runId, attachmentId: message.attachmentId, sequence: message.sequence,
          checkoutId: message.checkoutId }) });
      }
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
    await send({ m: createMessage("project:start", { projectId: project.id }) });
    const ready = await read((value) => value.type === "stream-ready" && value.projectId === project.id);
    await send({ s: ready.streamId, m: createMessage("file:read", { projectId: project.id, path: "proof.txt" }) });
    const file = await read((value) => value.type === "file:content" && value.projectId === project.id);
    assert.equal(file.content, `${project.name}:native-host-proof`);
    if (project.name === "alpha") {
      const requestId = randomUUID();
      await send({ s: ready.streamId, m: createMessage("session:create", {
        requestId, name: "native-checkout", isolation: "worktree",
      }) });
      const created = await read((value) => value.type === "session:result" && value.requestId === requestId);
      assert.equal(created.ok, true);
      assert.equal(created.session.checkoutKind, "managed-worktree");
      await send({ s: ready.streamId, m: createMessage("git:list-branches", {
        projectId: project.id, checkoutId: created.session.checkoutId,
      }) });
      const branches = await read((value) => value.type === "git:branches" && value.checkoutId === created.session.checkoutId);
      assert.equal(branches.current, created.session.checkoutBranch);

      const terminalId = "native-echo";
      await send({ s: ready.streamId, m: createMessage("terminal:start", {
        terminalId, name: terminalId, command: "node", args: ["native-echo.cjs"],
      }) });
      await read((value) => value.type === "terminal:started" && value.terminalId === terminalId);
      const subscribeId = randomUUID();
      await send({ s: ready.streamId, m: createMessage("terminal:subscribe", {
        terminalId, version: TERMINAL_PROTOCOL_VERSION, requestId: subscribeId,
      }) });
      await read((value) => value.type === "terminal:subscribed" && value.requestId === subscribeId);
      await send({ s: ready.streamId, m: createMessage("terminal:input", { terminalId, data: "native-roundtrip\r" }) });
      const output = await read((value) => value.type === "terminal:frame" && value.terminalId === terminalId &&
        value.ansi.includes("NATIVE_ECHO:native-roundtrip"));
      assert.ok(output.sequence > 0);
      await send({ s: ready.streamId, m: createMessage("terminal:stop", { terminalId }) });
      await read((value) => value.type === "terminal:display:status" && value.terminalId === terminalId && value.code === "ENDED");
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
