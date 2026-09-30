// SPDX-FileCopyrightText: 2026 Radha AI Products
// SPDX-License-Identifier: LicenseRef-Elastic-2.0

import { afterEach, describe, expect, spyOn, test } from "bun:test";
import { Hono } from "hono";
import { parseTrustedProxies } from "antgrid-wire";
import { makeClientIpResolver } from "../../src/util/client-ip.js";
import { oauthTokenRateLimit, OAUTH_TOKEN_BURST } from "../../src/auth/oauth-token-rate-limit.js";
import { memoryAdapter } from "better-auth/adapters/memory";
import { createAuth } from "../../src/auth/better-auth.js";
import type { DB } from "../../src/db/index.js";
import type { Env } from "../../src/env.js";

let now = 1_000_000;
let time: ReturnType<typeof spyOn>;
afterEach(() => time?.mockRestore());

function harness() {
  now = 1_000_000;
  time = spyOn(Date, "now").mockImplementation(() => now);
  const app = new Hono();
  const clientIp = makeClientIpResolver(parseTrustedProxies("172.28.0.0/16"));
  app.use("/api/auth/*", oauthTokenRateLimit(clientIp));
  let forwarded = 0;
  app.all("/api/auth/*", (c) => {
    forwarded++;
    return c.json({ error: "invalid_client" }, 400);
  });
  const request = (xff = "203.0.113.1", path = "/api/auth/oauth2/token", method = "POST") =>
    app.request(path, { method, headers: { "x-forwarded-for": xff } },
      { requestIP: () => ({ address: "172.28.0.9" }) });
  return { request, forwarded: () => forwarded };
}

describe("OAuth token rate limit", () => {
  test("the OAuth handler replaces only the token idle-reset counter", async () => {
    now = Date.now();
    time = spyOn(Date, "now").mockImplementation(() => now);
    const db = {} as DB;
    const env = {
      NODE_ENV: "test",
      BETTER_AUTH_URL: "http://localhost:8787",
      BETTER_AUTH_SECRET: "antgrid-test-secret-for-oauth-rate-limit-tests",
      TRUSTED_PROXY_IPS: [],
      CORS_ORIGINS: [],
    } as unknown as Env;
    const sendEmail = async () => {};
    const auth = createAuth({
      env, db, sendEmail,
      databaseOverride: memoryAdapter({ oauthClient: [] }),
    });
    (await auth.$context).rateLimit.enabled = true;
    const app = new Hono();
    const clientIp = makeClientIpResolver([]);
    app.use("/api/auth/*", oauthTokenRateLimit(clientIp));
    app.all("/api/auth/*", (c) => {
      const headers = new Headers(c.req.raw.headers);
      headers.set("x-forwarded-for", clientIp(c)!);
      return auth.handler(new Request(c.req.raw, { headers }));
    });
    const post = (path = "/api/auth/oauth2/token", ip = "203.0.113.41") =>
      app.request(path, {
        method: "POST",
        headers: {
          "content-type": "application/x-www-form-urlencoded",
          authorization: "Basic " + Buffer.from("bogus:bogus").toString("base64"),
        },
        body: "grant_type=client_credentials&scope=agent",
      }, { requestIP: () => ({ address: ip }) });
    for (let i = 0; i < 40; i++) {
      const res = await post();
      expect(res.status).toBe(400);
      expect((await res.json()).error).toBe("invalid_client");
      now += 20_000;
    }
    for (let i = 0; i < OAUTH_TOKEN_BURST; i++) await post();
    expect((await post()).status).toBe(429);
    expect((await post("/api/auth/oauth2/token/")).status).toBe(429);
    expect((await post(undefined, "203.0.113.42")).status).toBe(400);
    expect(auth.options.rateLimit?.customRules?.["/sign-in/email"]).toEqual({ window: 60, max: 10 });
    const before = (await auth.$context).rateLimit.customRules;
    expect(before?.["/oauth2/token"]).toBe(false);
  });

  test("sustained legacy lease traffic on a shared IP keeps refilling", async () => {
    const h = harness();
    for (let tick = 0; tick < 90; tick++) {
      for (let device = 0; device < 30; device++) {
        expect((await h.request()).status).toBe(400);
      }
      now += 20_000;
    }
    expect(h.forwarded()).toBe(2700);
  });

  test("bounds bursts, counts failed credentials, and recovers without an idle minute", async () => {
    const h = harness();
    for (let i = 0; i < OAUTH_TOKEN_BURST; i++) expect((await h.request()).status).toBe(400);
    const limited = await h.request();
    expect(limited.status).toBe(429);
    expect(limited.headers.get("retry-after")).toBe("1");
    expect(limited.headers.get("x-retry-after")).toBe("1");
    expect(h.forwarded()).toBe(OAUTH_TOKEN_BURST);
    now += 1000;
    expect((await h.request()).status).toBe(400);
  });

  test("forged forwarding chains cannot escape a bucket and real IPs are independent", async () => {
    const h = harness();
    for (let i = 0; i < OAUTH_TOKEN_BURST; i++) {
      expect((await h.request(`10.0.0.${i}, 203.0.113.1`)).status).toBe(400);
    }
    expect((await h.request("10.1.1.1, 203.0.113.1")).status).toBe(429);
    expect((await h.request("203.0.113.2")).status).toBe(400);
  });

  test("only token POSTs consume the bucket, including trailing-slash paths", async () => {
    const h = harness();
    for (let i = 0; i < OAUTH_TOKEN_BURST; i++) await h.request();
    expect((await h.request(undefined, "/api/auth/oauth2/token/")).status).toBe(429);
    expect((await h.request(undefined, "/api/auth/sign-in/email")).status).toBe(400);
    expect((await h.request(undefined, undefined, "GET")).status).toBe(400);
  });
});
