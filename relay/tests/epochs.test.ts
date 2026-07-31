import { test, expect, afterEach } from "bun:test";
import {
  startServer,
  defaultConfig,
  connect,
  connectHello,
  makeHello,
  waitForMessage,
  waitForType,
  generateKeyPair,
  type RelayServer,
} from "./helpers/relay-harness.js";

let relay: RelayServer | undefined;

afterEach(() => {
  relay?.stop();
  relay = undefined;
});

test("higher epoch supersedes: old socket gets SUPERSEDED then close, its streams are released", async () => {
  relay = startServer(defaultConfig);
  const deviceId = "epoch-agent";
  const identity = await generateKeyPair();

  const old = await connectHello(relay, {
    deviceId,
    epoch: 100,
    publicKeyBase64: identity.publicKeyBase64,
    privateSeed: identity.privateSeed,
  });
  const oldClosePromise = new Promise<number>((resolve) => { old.ws.onclose = (e) => resolve(e.code); });

  // Occupy a stream slot on the old connection.
  const openedOld = waitForType(old.ws, "stream-opened");
  old.ws.send(JSON.stringify({ type: "stream-open", streamId: "s-old" }));
  await openedOld;
  expect(relay.connections.countOpenStreamsForUser(`user-${deviceId}`)).toBe(1);

  const oldErr = waitForType(old.ws, "error");
  const fresh = await connectHello(relay, {
    deviceId,
    epoch: 200,
    publicKeyBase64: identity.publicKeyBase64,
    privateSeed: identity.privateSeed,
  });
  expect(fresh.welcome).toMatchObject({ type: "welcome", deviceId, epoch: 200 });

  const err = await oldErr;
  expect(err).toMatchObject({ type: "error", code: "SUPERSEDED", retryable: false });
  expect(await oldClosePromise).toBe(1008);

  // The old connection's stream was released BEFORE the new one was inserted
  // — the count never double-charges one device across a restart.
  expect(relay.connections.countOpenStreamsForUser(`user-${deviceId}`)).toBe(0);
  const openedNew = waitForType(fresh.ws, "stream-opened");
  fresh.ws.send(JSON.stringify({ type: "stream-open", streamId: "s-new" }));
  await openedNew;
  expect(relay.connections.countOpenStreamsForUser(`user-${deviceId}`)).toBe(1);
});

test("lower epoch is rejected: new socket gets SUPERSEDED, old connection is untouched", async () => {
  relay = startServer(defaultConfig);
  const deviceId = "epoch-lower";
  const identity = await generateKeyPair();

  const old = await connectHello(relay, {
    deviceId,
    epoch: 500,
    publicKeyBase64: identity.publicKeyBase64,
    privateSeed: identity.privateSeed,
  });

  const { hello } = await makeHello(relay, {
    deviceId,
    epoch: 100,
    publicKeyBase64: identity.publicKeyBase64,
    privateSeed: identity.privateSeed,
  });
  const ws2 = await connect(relay);
  const err2 = waitForMessage(ws2);
  const closed2 = new Promise<number>((resolve) => { ws2.onclose = (e) => resolve(e.code); });
  ws2.send(JSON.stringify(hello));
  expect(await err2).toMatchObject({ type: "error", code: "SUPERSEDED", retryable: false });
  expect(await closed2).toBe(1008);

  // The original connection is still the live holder and fully functional.
  expect(relay.connections.getByDeviceId(deviceId)).toBeDefined();
  const stillOpened = waitForType(old.ws, "stream-opened");
  old.ws.send(JSON.stringify({ type: "stream-open", streamId: "still-alive" }));
  await stillOpened;
});

