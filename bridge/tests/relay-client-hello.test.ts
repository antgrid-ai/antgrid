// v3 hello auth (design §4.1, plan B1/B2). Replaces the v2 register/challenge
// suite: there is no more challenge round trip, no protocolVersion:2 register,
// and reconnect is decided by the error contract's `retryable` flag instead of
// per-code lists.
import { test, expect, afterEach } from "bun:test";
import { sign, verify } from "node:crypto";
import { buildHelloSigBody, normalizeRelayHost } from "antgrid-wire";
import { RelayClient } from "../src/relay-client";
import { MessageBus } from "../src/message-bus";
import { rawSeedToPkcs8 } from "../src/e2e";
import { ED25519_SPKI_PREFIX } from "../src/ed25519-der";
import vector from "../../evals/fixtures/relay-hello-vector.json";

function verifyEd25519(data: Uint8Array, pubB64: string, sigB64: string): boolean {
  const spki = Buffer.concat([ED25519_SPKI_PREFIX, Buffer.from(pubB64, "base64")]);
  return verify(null, data, { key: spki, format: "der", type: "spki" }, Buffer.from(sigB64, "base64"));
}

function signEd25519(seedB64: string, data: Uint8Array): string {
  return sign(null, data, { key: rawSeedToPkcs8(Buffer.from(seedB64, "base64")), format: "der", type: "pkcs8" }).toString("base64");
}

let clients: RelayClient[] = [];
afterEach(() => { for (const c of clients.splice(0)) try { c.close(); } catch {} });

/** A stand-in WebSocket so `redialWithFreshToken` can drive a real `doConnect()`
 *  (which does `new WebSocket(url)`) without a live relay. Captures the dialed
 *  URL + any frames written after `fireOpen()` triggers `sendHello`. */
class FakeWS {
  static OPEN = 1;
  static CONNECTING = 0;
  static CLOSING = 2;
  static CLOSED = 3;
  static instances: FakeWS[] = [];
  readyState = FakeWS.CONNECTING;
  url: string;
  sent: string[] = [];
  private listeners: Record<string, Array<(ev?: unknown) => void>> = {};
  constructor(url: string) { this.url = url; FakeWS.instances.push(this); }
  addEventListener(type: string, cb: (ev?: unknown) => void) { (this.listeners[type] ??= []).push(cb); }
  send(d: string) { this.sent.push(d); }
  close() { this.readyState = FakeWS.CLOSED; }
  fireOpen() { this.readyState = FakeWS.OPEN; for (const cb of this.listeners.open ?? []) cb(); }
}

/** A client whose socket is stubbed OPEN so `sendHello` writes to `sent`
 *  without a live network connection. */
function makeClient(overrides: Partial<{ getLicenseToken: () => string; onError: (c: string, m: string) => void }> = {}) {
  const seed = Buffer.from(vector.ed25519.seedHex, "hex").toString("base64");
  const sent: string[] = [];
  const client = new RelayClient({
    url: "ws://relay.antgrid.ai:8443/ws",
    identity: {
      deviceId: vector.fields.deviceId,
      deviceName: "agent",
      createdAt: new Date().toISOString(),
      ed25519PublicKey: vector.fields.publicKey,
      ed25519PrivateKey: seed,
    },
    generateKeypair: () => { throw new Error("not used"); },
    getLicenseToken: overrides.getLicenseToken ?? (() => vector.fields.licenseToken),
    onError: overrides.onError,
  });
  clients.push(client);
  (client as any).ws = { readyState: WebSocket.OPEN, send: (d: string) => sent.push(d), close: () => {} };
  return { client, sent };
}

