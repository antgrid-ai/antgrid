import { test, expect, describe } from "bun:test";
import type { JWK } from "jose";
import { JwksCache, JwksUnavailableError } from "../../src/license/jwks-cache.js";

interface FakeFetchOptions {
  keys?: JWK[];
  status?: number;
  reject?: Error;
  delayMs?: number;
}

function makeFetch(steps: FakeFetchOptions[]): {
  fetch: typeof fetch;
  callCount: () => number;
  urls: () => string[];
} {
  let i = 0;
  const urls: string[] = [];
  const fetchImpl = (async (input: URL | RequestInfo) => {
    urls.push(typeof input === "string" ? input : input.toString());
    const step = steps[Math.min(i, steps.length - 1)];
    i += 1;
    if (step.delayMs) {
      await new Promise((r) => setTimeout(r, step.delayMs));
    }
    if (step.reject) {
      throw step.reject;
    }
    const status = step.status ?? 200;
    return new Response(JSON.stringify({ keys: step.keys ?? [] }), {
      status,
      headers: { "content-type": "application/json" },
    });
  }) as typeof fetch;
  return {
    fetch: fetchImpl,
    callCount: () => i,
    urls: () => urls,
  };
}

const KEY_A: JWK = { kty: "OKP", crv: "Ed25519", x: "aaa", kid: "a" };
const KEY_B: JWK = { kty: "OKP", crv: "Ed25519", x: "bbb", kid: "b" };