test("equal epoch under the same key admits: a redial evicts its own zombie", async () => {
  relay = startServer(defaultConfig);
  const deviceId = "epoch-equal";
  const identity = await generateKeyPair();

  // The half-open scenario: the client's watchdog closed this socket and
  // redialed, but the relay hasn't reaped it yet. Same process ⇒ same epoch.
  const zombie = await connectHello(relay, {
    deviceId,
    epoch: 300,
    publicKeyBase64: identity.publicKeyBase64,
    privateSeed: identity.privateSeed,
  });
  const zombieErr = waitForType(zombie.ws, "error");
  const zombieClosed = new Promise<number>((resolve) => { zombie.ws.onclose = (e) => resolve(e.code); });

  const redial = await connectHello(relay, {
    deviceId,
    epoch: 300,
    publicKeyBase64: identity.publicKeyBase64,
    privateSeed: identity.privateSeed,
  });
  expect(redial.welcome).toMatchObject({ type: "welcome", deviceId, epoch: 300 });

  expect(await zombieErr).toMatchObject({ type: "error", code: "SUPERSEDED", retryable: false });
  expect(await zombieClosed).toBe(1008);

  // The redial is the live holder and fully functional.
  const opened = waitForType(redial.ws, "stream-opened");
  redial.ws.send(JSON.stringify({ type: "stream-open", streamId: "post-redial" }));
  await opened;
});

test("a replayed hello cannot evict the connection it admitted", async () => {
  relay = startServer(defaultConfig);
  const deviceId = "epoch-replay";
  const identity = await generateKeyPair();
  const nonce = Buffer.from(crypto.getRandomValues(new Uint8Array(16))).toString("base64");

  const live = await connectHello(relay, {
    deviceId,
    epoch: 400,
    nonce,
    publicKeyBase64: identity.publicKeyBase64,
    privateSeed: identity.privateSeed,
  });

  // Byte-identical replay of the admitting frame — what an attacker who
  // captured it holds. The replay cache normally catches this, but it is
  // capacity-bounded and empty after a restart, so arbitration must not be the
  // only thing standing between a captured frame and a live device's socket.
  const { hello } = await makeHello(relay, {
    deviceId,
    epoch: 400,
    nonce,
    publicKeyBase64: identity.publicKeyBase64,
    privateSeed: identity.privateSeed,
  });
  const ws2 = await connect(relay);
  const err2 = waitForMessage(ws2);
  const closed2 = new Promise<number>((resolve) => { ws2.onclose = (e) => resolve(e.code); });
  ws2.send(JSON.stringify(hello));
  expect(await err2).toMatchObject({ type: "error", retryable: false });
  expect(await closed2).toBe(1008);

  // The live connection is untouched and still usable.
  expect(relay.connections.getByDeviceId(deviceId)).toBeDefined();
  const stillOpened = waitForType(live.ws, "stream-opened");
  live.ws.send(JSON.stringify({ type: "stream-open", streamId: "survived-replay" }));
  await stillOpened;
});

test("pubkey mismatch against a live holder is rejected regardless of epoch", async () => {
  relay = startServer(defaultConfig);
  const deviceId = "epoch-pubkey-conflict";
  const original = await connectHello(relay, { deviceId, epoch: 100 });

  // A different keypair claiming the SAME deviceId with a HIGHER epoch — the
  // conflict is an identity conflict, not an epoch race, so it still loses.
  const ws2 = await connect(relay);
  const err2 = waitForMessage(ws2);
  const closed2 = new Promise<number>((resolve) => { ws2.onclose = (e) => resolve(e.code); });
  const { hello } = await makeHello(relay, { deviceId, epoch: 999 });
  ws2.send(JSON.stringify(hello));
  const err = await err2;
  expect(err).toMatchObject({ type: "error", code: "AUTH_FAILED", retryable: false });
  expect(await closed2).toBe(1008);

  // The original connection is untouched.
  const stillOpened = waitForType(original.ws, "stream-opened");
  original.ws.send(JSON.stringify({ type: "stream-open", streamId: "untouched" }));
  await stillOpened;
});

test("restart with a higher epoch admits instantly — no 60s wait", async () => {
  relay = startServer(defaultConfig);
  const deviceId = "epoch-restart";
  const identity = await generateKeyPair();

  await connectHello(relay, {
    deviceId,
    epoch: 1,
    publicKeyBase64: identity.publicKeyBase64,
    privateSeed: identity.privateSeed,
  });

  const start = Date.now();
  const restarted = await connectHello(relay, {
    deviceId,
    epoch: 2,
    publicKeyBase64: identity.publicKeyBase64,
    privateSeed: identity.privateSeed,
  });
  const elapsedMs = Date.now() - start;

  expect(restarted.welcome).toMatchObject({ type: "welcome", deviceId, epoch: 2 });
  // Well under the deleted v2 60s ACTIVE_THRESHOLD_MS heuristic.
  expect(elapsedMs).toBeLessThan(2_000);
});