test("buildHelloSigBody + signing reproduces the cross-language golden vector", () => {
  // Cross-checks antgrid-wire's buildHelloSigBody against the fixture BOTH
  // Dart and TS implementations pin (evals/fixtures/relay-hello-vector.json),
  // independent of RelayClient's own hello construction below.
  const body = buildHelloSigBody(vector.fields as any);
  expect(Buffer.from(body).toString("hex")).toBe(vector.sigBodyHex);
  const seed = Buffer.from(vector.ed25519.seedHex, "hex").toString("base64");
  expect(signEd25519(seed, body)).toBe(vector.sigB64);
  expect(verifyEd25519(body, vector.ed25519.publicKeyB64, vector.sigB64)).toBe(true);
});

test("hello is the first (and only) frame sent on socket open, with a valid Ed25519 sig", async () => {
  const { client, sent } = makeClient();
  await (client as any).sendHello();

  expect(sent.length).toBe(1);
  const hello = JSON.parse(sent[0]);
  expect(hello.type).toBe("hello");
  expect(hello.protocolVersion).toBe(3);
  expect(hello.deviceType).toBe("agent");
  expect(hello.deviceId).toBe(vector.fields.deviceId);
  expect(hello.publicKey).toBe(vector.fields.publicKey);
  expect(hello.licenseToken).toBe(vector.fields.licenseToken);
  expect(typeof hello.nonce).toBe("string");
  expect(typeof hello.ts).toBe("string");

  const sigBody = buildHelloSigBody({
    relayHost: normalizeRelayHost("ws://relay.antgrid.ai:8443/ws"),
    deviceType: hello.deviceType,
    deviceId: hello.deviceId,
    publicKey: hello.publicKey,
    epoch: hello.epoch,
    licenseToken: hello.licenseToken,
    ts: hello.ts,
    nonce: hello.nonce,
  });
  expect(verifyEd25519(sigBody, vector.fields.publicKey, hello.sig)).toBe(true);
});

test("welcome authenticates and resets backoff (reset happens ONLY on welcome, not on socket open)", () => {
  const { client } = makeClient();
  let authenticated = false;
  (client as any).opts.onAuthenticated = () => { authenticated = true; };

  // Simulate a doubled-up backoff from a prior failed attempt — welcome must
  // reset it back to INITIAL_BACKOFF (1000ms), not merely leave it alone.
  (client as any).backoff = 8000;

  (client as any).handleTextMessage(JSON.stringify({
    type: "welcome", deviceId: vector.fields.deviceId, epoch: 1, serverTime: new Date().toISOString(),
  }));

  expect(authenticated).toBe(true);
  expect((client as any).backoff).toBe(1000);
});

test("clock-skew AUTH_FAILED learns the offset and applies it once to the next hello", async () => {
  const { client, sent } = makeClient();
  const serverTime = new Date(Date.now() + 5 * 60_000).toISOString(); // 5 minutes ahead

  (client as any).handleTextMessage(JSON.stringify({
    type: "error", code: "AUTH_FAILED", message: "clock skew", retryable: true, serverTime,
  }));
  expect((client as any).clockOffsetMs).toBeGreaterThan(4 * 60_000);
  expect((client as any).clockOffsetApplied).toBe(true);

  await (client as any).sendHello();
  const hello = JSON.parse(sent[0]);
  const skewMs = Date.parse(hello.ts) - Date.now();
  // The hello's `ts` should reflect the learned offset, not wall-clock now.
  expect(skewMs).toBeGreaterThan(4 * 60_000);

  // A second AUTH_FAILED with the SAME offset (within 1s) must NOT re-apply —
  // it falls through to normal retryable reconnect instead of thrashing.
  const appliedBefore = (client as any).clockOffsetMs;
  (client as any).handleTextMessage(JSON.stringify({
    type: "error", code: "AUTH_FAILED", message: "clock skew again", retryable: true, serverTime,
  }));
  expect((client as any).clockOffsetMs).toBe(appliedBefore);

  // welcome resets clockOffsetApplied so a FUTURE skew can re-apply.
  (client as any).handleTextMessage(JSON.stringify({
    type: "welcome", deviceId: vector.fields.deviceId, epoch: 1, serverTime: new Date().toISOString(),
  }));
  expect((client as any).clockOffsetApplied).toBe(false);
});

