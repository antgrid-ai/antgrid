// Account-trust admission (spec 2026-07-24 §3.3) has no pair-request, so the
// client-hello path is the ONLY place a same-account phone's row can be created.
// The row grants nothing — authorization is the machine's mobile-access switch —
// but without it a fully connected phone is invisible to `antgrid phones list`
// and unreachable by push.
import { test, expect, afterEach } from "bun:test";
import { generateKeyPairSync } from "node:crypto";
import { encodeRouteFrame, FrameKind } from "antgrid-wire";
import { generateEphemeralKeypair } from "../src/key-exchange";
import { RelayClient } from "../src/relay-client";
import type { PairedPhone, PairedPhonesStore } from "../src/paired-phones";
import { buildTranscript, signTranscript } from "../src/e2e";

const AGENT_DEVICE_ID = "agent-1";
const PHONE_ID = "phone-1";

let clients: RelayClient[] = [];
afterEach(() => { for (const c of clients.splice(0)) try { c.close(); } catch {} });

function ed25519Pair(): { seedB64: string; pubB64: string } {
  const { publicKey, privateKey } = generateKeyPairSync("ed25519");
  return {
    seedB64: Buffer.from(privateKey.export({ format: "der", type: "pkcs8" }).subarray(-32)).toString("base64"),
    pubB64: Buffer.from(publicKey.export({ format: "der", type: "spki" }).subarray(-32)).toString("base64"),
  };
}

/** In-memory stand-in for the on-disk store, counting writes: a rewrite per
 *  rekey would flush the file and trip its watcher's re-advertise. */
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

function clientHello(args: { attemptId: string; appX25519PubB64: string; phoneSeedB64: string; sign?: boolean }): Buffer {
  const nonce = Buffer.from([1, 2, 3, 4, 5, 6, 7, 8]);
  const transcript = buildTranscript({
    registrationId: AGENT_DEVICE_ID,
    role: "phone",
    agentDeviceId: AGENT_DEVICE_ID,
    phoneDeviceId: PHONE_ID,
    agentX25519Pub: Buffer.alloc(0),
    phoneX25519Pub: Buffer.from(args.appX25519PubB64, "base64"),
    nonce,
  });
  // A forged hello signs the right transcript with the WRONG key, so it fails
  // verification against every known identity rather than being malformed.
  const seed = args.sign === false ? ed25519Pair().seedB64 : args.phoneSeedB64;
  return Buffer.from(JSON.stringify({
    type: "handshake:client-hello",
    attemptId: args.attemptId,
    pubkey: args.appX25519PubB64,
    nonce: nonce.toString("base64"),
    sig: signTranscript(transcript, Buffer.from(seed, "base64")),
  }));
}

function makeClient(store: PairedPhonesStore, phoneEd: { pubB64: string }, agentEd: { seedB64: string }): RelayClient {
  const client = RelayClient.forTest({
    generateKeypair: generateEphemeralKeypair,
    sendPayload: () => {},
    peerId: PHONE_ID,
    deviceId: AGENT_DEVICE_ID,
    agentEd25519PrivB64: agentEd.seedB64,
    phoneEd25519PubB64: phoneEd.pubB64,
  });
  clients.push(client);
  const opts = (client as unknown as { opts: { pairedPhones?: PairedPhonesStore } }).opts;
  opts.pairedPhones = store;
  return client;
}

function sendHello(client: RelayClient, phoneSeedB64: string, attemptId: string, sign = true): void {
  const app = generateEphemeralKeypair();
  const payload = clientHello({ attemptId, appX25519PubB64: app.publicKey.toString("base64"), phoneSeedB64, sign });
  const frame = encodeRouteFrame({ type: "message", from: PHONE_ID, channel: "control" }, payload, FrameKind.handshake);
  (client as unknown as { handleBinaryFrame: (b: Buffer) => void }).handleBinaryFrame(Buffer.from(frame));
}

test("a verified client-hello registers an unknown account-trusted phone", () => {
  const agentEd = ed25519Pair();
  const phoneEd = ed25519Pair();
  const store = fakeStore();
  sendHello(makeClient(store, phoneEd, agentEd), phoneEd.seedB64, "attempt-a");

  expect(store.list()).toEqual([
    expect.objectContaining({ phonePubkey: phoneEd.pubB64, phoneDeviceId: PHONE_ID }),
  ]);
});

test("registration seeds no per-project grants — the row is identity only", () => {
  const agentEd = ed25519Pair();
  const phoneEd = ed25519Pair();
  const store = fakeStore();
  sendHello(makeClient(store, phoneEd, agentEd), phoneEd.seedB64, "attempt-a");

  expect(store.upserts[0]).not.toHaveProperty("allowedProjects");
});

test("a rekey does not rewrite the row — one write, not one per handshake", () => {
  const agentEd = ed25519Pair();
  const phoneEd = ed25519Pair();
  const store = fakeStore();
  const client = makeClient(store, phoneEd, agentEd);

  sendHello(client, phoneEd.seedB64, "attempt-a");
  sendHello(client, phoneEd.seedB64, "attempt-b");

  expect(store.upserts.length).toBe(1);
});

test("an admission against an existing row refreshes lastSeenAt (not frozen at creation)", () => {
  const agentEd = ed25519Pair();
  const phoneEd = ed25519Pair();
  const store = fakeStore([{
    phonePubkey: phoneEd.pubB64,
    phoneDeviceId: PHONE_ID,
    pairedAt: "2026-01-01T00:00:00.000Z",
    lastSeenAt: "2026-01-01T00:00:00.000Z",
  }]);
  sendHello(makeClient(store, phoneEd, agentEd), phoneEd.seedB64, "attempt-a");

  expect(store.touches).toEqual([phoneEd.pubB64]);
  expect(store.list()[0]!.lastSeenAt).not.toBe("2026-01-01T00:00:00.000Z");
  // The refresh must NOT come from a row rewrite — that is what re-flushes the
  // file and trips the watcher on every rekey.
  expect(store.upserts.length).toBe(0);
});

test("a client-hello that fails verification never refreshes lastSeenAt", () => {
  const agentEd = ed25519Pair();
  const phoneEd = ed25519Pair();
  const store = fakeStore([{
    phonePubkey: phoneEd.pubB64,
    phoneDeviceId: PHONE_ID,
    pairedAt: "2026-01-01T00:00:00.000Z",
    lastSeenAt: "2026-01-01T00:00:00.000Z",
  }]);
  sendHello(makeClient(store, phoneEd, agentEd), phoneEd.seedB64, "attempt-a", false);

  expect(store.touches).toEqual([]);
  expect(store.list()[0]!.lastSeenAt).toBe("2026-01-01T00:00:00.000Z");
});

test("a client-hello whose signature does not verify registers nothing", () => {
  const agentEd = ed25519Pair();
  const phoneEd = ed25519Pair();
  const store = fakeStore();
  sendHello(makeClient(store, phoneEd, agentEd), phoneEd.seedB64, "attempt-a", false);

  expect(store.list()).toEqual([]);
});
