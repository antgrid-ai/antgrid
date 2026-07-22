import { describe, expect, it, beforeAll, afterAll } from "bun:test";
import { createAuth } from "../../src/auth/better-auth.js";
import { startTestPg, type PgHandle } from "../helpers/pg.js";
import type { Env } from "../../src/env.js";

let pg: PgHandle;
beforeAll(async () => {
  pg = await startTestPg();
});
afterAll(async () => {
  await pg.stop();
});

function makeTestEnv(url: string): Env {
  return {
    NODE_ENV: "test",
    PG_DATABASE_URL: url,
    BETTER_AUTH_SECRET: "antgrid-test-better-auth-secret-for-tests-only",
    BETTER_AUTH_URL: "http://localhost:8787",
    GITHUB_CLIENT_ID: "gh",
    GITHUB_CLIENT_SECRET: "ghs",
    GOOGLE_CLIENT_ID: "gl",
    GOOGLE_CLIENT_SECRET: "gls",
    EMAIL_FROM: "Antgrid <no-reply@radhaai.org>",
    CORS_ORIGINS: ["http://localhost:4321"],
    PORT: 0,
  } as Env;
}

describe("OAuth Provider plugin", () => {
  it("exposes JWKS at /api/auth/jwks with at least one Ed25519 key", async () => {
    const env = makeTestEnv(pg.url);
    const auth = createAuth({ env, db: pg.db, sendEmail: async () => {} });
    const res = await auth.handler(new Request(`${env.BETTER_AUTH_URL}/api/auth/jwks`));
    expect(res.status).toBe(200);
    const body = (await res.json()) as { keys: { kty: string; crv?: string }[] };
    expect(Array.isArray(body.keys)).toBe(true);
    expect(body.keys.length).toBeGreaterThan(0);
    expect(body.keys[0].kty).toBe("OKP");
    expect(body.keys[0].crv).toBe("Ed25519");
  });

  it("exposes the OAuth token endpoint and refuses unknown clients", async () => {
    const env = makeTestEnv(pg.url);
    const auth = createAuth({ env, db: pg.db, sendEmail: async () => {} });
    const res = await auth.handler(
      new Request(`${env.BETTER_AUTH_URL}/api/auth/oauth2/token`, {
        method: "POST",
        headers: {
          "content-type": "application/x-www-form-urlencoded",
          authorization: "Basic " + Buffer.from("bogus:bogus").toString("base64"),
        },
        body: "grant_type=client_credentials&scope=agent",
      })
    );
    // RFC 6749 §5.2 allows either 400 or 401 for invalid_client.
    // @better-auth/oauth-provider@1.6.11 returns 400 for an unknown client_id.
    expect([400, 401]).toContain(res.status);
  });
});
