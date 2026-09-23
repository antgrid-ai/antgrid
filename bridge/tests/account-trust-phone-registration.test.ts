// Account-trust admission has no pair-request. Identity is now authenticated
// at the QUIC/lease layer (native-host-connection's acceptPeer), which hands
// the already-verified Ed25519 key to `admitPeer` — there is no transcript
// signature to check at this layer any more (that suite lives in
// native-host-connection.test.ts / peer-session-hello.test.ts). `admitPeer` is
// the ONLY place a same-account phone's row can be created. The row grants
// nothing — authorization is the machine's mobile-access switch — but without
// it a fully connected phone is invisible to `antgrid phones list` and
// unreachable by push.
import { test, expect, afterEach } from "bun:test";
import { generateKeyPairSync } from "node:crypto";
import { TestPeerSessionOwner } from "./test-peer-session-owner";
import type { PairedPhone, PairedPhonesStore } from "../src/paired-phones";

const AGENT_DEVICE_ID = "agent-1";
const PHONE_ID = "phone-1";

let clients: TestPeerSessionOwner[] = [];
afterEach(() => { for (const c of clients.splice(0)) try { c.close(); } catch {} });

function ed25519Pair(): { seedB64: string; pubB64: string } {
  const { publicKey, privateKey } = generateKeyPairSync("ed25519");
  return {
    seedB64: Buffer.from(privateKey.export({ format: "der", type: "pkcs8" }).subarray(-32)).toString("base64"),
    pubB64: Buffer.from(publicKey.export({ format: "der", type: "spki" }).subarray(-32)).toString("base64"),
  };
}

/** In-memory stand-in for the on-disk store, counting writes: a rewrite per
 *  reconnect would flush the file and trip its watcher's re-advertise. */
function fakeStore(seed: PairedPhone[] = []): PairedPhonesStore & { upserts: PairedPhone[]; touches: string[] } {
  const phones = [...seed];
  const upserts: PairedPhone[] = [];
  const touches: string[] = [];
  return {
    upserts,
    touches,
    list: () => phones.slice(),
    has: (pk: string) => phones.some((p) => p.phonePubkey === pk),
    get: (pk: string) => phones.find((p) => p.phonePubkey === pk),
    upsert: (phone: PairedPhone) => {
      upserts.push(phone);
      const i = phones.findIndex((p) => p.phonePubkey === phone.phonePubkey);
      if (i >= 0) phones[i] = { ...phone }; else phones.push({ ...phone });
    },
    touchLastSeen: (pk: string, at?: string) => {
      touches.push(pk);
      const phone = phones.find((p) => p.phonePubkey === pk);
      if (phone) phone.lastSeenAt = at ?? new Date().toISOString();
    },
  } as unknown as PairedPhonesStore & { upserts: PairedPhone[]; touches: string[] };
}

function makeClient(store: PairedPhonesStore, agentEd: { seedB64: string }): TestPeerSessionOwner {
  const client = TestPeerSessionOwner.forTest({
    sendPayload: () => {},
    peerId: PHONE_ID,
    deviceId: AGENT_DEVICE_ID,
    agentEd25519PrivB64: agentEd.seedB64,
  });
  clients.push(client);
  const opts = (client as unknown as { opts: { pairedPhones?: PairedPhonesStore } }).opts;
  opts.pairedPhones = store;
  return client;
}

/** `admitPeer` is protected on the base class — it runs at accept time, ahead
 *  of any hello, so this suite drives it directly rather than through
 *  `establish()`. */
function admit(client: TestPeerSessionOwner, peerId: string, ed25519Pub: string): void {
  (client as unknown as { admitPeer(peerId: string, ed25519Pub: string): void }).admitPeer(peerId, ed25519Pub);
}

test("admitting an unknown account-trusted phone registers it", () => {
  const agentEd = ed25519Pair();
  const phoneEd = ed25519Pair();
  const store = fakeStore();
  admit(makeClient(store, agentEd), PHONE_ID, phoneEd.pubB64);

  expect(store.list()).toEqual([
    expect.objectContaining({ phonePubkey: phoneEd.pubB64, phoneDeviceId: PHONE_ID }),
  ]);
});

test("registration seeds no per-project grants — the row is identity only", () => {
  const agentEd = ed25519Pair();
  const phoneEd = ed25519Pair();
  const store = fakeStore();
  admit(makeClient(store, agentEd), PHONE_ID, phoneEd.pubB64);

  expect(store.upserts[0]).not.toHaveProperty("allowedProjects");
});

test("a reconnect does not rewrite the row — one write, not one per connection", () => {
  const agentEd = ed25519Pair();
  const phoneEd = ed25519Pair();
  const store = fakeStore();
  const client = makeClient(store, agentEd);

  admit(client, PHONE_ID, phoneEd.pubB64);
  admit(client, PHONE_ID, phoneEd.pubB64);

  expect(store.upserts.length).toBe(1);
});

test("re-admitting an existing row refreshes lastSeenAt (not frozen at creation)", () => {
  const agentEd = ed25519Pair();
  const phoneEd = ed25519Pair();
  const store = fakeStore([{
    phonePubkey: phoneEd.pubB64,
    phoneDeviceId: PHONE_ID,
    pairedAt: "2026-01-01T00:00:00.000Z",
    lastSeenAt: "2026-01-01T00:00:00.000Z",
  }]);
  admit(makeClient(store, agentEd), PHONE_ID, phoneEd.pubB64);

  expect(store.touches).toEqual([phoneEd.pubB64]);
  expect(store.list()[0]!.lastSeenAt).not.toBe("2026-01-01T00:00:00.000Z");
  // The refresh must NOT come from a row rewrite — that is what re-flushes the
  // file and trips the watcher on every reconnect.
  expect(store.upserts.length).toBe(0);
});