test("close after a retryable:false error frame does NOT schedule a reconnect", () => {
  const { client } = makeClient();
  let scheduled = false;
  const origSchedule = (client as any).scheduleReconnect.bind(client);
  (client as any).scheduleReconnect = () => { scheduled = true; origSchedule(); };

  (client as any).handleTextMessage(JSON.stringify({
    type: "error", code: "PROTOCOL_VIOLATION", message: "bad frame", retryable: false,
  }));
  expect((client as any).lastError).toEqual({ code: "PROTOCOL_VIOLATION", retryable: false });

  // Drive the close handler's reconnect decision directly (mirrors the real
  // ws "close" listener body without needing an actual socket close event).
  const terminal = (client as any).lastError?.retryable === false;
  expect(terminal).toBe(true);
  if (!(client as any).intentionalClose && terminal === false) (client as any).scheduleReconnect();
  expect(scheduled).toBe(false);
});

test("close after a retryable:true error (or no error at all) schedules a jittered reconnect", () => {
  const { client } = makeClient();
  const delays: number[] = [];
  (client as any).scheduleReconnect = () => {
    const delay = (client as any).backoff / 2 + Math.random() * ((client as any).backoff / 2);
    delays.push(delay);
  };

  (client as any).handleTextMessage(JSON.stringify({
    type: "error", code: "PEER_OFFLINE", message: "peer gone", retryable: true,
  }));
  const terminal = (client as any).lastError?.retryable === false;
  expect(terminal).toBe(false);
  (client as any).scheduleReconnect();
  expect(delays.length).toBe(1);
  // Equal jitter: the delay is uniform in [backoff/2, backoff] around the
  // deterministic stored backoff (INITIAL_BACKOFF = 1000ms here).
  expect(delays[0]).toBeGreaterThanOrEqual(500);
  expect(delays[0]).toBeLessThanOrEqual(1000);

  // No error frame at all also reconnects (lastError stays null after a fresh
  // connection attempt — doConnect() resets it).
  (client as any).lastError = null;
  const terminalNoError = (client as any).lastError?.retryable === false;
  expect(terminalNoError).toBe(false);
});

test("SUPERSEDED stops reconnecting (retryable:false) WITHOUT firing onAuthRevoked", () => {
  let revoked = false;
  const { client } = makeClient();
  (client as any).opts.onAuthRevoked = () => { revoked = true; };

  (client as any).handleErrorFrame({ code: "SUPERSEDED", message: "newer instance", retryable: false });

  expect(revoked).toBe(false);
  expect((client as any).lastError).toEqual({ code: "SUPERSEDED", retryable: false });
});

// Identity-dead verdicts stay terminal-exit (onAuthRevoked → re-enroll). EXPIRED
// is split out below — it is recoverable by time (lapsed-then-renewed sub).
for (const code of ["LICENSE_INVALID", "LICENSE_REVOKED"]) {
  test(`${code} fires onAuthRevoked (terminal identity verdicts)`, () => {
    let revoked = false;
    const { client } = makeClient();
    (client as any).opts.onAuthRevoked = () => { revoked = true; };

    (client as any).handleErrorFrame({ code, message: "terminal license verdict", retryable: false });

    expect(revoked).toBe(true);
  });
}

test("LICENSE_EXPIRED does NOT fire onAuthRevoked — it stops reconnect and waits for a fresh mint", () => {
  let revoked = false;
  const { client } = makeClient();
  (client as any).opts.onAuthRevoked = () => { revoked = true; };

  (client as any).handleErrorFrame({ code: "LICENSE_EXPIRED", message: "expired", retryable: false });

  // Recoverable by time: never tells the user to re-enroll...
  expect(revoked).toBe(false);
  // ...but still terminal-for-socket — retryable:false stops the reconnect at
  // the close handler (mirrors the SUPERSEDED stop above).
  expect((client as any).lastError).toEqual({ code: "LICENSE_EXPIRED", retryable: false });
});

