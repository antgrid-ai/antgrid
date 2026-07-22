import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { loadConfig } from "../src/config";

const VALID_SECRET = "x".repeat(16);
const TOUCHED_KEYS = [
  "LICENSE_API_URL",
  "LICENSE_ISSUER_URL",
  "RELAY_INTERNAL_SECRET",
  "LICENSE_CACHE_MAX_ENTRIES",
] as const;

describe("loadConfig", () => {
  let saved: Record<string, string | undefined> = {};

  beforeEach(() => {
    saved = {};
    for (const k of TOUCHED_KEYS) {
      saved[k] = process.env[k];
      delete process.env[k];
    }
  });

  afterEach(() => {
    for (const k of TOUCHED_KEYS) {
      const v = saved[k];
      if (v === undefined) delete process.env[k];
      else process.env[k] = v;
    }
  });

  test("throws when LICENSE_API_URL is missing", () => {
    process.env.RELAY_INTERNAL_SECRET = VALID_SECRET;
    expect(() => loadConfig()).toThrow(/LICENSE_API_URL/);
  });

  test("throws when LICENSE_API_URL is empty", () => {
    process.env.LICENSE_API_URL = "";
    process.env.RELAY_INTERNAL_SECRET = VALID_SECRET;
    expect(() => loadConfig()).toThrow(/LICENSE_API_URL/);
  });

  test("throws when RELAY_INTERNAL_SECRET is missing", () => {
    process.env.LICENSE_API_URL = "http://localhost:8787";
    expect(() => loadConfig()).toThrow(/RELAY_INTERNAL_SECRET/);
  });

  test("throws when RELAY_INTERNAL_SECRET is too short", () => {
    process.env.LICENSE_API_URL = "http://localhost:8787";
    process.env.RELAY_INTERNAL_SECRET = "tooshort";
    expect(() => loadConfig()).toThrow(/RELAY_INTERNAL_SECRET.*16/);
  });

  test("loads with required vars set; defaults licenseCacheMaxEntries to 100000", () => {
    process.env.LICENSE_API_URL = "http://localhost:8787";
    process.env.RELAY_INTERNAL_SECRET = VALID_SECRET;
    const cfg = loadConfig();
    expect(cfg.licenseApiUrl).toBe("http://localhost:8787");
    expect(cfg.relayInternalSecret).toBe(VALID_SECRET);
    expect(cfg.licenseCacheMaxEntries).toBe(100000);
  });

  // licenseApiUrl may point at an internal address (docker DNS) for fast JWKS
  // fetches, which is NOT necessarily the public BETTER_AUTH_URL that Better-Auth
  // stamps into every token's `iss`. licenseIssuerUrl is undefined unless a
  // deployment opts in, so a single-host setup (local dev) needs no new config.
  test("licenseIssuerUrl is undefined when LICENSE_ISSUER_URL is unset", () => {
    process.env.LICENSE_API_URL = "http://web-blue:8787";
    process.env.RELAY_INTERNAL_SECRET = VALID_SECRET;
    const cfg = loadConfig();
    expect(cfg.licenseIssuerUrl).toBeUndefined();
  });

  test("licenseIssuerUrl is read from LICENSE_ISSUER_URL when set, independent of licenseApiUrl", () => {
    process.env.LICENSE_API_URL = "http://web-blue:8787";
    process.env.LICENSE_ISSUER_URL = "https://app.staging.antgrid.ai";
    process.env.RELAY_INTERNAL_SECRET = VALID_SECRET;
    const cfg = loadConfig();
    expect(cfg.licenseApiUrl).toBe("http://web-blue:8787");
    expect(cfg.licenseIssuerUrl).toBe("https://app.staging.antgrid.ai");
  });

  test("respects LICENSE_CACHE_MAX_ENTRIES override", () => {
    process.env.LICENSE_API_URL = "http://localhost:8787";
    process.env.RELAY_INTERNAL_SECRET = VALID_SECRET;
    process.env.LICENSE_CACHE_MAX_ENTRIES = "42";
    const cfg = loadConfig();
    expect(cfg.licenseCacheMaxEntries).toBe(42);
  });

  test("v3 keys default: clockSkewMs, replayTtlMs, staleGrantDays, jsonRateLimit*", () => {
    process.env.LICENSE_API_URL = "http://localhost:8787";
    process.env.RELAY_INTERNAL_SECRET = VALID_SECRET;
    const cfg = loadConfig();
    expect(cfg.clockSkewMs).toBe(120_000);
    expect(cfg.replayTtlMs).toBe(300_000);
    expect(cfg.staleGrantDays).toBe(30);
    expect(cfg.jsonRateLimitPerSec).toBe(10);
    expect(cfg.jsonRateLimitBurst).toBe(30);
  });

  test("v3 keys respect env overrides", () => {
    process.env.LICENSE_API_URL = "http://localhost:8787";
    process.env.RELAY_INTERNAL_SECRET = VALID_SECRET;
    process.env.CLOCK_SKEW_MS = "5000";
    process.env.REPLAY_TTL_MS = "20000"; // must stay >= 2 * CLOCK_SKEW_MS
    process.env.STALE_GRANT_DAYS = "7";
    process.env.JSON_RATE_LIMIT_PER_SEC = "1";
    process.env.JSON_RATE_LIMIT_BURST = "2";
    try {
      const cfg = loadConfig();
      expect(cfg.clockSkewMs).toBe(5000);
      expect(cfg.replayTtlMs).toBe(20000);
      expect(cfg.staleGrantDays).toBe(7);
      expect(cfg.jsonRateLimitPerSec).toBe(1);
      expect(cfg.jsonRateLimitBurst).toBe(2);
    } finally {
      delete process.env.CLOCK_SKEW_MS;
      delete process.env.REPLAY_TTL_MS;
      delete process.env.STALE_GRANT_DAYS;
      delete process.env.JSON_RATE_LIMIT_PER_SEC;
      delete process.env.JSON_RATE_LIMIT_BURST;
    }
  });

  test("rejects REPLAY_TTL_MS < 2 * CLOCK_SKEW_MS (a nonce would expire mid-window)", () => {
    process.env.LICENSE_API_URL = "http://localhost:8787";
    process.env.RELAY_INTERNAL_SECRET = VALID_SECRET;
    process.env.CLOCK_SKEW_MS = "120000";
    process.env.REPLAY_TTL_MS = "200000"; // < 240000
    try {
      expect(() => loadConfig()).toThrow(/REPLAY_TTL_MS.*CLOCK_SKEW_MS/);
    } finally {
      delete process.env.CLOCK_SKEW_MS;
      delete process.env.REPLAY_TTL_MS;
    }
  });

  test("accepts REPLAY_TTL_MS exactly at the 2 * CLOCK_SKEW_MS floor", () => {
    process.env.LICENSE_API_URL = "http://localhost:8787";
    process.env.RELAY_INTERNAL_SECRET = VALID_SECRET;
    process.env.CLOCK_SKEW_MS = "60000";
    process.env.REPLAY_TTL_MS = "120000"; // == 2 * skew
    try {
      const cfg = loadConfig();
      expect(cfg.replayTtlMs).toBe(120000);
    } finally {
      delete process.env.CLOCK_SKEW_MS;
      delete process.env.REPLAY_TTL_MS;
    }
  });

  // R1 deletes the v2 offline-queue and stale-pair-timeout knobs outright —
  // pin their absence so a reintroduction doesn't slip back in unnoticed.
  test("v2 offline-queue / stale-pair knobs are gone", () => {
    process.env.LICENSE_API_URL = "http://localhost:8787";
    process.env.RELAY_INTERNAL_SECRET = VALID_SECRET;
    const cfg = loadConfig() as unknown as Record<string, unknown>;
    for (const removed of ["maxQueueMessages", "maxQueueSizeBytes", "stalePairTimeoutHours"]) {
      expect(cfg).not.toHaveProperty(removed);
    }
  });
});
