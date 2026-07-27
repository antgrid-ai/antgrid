// resolvePhoneEd25519PubB64 resolution order (spec 2026-07-24 §3.3, task 6):
// explicit map -> account inventory (TrustedPeersProvider) -> paired-phones
// store -> noteMiss() + undefined. The explicit-map and paired-phones paths
// predate this task; these tests cover the newly-inserted inventory step and
// its ordering relative to the two existing sources.
import { test, expect } from "bun:test";
import { RelayClient } from "../src/relay-client";
import { generateEphemeralKeypair } from "../src/key-exchange";
import type { PairedPhonesStore } from "../src/paired-phones";
import type { TrustedPeersProvider } from "../src/trusted-peers";

function fakeTrustedPeers(byDeviceId: Record<string, string>): TrustedPeersProvider & { noteMissCalls: number } {
  const fake = {
    noteMissCalls: 0,
    lookup: (deviceId: string) => byDeviceId[deviceId],
    noteMiss: () => { fake.noteMissCalls++; },
    refresh: async () => {},
  };
  return fake as unknown as TrustedPeersProvider & { noteMissCalls: number };
}

function fakePairedPhones(phoneDeviceId: string, phonePubkey: string): PairedPhonesStore {
  return { list: () => [{ phonePubkey, phoneDeviceId, pairedAt: "x", lastSeenAt: "x", allowedProjects: [] }] } as unknown as PairedPhonesStore;
}

type Resolution = { pub: string | undefined; known: number };

function resolveResult(
  client: RelayClient,
  deviceId: string,
  verify: (candidate: string) => boolean = () => true,
): Resolution {
  return (
    client as unknown as { resolvePhoneEd25519PubB64: (id: string, verify: (c: string) => boolean) => Resolution }
  ).resolvePhoneEd25519PubB64(deviceId, verify);
}

function resolve(
  client: RelayClient,
  deviceId: string,
  verify: (candidate: string) => boolean = () => true,
): string | undefined {
  return resolveResult(client, deviceId, verify).pub;
}

test("resolvePhoneEd25519PubB64: inventory hit when absent from map and paired-phones store", () => {
  const client = RelayClient.forTest({ generateKeypair: generateEphemeralKeypair, sendPayload: () => {}, peerId: "other-peer" });
  const trustedPeers = fakeTrustedPeers({ "phone-inventory": "inventory-pubkey" });
  (client as unknown as { opts: { trustedPeers: TrustedPeersProvider; pairedPhones: PairedPhonesStore } }).opts.trustedPeers = trustedPeers;
  (client as unknown as { opts: { trustedPeers: TrustedPeersProvider; pairedPhones: PairedPhonesStore } }).opts.pairedPhones = fakePairedPhones("someone-else", "someone-else-pubkey");

  expect(resolve(client, "phone-inventory")).toBe("inventory-pubkey");
  expect(trustedPeers.noteMissCalls).toBe(0);
});

test("resolvePhoneEd25519PubB64: inventory takes priority over the paired-phones store", () => {
  const client = RelayClient.forTest({ generateKeypair: generateEphemeralKeypair, sendPayload: () => {}, peerId: "other-peer" });
  const trustedPeers = fakeTrustedPeers({ "phone-both": "inventory-pubkey" });
  (client as unknown as { opts: { trustedPeers: TrustedPeersProvider; pairedPhones: PairedPhonesStore } }).opts.trustedPeers = trustedPeers;
  (client as unknown as { opts: { trustedPeers: TrustedPeersProvider; pairedPhones: PairedPhonesStore } }).opts.pairedPhones = fakePairedPhones("phone-both", "store-pubkey");

  expect(resolve(client, "phone-both")).toBe("inventory-pubkey");
});

