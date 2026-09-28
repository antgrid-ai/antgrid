import assert from "node:assert/strict";
import { Endpoint, EndpointAddr, EndpointId } from "@number0/iroh/index.js";
import { PEER_ALPN, encodeStreamOpen } from "antgrid-wire";
import { StreamRecordReader, StreamRecordWriter } from "../src/peer/stream-records";

// Compiled-binary transport smoke: CI compiles this with `bun build --compile`
// and runs the resulting executable on each desktop platform. That is the only
// way to prove the @number0/iroh native addon loads and dials from INSIDE a
// single-file bridge binary — source-run evals never touch that binary shape.
// HostServer, project, git and terminal behavior are proved by the evals
// suite against a source-run bridge; duplicating them here would only make
// the compiled binary slower to build and run without proving anything new
// about the binary itself.
const MAX_RECORD_BYTES = 4096;
// A hung native handle keeps the process alive, so a timeout that only set the
// exit code would stall the CI job instead of failing it.
const timeout = setTimeout(() => {
  console.error("iroh-host-smoke timed out");
  process.exit(1);
}, 15_000);

const hostBuilder = Endpoint.builder();
hostBuilder.applyMinimal();
hostBuilder.bindAddr("127.0.0.1:0");
// The accepting side must advertise the protocol before bind, or a connect
// offering it sees no matching ALPN and fails the handshake; the dialing
// side passes its ALPN list straight to `connect()` instead (below).
hostBuilder.alpns([Array.from(Buffer.from(PEER_ALPN))]);
const host = await hostBuilder.bind();

const clientBuilder = Endpoint.builder();
clientBuilder.applyMinimal();
clientBuilder.bindAddr("127.0.0.1:0");
const client = await clientBuilder.bind();

try {
  const accepted = host.acceptNext().then(async (incoming) => {
    if (!incoming) throw new Error("host endpoint closed before accepting a connection");
    const accepting = await incoming.accept();
    return accepting.connect();
  });

  const hostAddr = new EndpointAddr(
    EndpointId.fromString(host.id().toString()),
    undefined,
    host.boundSockets().filter((address) => address.startsWith("127.0.0.1:")),
  );
  const clientConnection = await client.connect(hostAddr, Array.from(Buffer.from(PEER_ALPN)));
  const hostConnection = await accepted;

  // A native bidi stream is invisible to the peer until its first write, so
  // `acceptBi()` on the host side cannot be raced against `openBi()` here —
  // it has to wait until the client has actually written something.
  const clientStream = await clientConnection.openBi();
  const clientWriter = new StreamRecordWriter(
    clientStream, () => true, () => clientConnection.close(1n, []), MAX_RECORD_BYTES,
  );
  // Every native bidi stream opens with a StreamOpen record before anything
  // else — round-trip that same production framing, not a script-local shape.
  void clientWriter.send(encodeStreamOpen({ kind: "session" }));

  const hostStream = await hostConnection.acceptBi();
  const hostReader = new StreamRecordReader({ recv: hostStream.recv }, MAX_RECORD_BYTES, () => {});
  const hostWriter = new StreamRecordWriter(
    hostStream, () => true, () => hostConnection.close(1n, []), MAX_RECORD_BYTES,
  );
  const clientReader = new StreamRecordReader({ recv: clientStream.recv }, MAX_RECORD_BYTES, () => {});

  const opened = await hostReader.read();
  assert.ok(opened.byteLength > 0, "host never observed the StreamOpen record");

  const payload = Buffer.from("iroh-host-smoke-roundtrip");
  void hostWriter.send(payload);
  const echoed = Buffer.from(await clientReader.read());
  assert.equal(echoed.toString("utf8"), payload.toString("utf8"));

  console.log(JSON.stringify({ result: "pass", native: "real", roundTrip: true }));
} finally {
  clearTimeout(timeout);
  await client.close();
  await host.close();
}
