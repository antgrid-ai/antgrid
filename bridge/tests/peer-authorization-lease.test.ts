import { expect, test } from "bun:test";
import { join } from "node:path";
import { AuthorizationLease } from "../src/peer/authorization-lease";

const identity = { accountId: "account", deviceId: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", enrollmentId: "credential" };
const peerId = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
const snapshot = () => ({ ...identity, policyGeneration: "1", registrationGeneration: "0", allowed: true, leaseMs: 60_000,
  endpoint: null, peers: [{ deviceId: peerId, ed25519Pub: Buffer.alloc(32).toString("base64"), endpoint: null }], relayUrls: [] });

function manualScheduler() {
  const jobs: Array<{ ms: number; active: boolean; run: () => void }> = [];
  const schedule = (callback: () => void, ms: number) => {
    const job = { ms, active: true, run: callback };
    jobs.push(job);
    return () => { job.active = false; };
  };
  return { jobs, schedule };
}

// A suspend stops the monotonic clock on macOS and Linux; the wall clock is
// the only one of the two that saw the time pass.
test("a suspend the monotonic clock did not see still expires the lease", async () => {
  let wall = 1_000_000;
  const invalidated: string[] = [];
  const lease = new AuthorizationLease(identity, async () => snapshot(), (reason) => invalidated.push(reason),
    undefined, () => 0, undefined, undefined, () => wall);
  expect(await lease.refresh()).toBe(true);
  wall += 59_999;
  expect(lease.allows(peerId)).toBe(true);
  wall += 1;
  expect(lease.allows(peerId)).toBe(false);
  expect(invalidated).toEqual(["expired"]);
  lease.invalidate("closed");
});

test("an answer requested before a suspend is not accepted after it", async () => {
  let wall = 1_000_000;
  const pending = Promise.withResolvers<unknown>();
  const lease = new AuthorizationLease(identity, () => pending.promise, () => {},
    undefined, () => 0, undefined, undefined, () => wall);
  const refreshed = lease.refresh();
  wall += 60_000;
  pending.resolve(snapshot());
  expect(await refreshed).toBe(false);
  expect(lease.allows(peerId)).toBe(false);
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

test("a policy change pushed during a refresh keeps an answer that already reflects it", async () => {
  const pending = Promise.withResolvers<unknown>();
  let requests = 0;
  const reasons: string[] = [];
  const lease = new AuthorizationLease(identity, () => { requests++; return pending.promise; },
    (reason) => reasons.push(reason));
  const refreshed = lease.refresh();
  lease.observePolicyGeneration("2");
  expect(reasons).toEqual(["revoked"]);
  expect(lease.allows(peerId)).toBe(false);
  pending.resolve({ ...snapshot(), policyGeneration: "2" });
  expect(await refreshed).toBe(true);
  expect(requests).toBe(1);
  expect(lease.allows(peerId)).toBe(true);
  lease.invalidate("closed");
});

test("a policy change pushed during a refresh re-asks an answer read before it", async () => {
  const before = Promise.withResolvers<unknown>();
  const after = Promise.withResolvers<unknown>();
  let requests = 0;
  const lease = new AuthorizationLease(identity, () => ++requests === 1 ? before.promise : after.promise, () => {});
  const refreshed = lease.refresh();
  lease.observePolicyGeneration("2");
  const joined = lease.refresh();
  before.resolve(snapshot());
  await new Promise((resolve) => setTimeout(resolve, 0));
  expect(requests).toBe(2);
  expect(lease.allows(peerId)).toBe(false);
  after.resolve({ ...snapshot(), policyGeneration: "2" });
  expect(await refreshed).toBe(true);
  expect(await joined).toBe(true);
  expect(lease.allows(peerId)).toBe(true);
  lease.invalidate("closed");
});

test("an error that lands after a pushed policy change is re-asked, not thrown", async () => {
  const before = Promise.withResolvers<unknown>();
  let requests = 0;
  const lease = new AuthorizationLease(identity,
    () => ++requests === 1 ? before.promise : Promise.resolve({ ...snapshot(), policyGeneration: "2" }), () => {});
  const refreshed = lease.refresh();
  lease.observePolicyGeneration("2");
  before.reject(new Error("backend unavailable"));
  expect(await refreshed).toBe(true);
  expect(requests).toBe(2);
  lease.invalidate("closed");
});

test("accepted leases schedule jittered one-third refresh and their original expiry", async () => {
  let now = 0;
  const clock = manualScheduler();
  const lease = new AuthorizationLease(identity, async () => snapshot(), () => {}, undefined,
    () => now, () => 0.5, clock.schedule);

  expect(await lease.refresh()).toBe(true);
  expect(lease.remainingMs).toBe(60_000);
  expect(clock.jobs.filter((job) => job.active).map((job) => job.ms).sort((a, b) => a - b))
    .toEqual([20_000, 60_000]);
  now = 60_000;
  expect(lease.current).toBeNull();
});

test("transient refresh failure retains access only to the original deadline", async () => {
  let now = 0;
  let fail = false;
  const invalidated: string[] = [];
  const clock = manualScheduler();
  const lease = new AuthorizationLease(identity, async () => {
    if (fail) throw new Error("backend unavailable");
    return snapshot();
  }, (reason) => invalidated.push(reason), undefined, () => now, () => 0.5, clock.schedule);

  expect(await lease.refresh()).toBe(true);
  fail = true;
  now = 20_000;
  expect(await lease.refresh()).toBe(true);
  expect(lease.allows(peerId)).toBe(true);
  expect(clock.jobs.some((job) => job.active && job.ms === 375)).toBe(true);

  now = 60_000;
  expect(lease.allows(peerId)).toBe(false);
  expect(lease.remainingMs).toBe(0);
  expect(invalidated).toEqual(["expired"]);
});

test("timed-out authorization responses cannot revive a lease", async () => {
  let now = 0;
  const pending = Promise.withResolvers<unknown>();
  const clock = manualScheduler();
  const lease = new AuthorizationLease(identity, () => pending.promise, () => {}, undefined,
    () => now, () => 0.5, clock.schedule);

  const refresh = lease.refresh();
  const timeout = clock.jobs.find((job) => job.active && job.ms === 10_000);
  expect(timeout).toBeDefined();
  now = 10_000;
  timeout!.run();
  await expect(refresh).rejects.toThrow("AUTHORIZATION_TIMEOUT");
  pending.resolve(snapshot());
  await Promise.resolve();
  expect(lease.current).toBeNull();
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

// The bridge's enrollment and its lease must agree on which relay origins this
// host accepts. If they disagree, `register()` succeeds and the first refresh
// throws, so the native transport dies during startup and the WebSocket
// fallback hides it.
test("a plaintext relay origin is leased only where this host opted in", async () => {
  const run = async (value: string) => {
    const child = Bun.spawn(["bun", "run", join(import.meta.dir, "peer-dev-insecure-lease-fixture.ts")], {
      env: { ...process.env, ANTGRID_DEV_INSECURE_RELAY: value }, stdout: "pipe", stderr: "pipe",
    });
    const output = await new Response(child.stdout).text();
    await child.exited;
    return output.split("\n").find((line) => line.startsWith("RESULT "))?.slice(7).trim();
  };
  expect(await run("true")).toBe("true");
  expect(await run("false")).toBe("false");
}, 30_000);
