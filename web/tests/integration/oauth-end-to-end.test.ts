import { describe, test, expect, beforeAll, afterAll, beforeEach } from "bun:test";
import { jwtVerify, createLocalJWKSet, type JSONWebKeySet } from "jose";
import { startTestPg, type PgHandle } from "../helpers/pg.js";
import { buildTestApp } from "../helpers/app.js";
import { createTestUser, createTestSession, createTestSubscription } from "../helpers/fixtures.js";

/**
 * Better-Auth's oauth-provider only mints a JWT (vs an opaque token) when a
 * `resource` parameter is present in the token request. It validates the value
 * against `opts.validAudiences ?? [ctx.context.baseURL]` where
 * `ctx.context.baseURL = BETTER_AUTH_URL + "/api/auth"`. Pass that URL so
 * every token request in this file gets a real JWT back.
 */
const AGENT_RESOURCE = "http://localhost:8787/api/auth";

let pg: PgHandle;
beforeAll(async () => {
  pg = await startTestPg();
});
afterAll(async () => {
  await pg.stop();
});
beforeEach(async () => {
  await pg.truncate();
});

describe("OAuth end-to-end", () => {
  test("signed-in user can provision a device, mint a JWT, and the JWT verifies against JWKS", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const user = await createTestUser(pg.db, "alice@example.com");
    await createTestSubscription(pg.db, user.id, { tier: "pro" });
    const { cookie } = await createTestSession(pg.db, user.id);

    const deviceUuid = crypto.randomUUID();
    const pub = Buffer.alloc(32, 0xab).toString("base64");
    const provision = await app.request("/account/devices", {
      method: "POST",
      headers: { cookie, "content-type": "application/json" },
      body: JSON.stringify({
        deviceUuid,
        ed25519Pub: pub,
        x25519Pub: Buffer.alloc(32, 0xcd).toString("base64"),
        platform: "linux",
        displayName: "alice-laptop",
      }),
    });
    expect(provision.status).toBe(201);
    const creds = (await provision.json()) as {
      deviceUuid: string;
      clientId: string;
      clientSecret: string;
    };

    // Mint a JWT — `resource` parameter is required for Better-Auth to emit a
    // JWT instead of an opaque token.
    const mint = await app.request("/api/auth/oauth2/token", {
      method: "POST",
      headers: {
        "content-type": "application/x-www-form-urlencoded",
        authorization:
          "Basic " +
          Buffer.from(`${creds.clientId}:${creds.clientSecret}`).toString("base64"),
      },
      body: new URLSearchParams({
        grant_type: "client_credentials",
        scope: "agent",
        resource: AGENT_RESOURCE,
      }).toString(),
    });
    expect(mint.status).toBe(200);
    const tokenJson = (await mint.json()) as {
      access_token: string;
      token_type: string;
      expires_in: number;
    };
    expect(tokenJson.token_type.toLowerCase()).toBe("bearer");
    expect(tokenJson.expires_in).toBe(3600);

    // Fetch JWKS via the in-process app — this is the exact path the relay's
    // JwksCache hits in production.
    const jwksRes = await app.request("/api/auth/jwks");
    expect(jwksRes.status).toBe(200);
    const jwks = (await jwksRes.json()) as JSONWebKeySet;
    expect(jwks.keys.length).toBeGreaterThan(0);
    expect(jwks.keys[0].kty).toBe("OKP");
    expect(jwks.keys[0].crv).toBe("Ed25519");

    // Cryptographic verification — what the relay does in production.
    const keySet = createLocalJWKSet(jwks);
    const verified = await jwtVerify(tokenJson.access_token, keySet, {
      algorithms: ["EdDSA"],
    });
    const payload = verified.payload as Record<string, unknown>;
    expect(payload.uid).toBe(user.id);
    expect(payload.deviceUuid).toBe(creds.deviceUuid);
    expect(payload.tier).toBe("pro");
    expect(payload.email).toBe("alice@example.com");
    expect(payload.pk).toBe(pub);
  });
});
