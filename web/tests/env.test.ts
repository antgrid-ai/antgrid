import { describe, test, expect, beforeEach, afterEach } from "bun:test";
import { writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { loadEnv } from "../src/env.js";

const baseSource = {
  PG_DATABASE_URL: "postgres://u:p@h:5432/db",
  BETTER_AUTH_SECRET: "x".repeat(32),
  BETTER_AUTH_URL: "http://localhost:8787",
  GITHUB_CLIENT_ID: "gh",
  GITHUB_CLIENT_SECRET: "ghs",
  GOOGLE_CLIENT_ID: "gl",
  GOOGLE_CLIENT_SECRET: "gls",
  CORS_ORIGINS: "http://a,https://b",
  PORT: "8787",
};

describe("loadEnv", () => {
  test("parses a valid env", () => {
    const env = loadEnv({
      NODE_ENV: "test",
      ...baseSource,
    });
    expect(env.PORT).toBe(8787);
    expect(env.CORS_ORIGINS).toEqual(["http://a", "https://b"]);
    expect(env.RELAY_INTERNAL_URL).toBeUndefined();
  });

  test("rejects missing required", () => {
    expect(() => loadEnv({})).toThrow(/PG_DATABASE_URL/);
  });

  test("Razorpay key id is undefined when env omits it (no config default)", () => {
    const env = loadEnv({ NODE_ENV: "development", ...baseSource });
    expect(env.RAZORPAY_KEY_ID).toBeUndefined();
  });

  test("RAZORPAY_KEY_ID comes from env", () => {
    const env = loadEnv({
      NODE_ENV: "development",
      ...baseSource,
      RAZORPAY_KEY_ID: "rzp_test_MyOwnKey",
    });
    expect(env.RAZORPAY_KEY_ID).toBe("rzp_test_MyOwnKey");
  });

  // A hand-pinned audience list in .env used to REPLACE the one the
  // orchestrator computes per run from the current LAN IP. Pinned on an old
  // network, it silently dropped the live audience and every mobile token mint
  // 400'd "requested resource invalid" — surfacing only as a relay connection
  // that never establishes.
  describe("EXTRA_TOKEN_AUDIENCES", () => {
    const dotenvPath = join(tmpdir(), `antgrid-env-test-${process.pid}.env`);
    const saved = { ...process.env };

    beforeEach(() => {
      for (const [k, v] of Object.entries(baseSource)) process.env[k] = v;
      process.env.NODE_ENV = "test";
    });

    afterEach(() => {
      for (const k of Object.keys(process.env)) if (!(k in saved)) delete process.env[k];
      for (const [k, v] of Object.entries(saved)) process.env[k] = v;
      rmSync(dotenvPath, { force: true });
    });

    test("unions the ambient value with a stale .env pin", () => {
      writeFileSync(dotenvPath, "EXTRA_TOKEN_AUDIENCES=http://192.168.31.3:8787/api/auth\n");
      process.env.EXTRA_TOKEN_AUDIENCES = "http://192.168.96.1:8787/api/auth";

      const env = loadEnv(process.env, { dotenvPath });

      expect(env.EXTRA_TOKEN_AUDIENCES).toContain("http://192.168.96.1:8787/api/auth");
      expect(env.EXTRA_TOKEN_AUDIENCES).toContain("http://192.168.31.3:8787/api/auth");
    });

    test("keeps a .env pin working when nothing is set ambiently", () => {
      writeFileSync(dotenvPath, "EXTRA_TOKEN_AUDIENCES=http://192.168.31.3:8787/api/auth\n");
      delete process.env.EXTRA_TOKEN_AUDIENCES;

      const env = loadEnv(process.env, { dotenvPath });

      expect(env.EXTRA_TOKEN_AUDIENCES).toEqual(["http://192.168.31.3:8787/api/auth"]);
    });

    test("de-duplicates when both sides name the same audience", () => {
      writeFileSync(dotenvPath, "EXTRA_TOKEN_AUDIENCES=http://a/api/auth\n");
      process.env.EXTRA_TOKEN_AUDIENCES = "http://a/api/auth";

      const env = loadEnv(process.env, { dotenvPath });

      expect(env.EXTRA_TOKEN_AUDIENCES).toEqual(["http://a/api/auth"]);
    });

    // The launcher knows the port it actually allocated; .env carries the
    // `npm run dev` default. File-wins aimed the revoke push at a dead port,
    // and the push only warns — so a revoke looked successful while the relay
    // never learned and the device stayed connected.
    test("RELAY_INTERNAL_URL: the launcher's value beats a stale .env pin", () => {
      writeFileSync(dotenvPath, "RELAY_INTERNAL_URL=http://127.0.0.1:8080\n");
      process.env.RELAY_INTERNAL_URL = "http://127.0.0.1:3000";

      const env = loadEnv(process.env, { dotenvPath });

      expect(env.RELAY_INTERNAL_URL).toBe("http://127.0.0.1:3000");
    });

    test("RELAY_INTERNAL_URL: .env still supplies it when nothing is ambient", () => {
      writeFileSync(dotenvPath, "RELAY_INTERNAL_URL=http://127.0.0.1:8080\n");
      delete process.env.RELAY_INTERNAL_URL;

      const env = loadEnv(process.env, { dotenvPath });

      expect(env.RELAY_INTERNAL_URL).toBe("http://127.0.0.1:8080");
    });

    test("stays empty when neither side sets it", () => {
      writeFileSync(dotenvPath, "\n");
      delete process.env.EXTRA_TOKEN_AUDIENCES;

      const env = loadEnv(process.env, { dotenvPath });

      expect(env.EXTRA_TOKEN_AUDIENCES).toEqual([]);
    });
  });
});
