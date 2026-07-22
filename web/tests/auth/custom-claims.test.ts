import { describe, test, expect, beforeAll, afterAll, beforeEach } from "bun:test";
import { decodeJwt } from "jose";
import { startTestPg, type PgHandle } from "../helpers/pg.js";
import { buildTestApp } from "../helpers/app.js";
import { createTestUser, createTestSession, createTestSubscription } from "../helpers/fixtures.js";
import { ensureFreeSubscription } from "../../src/models/subscription.js";

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

/**
 * Provision a device for the given user: creates a session-authed POST to
 * /account/devices and returns the OAuth credentials + the ed25519Pub used.
 */
async function provisionDevice(
  app: ReturnType<typeof buildTestApp>["app"],
  userId: string,
  cookie: string,
  opts: { pubByte?: number; deviceUuid?: string } = {}
) {
  const deviceUuid = opts.deviceUuid ?? crypto.randomUUID();
  const pub = Buffer.alloc(32, opts.pubByte ?? 0xab).toString("base64");
  const res = await app.request("/account/devices", {
    method: "POST",
    headers: { cookie, "content-type": "application/json" },
    body: JSON.stringify({
      deviceUuid,
      ed25519Pub: pub,
      x25519Pub: Buffer.alloc(32, 0xcd).toString("base64"),
      platform: "macos",
      displayName: "test machine",
    }),
  });
  if (res.status !== 201) {
    throw new Error(`provisionDevice failed: ${res.status} ${await res.text()}`);
  }
  const creds = (await res.json()) as { deviceUuid: string; clientId: string; clientSecret: string };
  return { creds, pub };
}

async function mintToken(
  app: ReturnType<typeof buildTestApp>["app"],
  clientId: string,
  clientSecret: string,
  resource: string = AGENT_RESOURCE
) {
  return app.request("/api/auth/oauth2/token", {
    method: "POST",
    headers: {
      "content-type": "application/x-www-form-urlencoded",
      authorization: "Basic " + Buffer.from(`${clientId}:${clientSecret}`).toString("base64"),
    },
    // `resource` is required to get a JWT rather than an opaque token.
    // Better-Auth validates it against ctx.context.baseURL (= BETTER_AUTH_URL + "/api/auth").
    body: `grant_type=client_credentials&scope=agent&resource=${encodeURIComponent(resource)}`,
  });
}

describe("customAccessTokenClaims", () => {
  test("injects {uid, deviceUuid, tier, sessionLimit, email, pk} on minted client_credentials JWT", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const user = await createTestUser(pg.db, "alice@example.com");
    const { cookie } = await createTestSession(pg.db, user.id);
    await createTestSubscription(pg.db, user.id, { tier: "pro" });

    const { creds, pub } = await provisionDevice(app, user.id, cookie);

    const res = await mintToken(app, creds.clientId, creds.clientSecret);
    expect(res.status).toBe(200);

    const body = (await res.json()) as { access_token: string; expires_in: number };
    expect(body.expires_in).toBe(3600);

    const claims = decodeJwt(body.access_token) as Record<string, unknown>;
    expect(claims.uid).toBe(user.id);
    expect(claims.deviceUuid).toBe(creds.deviceUuid);
    expect(claims.tier).toBe("pro");
    // The paid axis: the relay reads this claim and enforces the concurrent
    // remote-agent cap at register. If web ever stops minting it, the relay
    // silently falls back to its tier table — so assert it lands here.
    expect(claims.sessionLimit).toBe(10);
    expect(claims.email).toBe("alice@example.com");
    expect(claims.pk).toBe(pub);
  });

  // A LAN-IP `resource` (the app mints against the dev machine's LAN IP so an
  // emulator/phone can reach web) is only accepted when it's in
  // EXTRA_TOKEN_AUDIENCES; otherwise the oauth-provider rejects it. The minted
  // JWT's issuer stays BETTER_AUTH_URL regardless — see web/src/auth/oauth-provider.ts.
  const LAN_RESOURCE = "http://192.168.1.50:8787/api/auth";

  test("accepts a LAN-IP resource when listed in EXTRA_TOKEN_AUDIENCES", async () => {
    const { app } = buildTestApp(pg.db, pg.url, {
      envOverrides: { EXTRA_TOKEN_AUDIENCES: [LAN_RESOURCE] },
    });
    const user = await createTestUser(pg.db, "dave@example.com");
    const { cookie } = await createTestSession(pg.db, user.id);
    await createTestSubscription(pg.db, user.id, { tier: "pro" });
    const { creds } = await provisionDevice(app, user.id, cookie);

    const res = await mintToken(app, creds.clientId, creds.clientSecret, LAN_RESOURCE);
    expect(res.status).toBe(200);

    const body = (await res.json()) as { access_token: string };
    const claims = decodeJwt(body.access_token) as Record<string, unknown>;
    // Issuer stays pinned to BETTER_AUTH_URL even though the audience is the LAN IP.
    expect(claims.iss).toBe("http://localhost:8787/api/auth");
    expect(claims.uid).toBe(user.id);
  });

  test("rejects a LAN-IP resource that is not in EXTRA_TOKEN_AUDIENCES", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const user = await createTestUser(pg.db, "erin@example.com");
    const { cookie } = await createTestSession(pg.db, user.id);
    await createTestSubscription(pg.db, user.id, { tier: "pro" });
    const { creds } = await provisionDevice(app, user.id, cookie);

    const res = await mintToken(app, creds.clientId, creds.clientSecret, LAN_RESOURCE);
    expect(res.status).toBe(400);
  });

  test("emits tier: pro for a newly-provisioned user (promotional grant)", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const user = await createTestUser(pg.db, "bob@example.com");
    const { cookie } = await createTestSession(pg.db, user.id);

    const me = await app.request("/account/me", { headers: { cookie } });
    expect(me.status).toBe(200);
    expect((await me.json()).tier).toBe("pro");
  });

  test("re-promotes to the promotional grant after a real subscription expires", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const user = await createTestUser(pg.db, "carol@example.com");
    const { cookie } = await createTestSession(pg.db, user.id);
    await createTestSubscription(pg.db, user.id, { tier: "pro" });

    const { creds } = await provisionDevice(app, user.id, cookie, { pubByte: 0x42 });

    const account = await pg.db.productAccount.findUnique({ where: { userId: user.id } });
    await pg.db.subscription.updateMany({
      where: { accountId: account!.id },
      data: { status: "expired", cancelledAt: new Date() },
    });
    // Mirrors what the real webhook-expiry path leaves behind: a genuinely
    // free, unblocked-in-name-only row.
    const free = await ensureFreeSubscription(pg.db, account!.id);
    expect(free.tier).toBe("free");

    // Minting a token re-provisions via provisionProductAccountForUser, which
    // upgrades a lingering real-free sub back to the promotional grant — so a
    // lapsed real subscription doesn't leave the user session-blocked during
    // the promo (see ensureDefaultSubscription).
    const res = await mintToken(app, creds.clientId, creds.clientSecret);
    expect(res.status).toBe(200);

    const body = (await res.json()) as { access_token: string };
    const claims = decodeJwt(body.access_token) as Record<string, unknown>;
    expect(claims.tier).toBe("pro");
    expect(claims.sessionLimit).toBe(10);
    expect(claims.uid).toBe(user.id);
  });
});
