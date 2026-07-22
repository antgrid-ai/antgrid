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

test("sessionLimit N then N+1 -> SESSION_LIMIT_EXCEEDED with ref=streamId; socket and other streams intact", async () => {
  const gate = makeFakeLicenseGate({ sessionLimit: 2 });
  relay = startServer(defaultConfig, { licenseGate: gate });
  const { ws } = await connectHello(relay, { deviceId: "stream-cap" });

  for (const id of ["s1", "s2"]) {
    const opened = waitForMessage(ws);
    ws.send(JSON.stringify({ type: "stream-open", streamId: id }));
    expect(await opened).toEqual({ type: "stream-opened", streamId: id });
  }

  const err = waitForMessage(ws);
  ws.send(JSON.stringify({ type: "stream-open", streamId: "s3" }));
  expect(await err).toMatchObject({
    type: "error",
    code: "SESSION_LIMIT_EXCEEDED",
    retryable: false,
    ref: "s3",
  });

  // Socket stays open; the two admitted streams are untouched.
  expect(relay.connections.getByDeviceId("stream-cap")?.openStreams.size).toBe(2);
  const closed = waitForMessage(ws);
  ws.send(JSON.stringify({ type: "stream-close", streamId: "s1" }));
  expect(await closed).toEqual({ type: "stream-closed", streamId: "s1" });
});

test("sessionLimit counts open streams across two connections sharing one license userId", async () => {
  const gate = makeFakeLicenseGate({ sessionLimit: 2, agentUid: () => "shared-account" });
  relay = startServer(defaultConfig, { licenseGate: gate });
  const a = await connectHello(relay, { deviceId: "stream-multi-a" });
  const b = await connectHello(relay, { deviceId: "stream-multi-b" });

  const openedA = waitForMessage(a.ws);
  a.ws.send(JSON.stringify({ type: "stream-open", streamId: "sa" }));
  await openedA;

  const openedB = waitForMessage(b.ws);
  b.ws.send(JSON.stringify({ type: "stream-open", streamId: "sb" }));
  await openedB;

  // The account's cap (2) is now exhausted across BOTH connections; a third
  // open on either one is rejected.
  const errA = waitForMessage(a.ws);
  a.ws.send(JSON.stringify({ type: "stream-open", streamId: "sc" }));
  expect(await errA).toMatchObject({ type: "error", code: "SESSION_LIMIT_EXCEEDED" });

  const errB = waitForMessage(b.ws);
  b.ws.send(JSON.stringify({ type: "stream-open", streamId: "sd" }));
  expect(await errB).toMatchObject({ type: "error", code: "SESSION_LIMIT_EXCEEDED" });
});

test("epoch supersession releases the superseded connection's stream count", async () => {
  const gate = makeFakeLicenseGate({ sessionLimit: 1 });
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

  // With sessionLimit 1, opening on the fresh connection only succeeds if the
  // old connection's single stream was actually released.
  const reopened = waitForMessage(fresh.ws);
  fresh.ws.send(JSON.stringify({ type: "stream-open", streamId: "s2" }));
  expect(await reopened).toEqual({ type: "stream-opened", streamId: "s2" });
});
