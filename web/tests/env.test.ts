import { describe, test, expect } from "bun:test";
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
});
