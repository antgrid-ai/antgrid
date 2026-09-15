import assert from "node:assert/strict";
import { createInterface } from "node:readline";
import { spawn } from "node:child_process";
import { resolve } from "node:path";

const { Endpoint, presetMinimal } = require("@number0/iroh/index.js");
const dartExecutable = process.env.IROH_QUALIFICATION_DART;
if (!dartExecutable) throw new Error("Set IROH_QUALIFICATION_DART to a Dart executable or compiled client");

const alpn = Array.from(Buffer.from("antgrid/peer/1"));
const builder = Endpoint.builder();
presetMinimal(builder);
builder.bindAddr("127.0.0.1:0");
builder.alpns([alpn]);
const endpoint = await builder.bind();
const args = process.env.IROH_QUALIFICATION_COMPILED === "1"
  ? [] : ["run", "bin/interop.dart"];
const child = spawn(dartExecutable, args, {
  cwd: process.env.IROH_QUALIFICATION_COMPILED === "1"
    ? undefined : resolve(import.meta.dir, "dart"),
  stdio: ["pipe", "pipe", "inherit"],
});
const exited = new Promise<number | null>((resolve, reject) => {
  child.once("exit", resolve);
  child.once("error", reject);
});
// Observe early failures even when the native accept is still pending.
void exited.catch(() => {});
const timer = setTimeout(() => {
  child.kill();
  console.error("FAIL: native interop exceeded 20 seconds");
  process.exit(1);
}, 20_000);
const stage = (name: string) => console.error(JSON.stringify({ stage: name }));
let connection;
try {
  const lines = createInterface({ input: child.stdout });
  const iterator = lines[Symbol.asyncIterator]();
  const first = await iterator.next();
  assert.equal(first.done, false, "Dart must report its authenticated endpoint identity");
  const { endpointId } = JSON.parse(first.value!);
  assert.match(endpointId, /^[0-9a-f]{64}$/);
  stage("dart-bound");
  child.stdin.end(JSON.stringify({
    endpointId: endpoint.id().toString(),
    addresses: endpoint.boundSockets().filter((address: string) => address.startsWith("127.0.0.1:")),
  }) + "\n");
  const incoming = await endpoint.acceptNext();
  stage("incoming");
  assert.ok(incoming);
  connection = await (await incoming.accept()).connect();
  stage("connected");
  assert.equal(connection.remoteId().toString(), endpointId);
  assert.deepEqual(connection.alpn(), alpn);
  const stream = await connection.acceptBi();
  stage("stream");
  const prefix = Buffer.from(await stream.recv.readExact(4));
  const length = prefix.readUInt32BE();
  assert.equal(length, 4096, "Reject unexpected lengths before requesting native allocation");
  const payload = Buffer.from(await stream.recv.readExact(length));
  assert.deepEqual(payload, Buffer.from(Array.from({ length }, (_, i) => i % 251)));
  await stream.send.writeAll(Array.from(Buffer.concat([prefix, payload])));
  await stream.send.finish();
  stage("echo-sent");
  const result = await iterator.next();
  assert.equal(result.done, false);
  assert.equal(JSON.parse(result.value!).check, "echo-pass");
  lines.close();
  assert.equal(await exited, 0);
  console.log(JSON.stringify({
    check: "bun-dart-native-interop", status: "pass", bytes: length,
    authenticatedRemoteIdentity: true, alpn: "antgrid/peer/1",
    profile: "loopback-no-relay", stats: connection.stats(),
  }));
} finally {
  child.kill();
  connection?.close(0n, []);
  await endpoint.close();
  clearTimeout(timer);
}