describe("JwksCache", () => {
  test("first getKeys triggers exactly one fetch and returns keys", async () => {
    const f = makeFetch([{ keys: [KEY_A] }]);
    const cache = new JwksCache({
      licenseApiUrl: "http://license.test",
      fetchImpl: f.fetch,
    });

    const keys = await cache.getKeys();
    expect(keys).toEqual([KEY_A]);
    expect(f.callCount()).toBe(1);
    expect(f.urls()[0]).toBe("http://license.test/api/auth/jwks");
  });

  test("second getKeys within TTL does not fetch again", async () => {
    const f = makeFetch([{ keys: [KEY_A] }, { keys: [KEY_B] }]);
    const cache = new JwksCache({
      licenseApiUrl: "http://license.test",
      ttlMs: 60_000,
      fetchImpl: f.fetch,
    });

    const a = await cache.getKeys();
    const b = await cache.getKeys();
    expect(a).toEqual([KEY_A]);
    expect(b).toEqual([KEY_A]);
    expect(f.callCount()).toBe(1);
  });

  test("after TTL elapses, getKeys triggers a fresh fetch", async () => {
    const f = makeFetch([{ keys: [KEY_A] }, { keys: [KEY_B] }]);
    const cache = new JwksCache({
      licenseApiUrl: "http://license.test",
      ttlMs: 50,
      fetchImpl: f.fetch,
    });

    const first = await cache.getKeys();
    expect(first).toEqual([KEY_A]);

    await new Promise((r) => setTimeout(r, 70));

    const second = await cache.getKeys();
    expect(second).toEqual([KEY_B]);
    expect(f.callCount()).toBe(2);
  });

  test("single-flight: concurrent calls share one fetch", async () => {
    const f = makeFetch([{ keys: [KEY_A], delayMs: 30 }]);
    const cache = new JwksCache({
      licenseApiUrl: "http://license.test",
      fetchImpl: f.fetch,
    });

    const results = await Promise.all([
      cache.getKeys(),
      cache.getKeys(),
      cache.getKeys(),
      cache.getKeys(),
      cache.getKeys(),
    ]);

    expect(f.callCount()).toBe(1);
    for (const r of results) {
      expect(r).toEqual([KEY_A]);
      expect(r).toBe(results[0]); // same array instance
    }
  });

  test("stale-while-error: returns cached keys when refresh fails", async () => {
    const f = makeFetch([
      { keys: [KEY_A] },
      { reject: new Error("network down") },
    ]);
    const cache = new JwksCache({
      licenseApiUrl: "http://license.test",
      ttlMs: 20,
      fetchImpl: f.fetch,
    });

    const first = await cache.getKeys();
    expect(first).toEqual([KEY_A]);

    await new Promise((r) => setTimeout(r, 40));

    const second = await cache.getKeys();
    expect(second).toEqual([KEY_A]);
    expect(f.callCount()).toBe(2);
  });

  test("initial fetch failure (no cache) throws JwksUnavailableError", async () => {
    const f = makeFetch([{ reject: new Error("boom") }]);
    const cache = new JwksCache({
      licenseApiUrl: "http://license.test",
      fetchImpl: f.fetch,
    });

    await expect(cache.getKeys()).rejects.toThrow(/jwks_fetch_failed/i);
    // The license gate distinguishes "verifiably invalid" from "unknown, ask
    // again later" by this exact class — a plain Error would collapse both
    // into a terminal LICENSE_INVALID (hardening item 1 regression).
    let caught: unknown;
    try {
      await cache.getKeys();
    } catch (e) {
      caught = e;
    }
    expect(caught).toBeInstanceOf(JwksUnavailableError);
  });

  test("non-2xx response on initial fetch throws JwksUnavailableError", async () => {
    const f = makeFetch([{ status: 503, keys: [] }]);
    const cache = new JwksCache({
      licenseApiUrl: "http://license.test",
      fetchImpl: f.fetch,
    });

    await expect(cache.getKeys()).rejects.toThrow(/jwks_fetch_failed/i);
    let caught: unknown;
    try {
      await cache.getKeys();
    } catch (e) {
      caught = e;
    }
    expect(caught).toBeInstanceOf(JwksUnavailableError);
  });

  test("stale-while-error: a warm cache never throws JwksUnavailableError on refresh failure", async () => {
    const f = makeFetch([{ keys: [KEY_A] }, { reject: new Error("network down") }]);
    const cache = new JwksCache({
      licenseApiUrl: "http://license.test",
      ttlMs: 10,
      fetchImpl: f.fetch,
    });

    await cache.getKeys(); // warms the cache
    await new Promise((r) => setTimeout(r, 20));

    // Refresh fails, but a populated cache serves stale keys instead of throwing.
    await expect(cache.getKeys()).resolves.toEqual([KEY_A]);
  });

  test("the cold-cache failure is typed, so verify can classify it as retryable", async () => {
    // The type is the contract: verify.ts keys LICENSE_UNAVAILABLE off this
    // class. Downgrade it to a bare Error and every cold-cache outage silently
    // becomes LICENSE_INVALID again — terminal, fleet-wide.
    const f = makeFetch([{ reject: new Error("boom") }]);
    const cache = new JwksCache({
      licenseApiUrl: "http://license.test",
      fetchImpl: f.fetch,
    });

    await expect(cache.getKeys()).rejects.toBeInstanceOf(JwksUnavailableError);
  });

  test("stale-while-error does NOT raise unavailable — a warm cache still verifies", async () => {
    const f = makeFetch([
      { keys: [KEY_A] },
      { reject: new Error("network down") },
    ]);
    const cache = new JwksCache({
      licenseApiUrl: "http://license.test",
      ttlMs: 20,
      fetchImpl: f.fetch,
    });

    await cache.getKeys();
    await new Promise((r) => setTimeout(r, 40));

    expect(await cache.getKeys()).toEqual([KEY_A]);
  });

  test("a genuinely new kid still force-refreshes once (rotation self-heals)", async () => {
    const f = makeFetch([{ keys: [KEY_A] }, { keys: [KEY_A, KEY_B] }]);
    const cache = new JwksCache({
      licenseApiUrl: "http://license.test",
      ttlMs: 60_000,
      fetchImpl: f.fetch,
    });

    await cache.getKeys(); // warm with KEY_A only
    // kid "b" is absent → one force-refresh picks it up.
    expect(await cache.getKeys({ forKid: "b" })).toEqual([KEY_A, KEY_B]);
    expect(f.callCount()).toBe(2);
  });

  test("kid-miss force-refreshes are throttled — unknown kids can't amplify to web", async () => {
    // Finding #2: the hello sig verifies against the caller's OWN key, so an
    // unauthenticated attacker reaches the gate and can cycle novel kids. Each
    // distinct unknown kid must NOT map 1:1 to a relay→web fetch.
    const f = makeFetch([{ keys: [KEY_A] }]); // every fetch returns only KEY_A
    const cache = new JwksCache({
      licenseApiUrl: "http://license.test",
      ttlMs: 60_000,
      kidMissRefreshCooldownMs: 10_000,
      fetchImpl: f.fetch,
    });

    await cache.getKeys(); // warm: 1 fetch
    expect(f.callCount()).toBe(1);

    // First unknown kid → one refresh (still missing, but that's allowed once).
    await cache.getKeys({ forKid: "x1" });
    expect(f.callCount()).toBe(2);

    // A flood of further distinct unknown kids within the cooldown → NO fetches.
    for (let i = 0; i < 100; i++) {
      await cache.getKeys({ forKid: `flood-${i}` });
    }
    expect(f.callCount()).toBe(2);
  });

  test("after the cooldown elapses, a kid miss may refresh again", async () => {
    const f = makeFetch([{ keys: [KEY_A] }]);
    const cache = new JwksCache({
      licenseApiUrl: "http://license.test",
      ttlMs: 60_000,
      kidMissRefreshCooldownMs: 30,
      fetchImpl: f.fetch,
    });

    await cache.getKeys(); // warm: 1
    await cache.getKeys({ forKid: "y" }); // 2
    expect(f.callCount()).toBe(2);
    await cache.getKeys({ forKid: "z" }); // throttled: still 2
    expect(f.callCount()).toBe(2);

    await new Promise((r) => setTimeout(r, 45));
    await cache.getKeys({ forKid: "w" }); // cooldown passed → 3
    expect(f.callCount()).toBe(3);
  });
});
