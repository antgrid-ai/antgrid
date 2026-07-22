import { test, expect, afterEach } from "bun:test";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { RelayClient } from "../../src/relay-client";
import { loadPairedPhones } from "../../src/paired-phones";

let clients: RelayClient[] = [];
afterEach(() => {
  for (const c of clients.splice(0)) try { c.close(); } catch {}
});

/** Build a RelayClient with a fake OPEN WebSocket that records every send() so
 *  we can assert the exact control frame `sendPushDeliver` puts on the wire.
 *  Mirrors the in-file fake-ws pattern in tests/relay-client-register.test.ts. */
function makeClientWithFakeWs(): { client: RelayClient; sent: unknown[] } {
  const sent: unknown[] = [];
  const client = new RelayClient({
    url: "ws://127.0.0.1:1",
    identity: {
      deviceId: "uuid-1",
      deviceName: "machine",
      createdAt: new Date().toISOString(),
      ed25519PublicKey: "pk",
      ed25519PrivateKey: "sk",
    },
    generateKeypair: () => { throw new Error("not used"); },
    getLicenseToken: () => "tok",
  });
  clients.push(client);
  // WebSocket.OPEN === 1; sendJson gates on readyState === WebSocket.OPEN.
  (client as any).ws = { readyState: 1, send: (d: unknown) => sent.push(d), close: () => {} };
  return { client, sent };
}

test("sendPushDeliver emits a top-level push:deliver control frame", () => {
  const { client, sent } = makeClientWithFakeWs();
  client.sendPushDeliver({ pushToken: "tok", provider: "fcm", blob: { epk: "E", box: "B" } });
  const frames = sent.filter((s) => typeof s === "string").map((s) => JSON.parse(s as string));
  const pd = frames.find((f) => f.type === "push:deliver");
  expect(pd).toBeTruthy();
  expect(pd.pushToken).toBe("tok");
  expect(pd.provider).toBe("fcm");
  expect(pd.blob).toEqual({ epk: "E", box: "B" });
});

test("sendPushDeliver is a safe no-op when the socket is not open", () => {
  const { client, sent } = makeClientWithFakeWs();
  (client as any).ws = { readyState: 3 /* CLOSED */, send: (d: unknown) => sent.push(d), close: () => {} };
  client.sendPushDeliver({ pushToken: "tok", provider: "fcm", blob: { epk: "E", box: "B" } });
  expect(sent).toEqual([]);
});

function seedPhone(pushToken: string) {
  const dir = mkdtempSync(join(tmpdir(), "ab-pushresult-"));
  const store = loadPairedPhones(dir);
  store.upsert({
    phonePubkey: "PK", phoneDeviceId: "d1", pairedAt: "2026-07-01T00:00:00.000Z",
    lastSeenAt: "2026-07-01T00:00:00.000Z", admission: "same-account",
    pushToken, pushProvider: "fcm", pushPubkey: "xpk",
  });
  return store;
}

test("push:result { ok:false, reason:unregistered } prunes the dead token", () => {
  const pairedPhones = seedPhone("dead-token");
  const client = new RelayClient({
    url: "ws://127.0.0.1:1",
    identity: { deviceId: "uuid-1", deviceName: "m", createdAt: new Date().toISOString(), ed25519PublicKey: "pk", ed25519PrivateKey: "sk" },
    generateKeypair: () => { throw new Error("not used"); },
    getLicenseToken: () => "tok",
    pairedPhones,
  });
  clients.push(client);

  (client as any).handleTextMessage(
    JSON.stringify({ type: "push:result", pushToken: "dead-token", ok: false, reason: "unregistered" }),
  );

  const phone = pairedPhones.get("PK");
  expect(phone?.pushToken).toBeUndefined();
  expect(phone?.pushPubkey).toBe("xpk"); // identity survives
});

test("push:result with a non-unregistered failure keeps the token (log-only, no crash)", () => {
  const pairedPhones = seedPhone("live-token");
  const client = new RelayClient({
    url: "ws://127.0.0.1:1",
    identity: { deviceId: "uuid-1", deviceName: "m", createdAt: new Date().toISOString(), ed25519PublicKey: "pk", ed25519PrivateKey: "sk" },
    generateKeypair: () => { throw new Error("not used"); },
    getLicenseToken: () => "tok",
    pairedPhones,
  });
  clients.push(client);

  (client as any).handleTextMessage(
    JSON.stringify({ type: "push:result", pushToken: "live-token", ok: false, reason: "error" }),
  );
  (client as any).handleTextMessage(
    JSON.stringify({ type: "push:result", pushToken: "live-token", ok: true }),
  );

  expect(pairedPhones.get("PK")?.pushToken).toBe("live-token");
});
