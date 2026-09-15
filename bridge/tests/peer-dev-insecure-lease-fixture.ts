import { AuthorizationLease } from "../src/peer/authorization-lease";

/**
 * Driven as a subprocess by `peer-authorization-lease.test.ts`. The schema this
 * host accepts is resolved from its own environment at module load, and Bun
 * shares one module cache across the whole suite, so the two modes can only be
 * compared across processes.
 */
const identity = { accountId: "account", deviceId: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", enrollmentId: "credential" };
const snapshot = { ...identity, policyGeneration: "1", registrationGeneration: "0", allowed: true,
  leaseMs: 60_000, endpoint: null, peers: [], relayUrls: ["http://127.0.0.1:3000/"] };
const lease = new AuthorizationLease(identity, async () => snapshot, () => {});
// Marked because the dev-mode warning shares this stream.
console.log(`RESULT ${await lease.refresh().catch(() => false)}`);
lease.invalidate("closed");