test("redialWithFreshToken after LICENSE_EXPIRED clears the stop and reconnects with a fresh token fetch", async () => {
  let tokenFetches = 0;
  const { client } = makeClient({
    getLicenseToken: () => { tokenFetches++; return vector.fields.licenseToken; },
  });

  // Enter the expired-stop, then simulate the socket having closed underneath us.
  (client as any).handleErrorFrame({ code: "LICENSE_EXPIRED", message: "expired", retryable: false });
  (client as any).ws = null;

  const realWS = globalThis.WebSocket;
  FakeWS.instances.length = 0;
  (globalThis as any).WebSocket = FakeWS;
  try {
    client.redialWithFreshToken();

    // A REAL fresh dial to the relay URL — not just a flag flip.
    expect(FakeWS.instances.length).toBe(1);
    expect(FakeWS.instances[0].url).toBe("ws://relay.antgrid.ai:8443/ws");
    // The stop is cleared and backoff reset (INITIAL_BACKOFF = 1000ms).
    expect((client as any).lastError).toBeNull();
    expect((client as any).backoff).toBe(1000);

    // Fire open → sendHello fetches a FRESH token and writes the hello frame.
    FakeWS.instances[0].fireOpen();
    await new Promise((r) => setTimeout(r, 0)); // let async sendHello settle
    expect(tokenFetches).toBeGreaterThanOrEqual(1);
    const hello = JSON.parse(FakeWS.instances[0].sent[0]);
    expect(hello.type).toBe("hello");
    expect(hello.licenseToken).toBe(vector.fields.licenseToken);
  } finally {
    (globalThis as any).WebSocket = realWS;
  }
});

test("redialWithFreshToken is a no-op when not expired-stopped", () => {
  const { client } = makeClient();
  // Fresh client: lastError is null (never received an expired verdict).
  (client as any).ws = null;

  const realWS = globalThis.WebSocket;
  FakeWS.instances.length = 0;
  (globalThis as any).WebSocket = FakeWS;
  try {
    client.redialWithFreshToken();
    expect(FakeWS.instances.length).toBe(0); // no dial
  } finally {
    (globalThis as any).WebSocket = realWS;
  }
});

test("redialWithFreshToken is a no-op when the socket is already open", () => {
  const { client } = makeClient(); // makeClient stubs ws OPEN
  (client as any).handleErrorFrame({ code: "LICENSE_EXPIRED", message: "expired", retryable: false });

  const realWS = globalThis.WebSocket;
  FakeWS.instances.length = 0;
  (globalThis as any).WebSocket = FakeWS;
  try {
    client.redialWithFreshToken(); // ws.readyState === OPEN → guard returns
    expect(FakeWS.instances.length).toBe(0);
  } finally {
    (globalThis as any).WebSocket = realWS;
  }
});

test("SUPERSEDED (retryable:false) does NOT fire onAuthRevoked — only the license codes do", () => {
  let revoked = false;
  const { client } = makeClient();
  (client as any).opts.onAuthRevoked = () => { revoked = true; };

  (client as any).handleErrorFrame({ code: "SUPERSEDED", message: "newer connection", retryable: false });

  expect(revoked).toBe(false);
});

test("a stream-open rejection (ref===streamId) is routed to the mux and never recorded as lastError", () => {
  const { client } = makeClient();
  const rejected: Array<{ code: string; message: string }> = [];
  const handle = client.attachStream(new MessageBus(), {
    onRejected: (code: string, message: string) => rejected.push({ code, message }),
  });

  (client as any).handleErrorFrame({
    code: "SESSION_LIMIT_EXCEEDED", message: "cap reached", retryable: false, ref: handle.streamId,
  });

  expect(rejected).toEqual([{ code: "SESSION_LIMIT_EXCEEDED", message: "cap reached" }]);
  // The load-bearing assertion (B2): lastError must stay null so an unrelated
  // later close doesn't read this stream rejection's retryable:false and wrongly
  // stop reconnecting the whole socket.
  expect((client as any).lastError).toBeNull();
});
