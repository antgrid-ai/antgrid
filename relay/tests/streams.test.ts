import { test, expect, afterEach } from "bun:test";
import {
  startServer,
  defaultConfig,
  connectHello,
  makeFakeLicenseGate,
  waitForMessage,
  waitForType,
  type RelayServer,
} from "./helpers/relay-harness.js";

let relay: RelayServer | undefined;

afterEach(() => {
  relay?.stop();
  relay = undefined;
});

test("stream-open / stream-opened ack", async () => {
  relay = startServer(defaultConfig);
  const { ws } = await connectHello(relay, { deviceId: "stream-basic" });

  const opened = waitForMessage(ws);
  ws.send(JSON.stringify({ type: "stream-open", streamId: "s1" }));
  expect(await opened).toEqual({ type: "stream-opened", streamId: "s1" });
});

test("stream-close is idempotent", async () => {
  relay = startServer(defaultConfig);
  const { ws } = await connectHello(relay, { deviceId: "stream-close-idem" });

  const opened = waitForMessage(ws);
  ws.send(JSON.stringify({ type: "stream-open", streamId: "s1" }));
  await opened;

  const closed1 = waitForMessage(ws);
  ws.send(JSON.stringify({ type: "stream-close", streamId: "s1" }));
  expect(await closed1).toEqual({ type: "stream-closed", streamId: "s1" });

  const closed2 = waitForMessage(ws);
  ws.send(JSON.stringify({ type: "stream-close", streamId: "s1" }));
  expect(await closed2).toEqual({ type: "stream-closed", streamId: "s1" });
});

test("stream-open from an app is WRONG_DEVICE_TYPE", async () => {
  relay = startServer(defaultConfig);
  const { ws } = await connectHello(relay, { deviceId: "stream-app", deviceType: "app" });

  const err = waitForMessage(ws);
  ws.send(JSON.stringify({ type: "stream-open", streamId: "s1" }));
  expect(await err).toMatchObject({ type: "error", code: "WRONG_DEVICE_TYPE", retryable: false });
});

// Stream admission is uncapped: the paid axis is a worker (agent-device) cap
// web enforces at registration, so a fleet view or warm-project LRU may fan out
// as many streams as it likes without paying for them.
test("many streams are admitted on one connection", async () => {
  relay = startServer(defaultConfig);
  const { ws } = await connectHello(relay, { deviceId: "stream-many" });

  const ids = ["s1", "s2", "s3", "s4", "s5", "s6", "s7", "s8"];
  for (const id of ids) {
    const opened = waitForMessage(ws);
    ws.send(JSON.stringify({ type: "stream-open", streamId: id }));
    expect(await opened).toEqual({ type: "stream-opened", streamId: id });
  }

  expect(relay.connections.getByDeviceId("stream-many")?.openStreams.size).toBe(ids.length);
  const closed = waitForMessage(ws);
  ws.send(JSON.stringify({ type: "stream-close", streamId: "s1" }));
  expect(await closed).toEqual({ type: "stream-closed", streamId: "s1" });
});

test("the per-connection ceiling rejects the overflowing stream and keeps the socket", async () => {
  relay = startServer({ ...defaultConfig, maxStreamsPerConnection: 3 });
  const { ws } = await connectHello(relay, { deviceId: "stream-ceiling" });

  for (const id of ["s1", "s2", "s3"]) {
    const opened = waitForMessage(ws);
    ws.send(JSON.stringify({ type: "stream-open", streamId: id }));
    expect(await opened).toEqual({ type: "stream-opened", streamId: id });
  }

  const rejected = waitForMessage(ws);
  ws.send(JSON.stringify({ type: "stream-open", streamId: "s4" }));
  expect(await rejected).toMatchObject({
    type: "error",
    code: "STREAM_LIMIT_EXCEEDED",
    retryable: false,
    ref: "s4",
  });
  expect(relay.connections.getByDeviceId("stream-ceiling")?.openStreams.size).toBe(3);

  // Stream errors never close the socket (error contract), and freeing a slot
  // makes the connection usable again rather than needing a reconnect.
  const closed = waitForMessage(ws);
  ws.send(JSON.stringify({ type: "stream-close", streamId: "s1" }));
  expect(await closed).toEqual({ type: "stream-closed", streamId: "s1" });
  const reopened = waitForMessage(ws);
  ws.send(JSON.stringify({ type: "stream-open", streamId: "s4" }));
  expect(await reopened).toEqual({ type: "stream-opened", streamId: "s4" });
});

test("re-opening a held stream at the ceiling is admitted, not rejected", async () => {
  // The mux re-opens every attached stream on each `welcome`; a re-open cannot
  // grow the set, so the ceiling must not reject it.
  relay = startServer({ ...defaultConfig, maxStreamsPerConnection: 2 });
  const { ws } = await connectHello(relay, { deviceId: "stream-reopen" });

  for (const id of ["s1", "s2"]) {
    const opened = waitForMessage(ws);
    ws.send(JSON.stringify({ type: "stream-open", streamId: id }));
    expect(await opened).toEqual({ type: "stream-opened", streamId: id });
  }

  const reopened = waitForMessage(ws);
  ws.send(JSON.stringify({ type: "stream-open", streamId: "s2" }));
  expect(await reopened).toEqual({ type: "stream-opened", streamId: "s2" });
  expect(relay.connections.getByDeviceId("stream-reopen")?.openStreams.size).toBe(2);
});

test("streams on two connections sharing one license userId are all admitted", async () => {
  const gate = makeFakeLicenseGate({ agentUid: () => "shared-account" });
  relay = startServer(defaultConfig, { licenseGate: gate });
  const a = await connectHello(relay, { deviceId: "stream-multi-a" });
  const b = await connectHello(relay, { deviceId: "stream-multi-b" });

  for (const [side, ids] of [[a, ["sa", "sc"]], [b, ["sb", "sd"]]] as const) {
    for (const id of ids) {
      const opened = waitForMessage(side.ws);
      side.ws.send(JSON.stringify({ type: "stream-open", streamId: id }));
      expect(await opened).toEqual({ type: "stream-opened", streamId: id });
    }
  }

  expect(relay.connections.countOpenStreamsForUser("shared-account")).toBe(4);
});

test("epoch supersession releases the superseded connection's stream count", async () => {
  const gate = makeFakeLicenseGate({ agentUid: () => "supersede-account" });
  relay = startServer(defaultConfig, { licenseGate: gate });
  const deviceId = "stream-supersede";

  const old = await connectHello(relay, { deviceId, epoch: 1 });
  const opened = waitForMessage(old.ws);
  old.ws.send(JSON.stringify({ type: "stream-open", streamId: "s1" }));
  await opened;

  const oldErr = waitForType(old.ws, "error");
  const fresh = await connectHello(relay, {
    deviceId,
    epoch: 2,
    publicKeyBase64: old.publicKeyBase64,
    privateSeed: old.privateSeed,
  });
  await oldErr;

  // The superseded connection's entry is gone, taking its openStreams with it,
  // so the account's total reflects only the successor's re-opened stream.
  const reopened = waitForMessage(fresh.ws);
  fresh.ws.send(JSON.stringify({ type: "stream-open", streamId: "s2" }));
  expect(await reopened).toEqual({ type: "stream-opened", streamId: "s2" });
  expect(relay.connections.countOpenStreamsForUser("supersede-account")).toBe(1);
});
