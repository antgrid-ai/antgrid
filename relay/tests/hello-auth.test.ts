// The happy paths (agent/app hello -> welcome, non-hello first frame, clock
// skew) live in hello-smoke.test.ts. This file covers the remaining R10 hello
// assertions: replay, forged signature, host mismatch, JWKS outage, and the
// app-token-required schema gate.
import { test, expect, afterEach } from "bun:test";
import {
  startServer,
  defaultConfig,
  connect,
  makeHello,
  waitForMessage,
  type RelayServer,
} from "./helpers/relay-harness.js";
import type { LicenseGate } from "../src/license/gate.js";

let relay: RelayServer | undefined;

afterEach(() => {
  relay?.stop();
  relay = undefined;
});

test("replayed (deviceId, nonce) is rejected even after the first connection closed", async () => {
  relay = startServer(defaultConfig);
  const { hello } = await makeHello(relay, { deviceId: "agent-replay" });

  const ws1 = await connect(relay);
  const first = waitForMessage(ws1);
  ws1.send(JSON.stringify(hello));
  expect((await first).type).toBe("welcome");
  await new Promise<void>((resolve) => {
    ws1.onclose = () => resolve();
    ws1.close();
  });

  // Same deviceId + nonce, byte-for-byte, on a brand new connection.
  const ws2 = await connect(relay);
  const second = waitForMessage(ws2);
  const closed = new Promise<number>((resolve) => { ws2.onclose = (e) => resolve(e.code); });
  ws2.send(JSON.stringify(hello));
  const err = await second;
  expect(err.type).toBe("error");
  expect(err.code).toBe("AUTH_FAILED");
  expect(err.retryable).toBe(false);
  expect(await closed).toBe(1008);
});

test("bad signature is rejected", async () => {
  relay = startServer(defaultConfig);
  const { hello } = await makeHello(relay, { deviceId: "agent-badsig" });
  const tampered = { ...hello, sig: Buffer.alloc(64, 0).toString("base64") };

  const ws = await connect(relay);
  const first = waitForMessage(ws);
  const closed = new Promise<number>((resolve) => { ws.onclose = (e) => resolve(e.code); });
  ws.send(JSON.stringify(tampered));
  const err = await first;
  expect(err).toMatchObject({ type: "error", code: "AUTH_FAILED", retryable: false });
  expect(await closed).toBe(1008);
});

test("a sig-invalid hello does NOT consume the replay cache (record happens after verify)", async () => {
  // Finding #1: if the nonce were recorded before signature verification, an
  // unauthenticated attacker could burn replay-cache capacity with junk hellos
  // (and, at the eviction ceiling, evict a victim's legit nonce). Guard: a
  // bad-sig hello must leave the (deviceId, nonce) UNSEEN, so the genuine hello
  // that later arrives with the same nonce still authenticates.
  relay = startServer(defaultConfig);
  const { hello } = await makeHello(relay, { deviceId: "agent-record-order", nonce: "cmVjb3JkLW9yZGVyLW5vbmNl" });
  const tampered = { ...hello, sig: Buffer.alloc(64, 0).toString("base64") };

  const ws1 = await connect(relay);
  const first = waitForMessage(ws1);
  const closed1 = new Promise<void>((resolve) => { ws1.onclose = () => resolve(); });
  ws1.send(JSON.stringify(tampered));
  expect(await first).toMatchObject({ type: "error", code: "AUTH_FAILED" });
  await closed1;

  // The real, correctly-signed hello with the SAME nonce must be admitted —
  // the failed attempt above must not have recorded it as seen.
  const ws2 = await connect(relay);
  const second = waitForMessage(ws2);
  ws2.send(JSON.stringify(hello));
  expect((await second).type).toBe("welcome");
});

test("Host-header mismatch is rejected (hello signed for a different relayHost)", async () => {
  relay = startServer(defaultConfig);
  const { hello } = await makeHello(relay, {
    deviceId: "agent-hostmismatch",
    relayHost: "evil.example:9999",
  });

  const ws = await connect(relay);
  const first = waitForMessage(ws);
  const closed = new Promise<number>((resolve) => { ws.onclose = (e) => resolve(e.code); });
  ws.send(JSON.stringify(hello));
  const err = await first;
  // The relay rebuilds the sig body with ITS OWN Host header, so a hello
  // signed for another host fails signature verification, not a dedicated
  // "host mismatch" code (step 4).
  expect(err).toMatchObject({ type: "error", code: "AUTH_FAILED", retryable: false });
  expect(await closed).toBe(1008);
});

test("agent with unreachable JWKS -> LICENSE_UNAVAILABLE, retryable", async () => {
  const unavailableGate: LicenseGate = {
    async verify() { return { ok: false, code: "LICENSE_UNAVAILABLE" }; },
    async verifyAppToken() { return { ok: false, code: "LICENSE_UNAVAILABLE" }; },
  };
  relay = startServer(defaultConfig, { licenseGate: unavailableGate });
  const { hello } = await makeHello(relay, { deviceId: "agent-jwks-down" });

  const ws = await connect(relay);
  const first = waitForMessage(ws);
  const closed = new Promise<number>((resolve) => { ws.onclose = (e) => resolve(e.code); });
  ws.send(JSON.stringify(hello));
  const err = await first;
  expect(err).toMatchObject({ type: "error", code: "LICENSE_UNAVAILABLE", retryable: true });
  expect(await closed).toBe(1008);
});

test("app hello without a licenseToken fails schema -> PROTOCOL_VIOLATION", async () => {
  relay = startServer(defaultConfig);
  const { hello } = await makeHello(relay, { deviceId: "app-no-token", deviceType: "app" });
  const { licenseToken: _drop, ...withoutToken } = hello;

  const ws = await connect(relay);
  const first = waitForMessage(ws);
  const closed = new Promise<number>((resolve) => { ws.onclose = (e) => resolve(e.code); });
  ws.send(JSON.stringify(withoutToken));
  const err = await first;
  expect(err).toMatchObject({ type: "error", code: "PROTOCOL_VIOLATION", retryable: false });
  expect(await closed).toBe(1008);
});
