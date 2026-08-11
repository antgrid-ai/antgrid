import { test, expect, describe } from "bun:test";
import { LicenseCache, type LicenseCacheEntry } from "../../src/license/cache.js";

const sample = (over: Partial<LicenseCacheEntry> = {}): LicenseCacheEntry => ({
  jti: "j1",
  deviceId: "d1",
  userId: "u1",
  tier: "pro",
  pk: "pk1",
  ...over,
});

describe("LicenseCache", () => {
  test("set + get by deviceId returns the entry", () => {
    const c = new LicenseCache({ maxEntries: 4 });
    c.set(sample());
    expect(c.get("d1")?.jti).toBe("j1");
    expect(c.get("d1")?.pk).toBe("pk1");
    expect(c.get("d1")?.revoked).toBe(false);
  });

  test("get returns undefined for unknown deviceId", () => {
    const c = new LicenseCache({ maxEntries: 4 });
    expect(c.get("missing")).toBeUndefined();
  });

  test("markRevoked by deviceId flips revoked flag in place", () => {
    const c = new LicenseCache({ maxEntries: 4 });
    c.set(sample());
    c.markRevoked("d1");
    expect(c.get("d1")?.revoked).toBe(true);
  });

  test("markRevoked on missing deviceId is a no-op", () => {
    const c = new LicenseCache({ maxEntries: 4 });
    expect(() => c.markRevoked("missing")).not.toThrow();
  });

  // One slot per deviceId, but a deviceId is unique per ACCOUNT only — two
  // accounts on the same physical device share the slot, and the last to verify
  // owns it. Unscoped, one account's revoke rejects the other's next hello.
  test("markRevoked scoped to a userId leaves another account's entry alone", () => {
    const c = new LicenseCache({ maxEntries: 4 });
    c.set(sample({ deviceId: "shared", userId: "u2" }));

    c.markRevoked("shared", "u1");
    expect(c.get("shared")?.revoked).toBe(false);

    c.markRevoked("shared", "u2");
    expect(c.get("shared")?.revoked).toBe(true);
  });

  test("dropByUser flips all entries for that user and returns deviceIds", () => {
    const c = new LicenseCache({ maxEntries: 4 });
    c.set(sample({ deviceId: "d1", userId: "u1" }));
    c.set(sample({ deviceId: "d2", userId: "u1" }));
    c.set(sample({ deviceId: "d3", userId: "u2" }));

    const dropped = c.dropByUser("u1");
    expect(dropped.sort()).toEqual(["d1", "d2"]);

    expect(c.get("d1")?.revoked).toBe(true);
    expect(c.get("d2")?.revoked).toBe(true);
    expect(c.get("d3")?.revoked).toBe(false);
  });

  test("dropByUser with no matches returns empty array", () => {
    const c = new LicenseCache({ maxEntries: 4 });
    c.set(sample());
    expect(c.dropByUser("nobody")).toEqual([]);
  });

  test("capacity eviction drops oldest", () => {
    const c = new LicenseCache({ maxEntries: 2 });
    c.set(sample({ deviceId: "a" }));
    c.set(sample({ deviceId: "b" }));
    c.set(sample({ deviceId: "c" }));
    expect(c.get("a")).toBeUndefined();
    expect(c.get("b")).toBeDefined();
    expect(c.get("c")).toBeDefined();
  });

  test("re-setting an existing deviceId does not evict", () => {
    const c = new LicenseCache({ maxEntries: 2 });
    c.set(sample({ deviceId: "d1", jti: "j1" }));
    c.set(sample({ deviceId: "d2", jti: "j2" }));
    c.set(sample({ deviceId: "d2", jti: "j2-new" }));

    expect(c.get("d1")).toBeDefined();
    expect(c.get("d2")?.jti).toBe("j2-new");
  });

  test("destroy clears state", () => {
    const c = new LicenseCache({ maxEntries: 10 });
    c.set(sample());
    c.destroy();
    expect(c.get("d1")).toBeUndefined();
    expect(() => c.destroy()).not.toThrow();
  });
});
