import { expect, test } from "bun:test";
import { AuthorizationLease } from "../src/peer/authorization-lease";

const identity = { accountId: "account", deviceId: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", enrollmentId: "credential" };
const peerId = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
const snapshot = () => ({ ...identity, policyGeneration: "1", registrationGeneration: "0", allowed: true, leaseMs: 60_000,
  endpoint: null, peers: [{ deviceId: peerId, ed25519Pub: Buffer.alloc(32).toString("base64"), endpoint: null }], relayUrls: [] });

test("resume fences an in-flight lease then requests new authorization", async () => {
  const old = Promise.withResolvers<unknown>();
  const fresh = Promise.withResolvers<unknown>();
  let requests = 0;
  const reasons: string[] = [];
  const lease = new AuthorizationLease(identity, () => ++requests === 1 ? old.promise : fresh.promise,
    (reason) => reasons.push(reason));
  const before = lease.refresh();
  const resumed = lease.resume();
  expect(reasons).toEqual(["resume"]);
  expect(lease.allows(peerId)).toBe(false);
  old.resolve(snapshot());
  expect(await before).toBe(false);
  await new Promise((resolve) => setTimeout(resolve, 0));
  expect(requests).toBe(2);
  expect(lease.current).toBeNull();
  fresh.resolve(snapshot());
  expect(await resumed).toBe(true);
  expect(lease.allows(peerId)).toBe(true);
  lease.invalidate("closed");
});

test("lease expires from monotonic request start, including response delay", async () => {
  let now = 0;
  const pending = Promise.withResolvers<unknown>();
  const invalidated: string[] = [];
  const lease = new AuthorizationLease(identity, () => pending.promise, (reason) => invalidated.push(reason), undefined, () => now);
  const refresh = lease.refresh();
  expect(lease.refresh()).toBe(refresh);
  now = 59_000;
  pending.resolve(snapshot());
  expect(await refresh).toBe(true);
  expect(lease.allows(peerId)).toBe(true);
  now = 60_000;
  expect(lease.allows(peerId)).toBe(false);
  expect(invalidated).toEqual(["expired"]);
  lease.invalidate("closed");
});

test("in-flight refresh cannot resurrect admission after revocation", async () => {
  const pending = Promise.withResolvers<unknown>();
  const lease = new AuthorizationLease(identity, () => pending.promise, () => {});
  const refreshed = lease.refresh();
  lease.invalidate("revoked");
  pending.resolve(snapshot());
  expect(await refreshed).toBe(false);
  expect(lease.allows(peerId)).toBe(false);
  lease.invalidate("closed");
});

test("older policy cannot renew an authoritative denial", async () => {
  let value = { ...snapshot(), policyGeneration: "2", allowed: false };
  const lease = new AuthorizationLease(identity, async () => value, () => {});
  expect(await lease.refresh()).toBe(false);
  value = snapshot();
  expect(await lease.refresh()).toBe(false);
  expect(lease.current).toBeNull();
  lease.invalidate("closed");
});