test("resolvePhoneEd25519PubB64: falls back to the paired-phones store on an inventory miss", () => {
  const client = RelayClient.forTest({ generateKeypair: generateEphemeralKeypair, sendPayload: () => {}, peerId: "other-peer" });
  const trustedPeers = fakeTrustedPeers({});
  (client as unknown as { opts: { trustedPeers: TrustedPeersProvider; pairedPhones: PairedPhonesStore } }).opts.trustedPeers = trustedPeers;
  (client as unknown as { opts: { trustedPeers: TrustedPeersProvider; pairedPhones: PairedPhonesStore } }).opts.pairedPhones = fakePairedPhones("phone-store-only", "store-pubkey");

  expect(resolve(client, "phone-store-only")).toBe("store-pubkey");
  expect(trustedPeers.noteMissCalls).toBe(0);
});

test("resolvePhoneEd25519PubB64: total miss returns undefined and records exactly one noteMiss call", () => {
  const client = RelayClient.forTest({ generateKeypair: generateEphemeralKeypair, sendPayload: () => {}, peerId: "other-peer" });
  const trustedPeers = fakeTrustedPeers({});
  (client as unknown as { opts: { trustedPeers: TrustedPeersProvider; pairedPhones: PairedPhonesStore } }).opts.trustedPeers = trustedPeers;
  (client as unknown as { opts: { trustedPeers: TrustedPeersProvider; pairedPhones: PairedPhonesStore } }).opts.pairedPhones = fakePairedPhones("someone-else", "someone-else-pubkey");

  expect(resolve(client, "phone-unknown")).toBeUndefined();
  expect(trustedPeers.noteMissCalls).toBe(1);
});

// M5: a device re-registering under a new Ed25519 key must not be permanently
// locked out by the in-memory cache. `phoneEd25519ByDeviceId` is written from
// a PRIOR successful verify (handleClientHello, ~L1045); it is not itself
// re-validated, so a stale entry has to fall through to the inventory instead
// of shadowing it forever.
test("resolvePhoneEd25519PubB64: falls back to inventory when the cached key fails verification (stale cache after re-key)", () => {
  const client = RelayClient.forTest({
    generateKeypair: generateEphemeralKeypair,
    sendPayload: () => {},
    peerId: "other-peer",
  });
  (client as unknown as { phoneEd25519ByDeviceId: Map<string, string> }).phoneEd25519ByDeviceId.set(
    "phone-rekeyed",
    "stale-cached-pubkey",
  );
  const trustedPeers = fakeTrustedPeers({ "phone-rekeyed": "fresh-inventory-pubkey" });
  (client as unknown as { opts: { trustedPeers: TrustedPeersProvider } }).opts.trustedPeers = trustedPeers;

  const verify = (candidate: string) => candidate === "fresh-inventory-pubkey";
  expect(resolve(client, "phone-rekeyed", verify)).toBe("fresh-inventory-pubkey");
  // The stale cache is a known-unknown, not an unknown-unknown — no refresh
  // needed since the inventory already had the answer.
  expect(trustedPeers.noteMissCalls).toBe(0);
});

test("resolvePhoneEd25519PubB64: warms the inventory refresh when NO candidate verifies (cache and inventory both stale)", () => {
  const client = RelayClient.forTest({
    generateKeypair: generateEphemeralKeypair,
    sendPayload: () => {},
    peerId: "other-peer",
  });
  (client as unknown as { phoneEd25519ByDeviceId: Map<string, string> }).phoneEd25519ByDeviceId.set(
    "phone-x",
    "stale-cached-pubkey",
  );
  const trustedPeers = fakeTrustedPeers({ "phone-x": "also-stale-pubkey" });
  (client as unknown as { opts: { trustedPeers: TrustedPeersProvider } }).opts.trustedPeers = trustedPeers;

  expect(resolve(client, "phone-x", () => false)).toBeUndefined();
  expect(trustedPeers.noteMissCalls).toBe(1);
});

// The two rejection causes are diagnostically different on the admission path
// ("nobody has heard of this device" vs "a device we know signed something that
// doesn't verify"), so a rejection reports how many identities were tried and
// handleClientHello logs them as separate lines.
test("resolvePhoneEd25519PubB64: a rejection distinguishes an unknown peer from a failed signature", () => {
  const client = RelayClient.forTest({ generateKeypair: generateEphemeralKeypair, sendPayload: () => {}, peerId: "other-peer" });
  (client as unknown as { phoneEd25519ByDeviceId: Map<string, string> }).phoneEd25519ByDeviceId.set(
    "phone-known",
    "cached-pubkey",
  );
  const trustedPeers = fakeTrustedPeers({ "phone-known": "inventory-pubkey" });
  (client as unknown as { opts: { trustedPeers: TrustedPeersProvider } }).opts.trustedPeers = trustedPeers;

  expect(resolveResult(client, "phone-unheard-of", () => false)).toEqual({ pub: undefined, known: 0 });
  expect(resolveResult(client, "phone-known", () => false)).toEqual({ pub: undefined, known: 2 });
});

// Per-machine relay slots (`<accountDeviceUuid>#<machineDeviceUuid>`): the
// route id the phone reaches us on is a transport address. Neither persistent
// store has ever heard of one, so both are looked up by the base account id.
// This widens the CANDIDATE list only — `verify` still has to pass, so a client
// claiming `<victim>#x` is handed the victim's pubkey and then fails the
// signature.
test("resolvePhoneEd25519PubB64: a slot route id resolves against the base-keyed inventory", () => {
  const client = RelayClient.forTest({ generateKeypair: generateEphemeralKeypair, sendPayload: () => {}, peerId: "other-peer" });
  const trustedPeers = fakeTrustedPeers({ "phone-a": "inventory-pubkey" });
  (client as unknown as { opts: { trustedPeers: TrustedPeersProvider } }).opts.trustedPeers = trustedPeers;

  expect(resolve(client, "phone-a#machine-1")).toBe("inventory-pubkey");
  expect(trustedPeers.noteMissCalls).toBe(0);
});

test("resolvePhoneEd25519PubB64: a slot route id resolves against the base-keyed paired-phones store", () => {
  const client = RelayClient.forTest({ generateKeypair: generateEphemeralKeypair, sendPayload: () => {}, peerId: "other-peer" });
  (client as unknown as { opts: { trustedPeers: TrustedPeersProvider; pairedPhones: PairedPhonesStore } }).opts.trustedPeers = fakeTrustedPeers({});
  (client as unknown as { opts: { trustedPeers: TrustedPeersProvider; pairedPhones: PairedPhonesStore } }).opts.pairedPhones = fakePairedPhones("phone-b", "store-pubkey");

  expect(resolve(client, "phone-b#machine-2")).toBe("store-pubkey");
});

// The in-memory cache is the reply-address map, so it stays keyed by the full
// route id: two machines' slots for one phone are different sockets.
test("resolvePhoneEd25519PubB64: the in-memory cache is keyed by the full slot, not the base id", () => {
  const client = RelayClient.forTest({ generateKeypair: generateEphemeralKeypair, sendPayload: () => {}, peerId: "other-peer" });
  (client as unknown as { phoneEd25519ByDeviceId: Map<string, string> }).phoneEd25519ByDeviceId.set(
    "phone-c#machine-1",
    "cached-pubkey",
  );
  (client as unknown as { opts: { trustedPeers: TrustedPeersProvider } }).opts.trustedPeers = fakeTrustedPeers({});

  expect(resolve(client, "phone-c#machine-1")).toBe("cached-pubkey");
  expect(resolve(client, "phone-c#machine-2")).toBeUndefined();
});

// Stripping must not admit a slot whose base id resolves to somebody else's
// key: the signature is the gate, exactly as it is for a bare id today.
test("resolvePhoneEd25519PubB64: a slot claiming another account's base id still fails verification", () => {
  const client = RelayClient.forTest({ generateKeypair: generateEphemeralKeypair, sendPayload: () => {}, peerId: "other-peer" });
  const trustedPeers = fakeTrustedPeers({ "victim-device": "victim-pubkey" });
  (client as unknown as { opts: { trustedPeers: TrustedPeersProvider } }).opts.trustedPeers = trustedPeers;

  // The victim's key IS offered as a candidate — and is rejected, because the
  // caller cannot produce a transcript signature under it.
  expect(resolveResult(client, "victim-device#attacker-machine", () => false)).toEqual({ pub: undefined, known: 1 });
});
