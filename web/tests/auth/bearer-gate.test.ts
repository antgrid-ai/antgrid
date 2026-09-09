import { describe, test, expect, beforeAll, afterAll, beforeEach } from "bun:test";
import { Hono } from "hono";
import { SignJWT, importJWK } from "jose";
import { symmetricDecrypt } from "better-auth/crypto";
import { startTestPg, type PgHandle } from "../helpers/pg.js";
import { buildTestApp, TEST_BETTER_AUTH_SECRET } from "../helpers/app.js";
import {
  createTestUser,
  createTestSession,
  createTestSubscription,
  createTestDevice,
} from "../helpers/fixtures.js";
import { requireBearerJwt } from "../../src/auth/jwt-bearer.js";
import type { AuthVars } from "../../src/auth/middleware.js";

const ISSUER = "http://localhost:8787/api/auth";

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
 * The gate under test, mounted on a probe route that echoes the context it
 * populated. No production route exposes `deviceId`, so this is the only way to
 * assert the resolved device actually reaches a handler.
 */
function buildProbe(built: ReturnType<typeof buildTestApp>) {
  const r = new Hono<{ Variables: AuthVars }>();
  r.use("/probe", requireBearerJwt({ auth: built.auth, db: pg.db, env: built.env }));
  r.get("/probe", (c) =>
    c.json({
      userId: c.get("userId"),
      sessionId: c.get("sessionId"),
      deviceId: c.get("deviceId") ?? null,
    })
  );
  return r;
}

function probe(r: ReturnType<typeof buildProbe>, token: string) {
  return r.request("/probe", { headers: { authorization: `Bearer ${token}` } });
}

/** Register a device and mint its token the way the bridge does in production. */
async function provisionAndMint(
  built: ReturnType<typeof buildTestApp>,
  cookie: string
): Promise<{ token: string; deviceUuid: string }> {
  const deviceUuid = crypto.randomUUID();
  const provision = await built.app.request("/account/devices", {
    method: "POST",
    headers: { cookie, "content-type": "application/json" },
    body: JSON.stringify({
      deviceUuid,
      ed25519Pub: Buffer.alloc(32, 0xab).toString("base64"),
      x25519Pub: Buffer.alloc(32, 0xcd).toString("base64"),
      platform: "linux",
      displayName: "bearer-gate-agent",
    }),
  });
  if (provision.status !== 201) {
    throw new Error(`provision failed: ${provision.status} ${await provision.text()}`);
  }
  const creds = (await provision.json()) as { clientId: string; clientSecret: string };
  const mint = await built.app.request("/api/auth/oauth2/token", {
    method: "POST",
    headers: {
      "content-type": "application/x-www-form-urlencoded",
      authorization:
        "Basic " + Buffer.from(`${creds.clientId}:${creds.clientSecret}`).toString("base64"),
    },
    // `resource` is what makes Better-Auth emit a JWT rather than an opaque token.
    body: new URLSearchParams({
      grant_type: "client_credentials",
      scope: "agent",
      resource: ISSUER,
    }).toString(),
  });
  if (mint.status !== 200) {
    throw new Error(`mint failed: ${mint.status} ${await mint.text()}`);
  }
  return { token: ((await mint.json()) as { access_token: string }).access_token, deviceUuid };
}

/**
 * Sign a token with the live JWKS private key, so the gate sees a genuine
 * signature and issuer and the claim set is the only variable. The token
 * endpoint refuses to mint anything but a full `agent` token, so claim-shaped
 * cases (no scope, a foreign deviceUuid) are unreachable through it.
 */
async function forgeToken(
  built: ReturnType<typeof buildTestApp>,
  claims: Record<string, unknown>
): Promise<string> {
  await built.app.request("/api/auth/jwks");
  const row = await pg.db.jwks.findFirstOrThrow();
  const jwk = JSON.parse(
    await symmetricDecrypt({
      key: TEST_BETTER_AUTH_SECRET,
      data: JSON.parse(row.privateKey) as string,
    })
  ) as Record<string, unknown>;
  const key = (await importJWK(jwk, "EdDSA")) as CryptoKey;
  return new SignJWT(claims)
    .setProtectedHeader({ alg: "EdDSA", kid: row.id })
    .setIssuer(ISSUER)
    .setAudience(ISSUER)
    .setIssuedAt()
    .setExpirationTime("1h")
    .sign(key);
}

async function payingUser(email: string) {
  const user = await createTestUser(pg.db, email);
  await createTestSubscription(pg.db, user.id, { tier: "pro" });
  const { cookie } = await createTestSession(pg.db, user.id);
  return { user, cookie };
}

describe("requireBearerJwt device resolution", () => {
  test("a live device passes and its id reaches the handler", async () => {
    const built = buildTestApp(pg.db, pg.url);
    const { user, cookie } = await payingUser("alice@example.com");
    const { token, deviceUuid } = await provisionAndMint(built, cookie);

    const res = await probe(buildProbe(built), token);
    expect(res.status).toBe(200);
    const body = (await res.json()) as Record<string, unknown>;
    expect(body.userId).toBe(user.id);
    expect(body.deviceId).toBe(deviceUuid);
    // Bearer callers have no session, so `deviceId` is the only actor-type signal.
    expect(body.sessionId).toBe("");
  });

  test("a revoked device's still-valid JWT is refused", async () => {
    const built = buildTestApp(pg.db, pg.url);
    const { user, cookie } = await payingUser("bob@example.com");
    const { token, deviceUuid } = await provisionAndMint(built, cookie);
    const r = buildProbe(built);
    expect((await probe(r, token)).status).toBe(200);

    // Revocation deletes the OAuth client but cannot reach an already-minted
    // token, which stays signature-valid for its full hour.
    await pg.db.device.update({
      where: { userId_deviceId: { userId: user.id, deviceId: deviceUuid } },
      data: { revokedAt: new Date() },
    });

    expect((await probe(r, token)).status).toBe(401);
  });

  test("a token naming another user's device is refused", async () => {
    const built = buildTestApp(pg.db, pg.url);
    const { user: alice, cookie } = await payingUser("alice2@example.com");
    await provisionAndMint(built, cookie);
    const bob = await createTestUser(pg.db, "bob2@example.com");
    const bobDeviceId = crypto.randomUUID();
    await createTestDevice(pg.db, {
      userId: bob.id,
      deviceId: bobDeviceId,
      kind: "agent",
      platform: "linux",
      displayName: "Bob's Agent",
    });

    const token = await forgeToken(built, {
      uid: alice.id,
      deviceUuid: bobDeviceId,
      scope: "agent",
      email: "alice2@example.com",
    });

    expect((await probe(buildProbe(built), token)).status).toBe(401);
  });

  test("a token with no deviceUuid claim is refused", async () => {
    const built = buildTestApp(pg.db, pg.url);
    const { user, cookie } = await payingUser("carol@example.com");
    await provisionAndMint(built, cookie);

    const token = await forgeToken(built, { uid: user.id, scope: "agent" });
    expect((await probe(buildProbe(built), token)).status).toBe(401);
  });
});

describe("requireBearerJwt scope enforcement", () => {
  test("a token without the agent scope is refused, the same claims with it pass", async () => {
    const built = buildTestApp(pg.db, pg.url);
    const { user, cookie } = await payingUser("dave@example.com");
    const { deviceUuid } = await provisionAndMint(built, cookie);
    const r = buildProbe(built);

    const base = { uid: user.id, deviceUuid, email: "dave@example.com" };
    expect((await probe(r, await forgeToken(built, base))).status).toBe(401);
    expect((await probe(r, await forgeToken(built, { ...base, scope: "openid" }))).status).toBe(401);
    // Scope is the only variable, so the two 401s above cannot be blamed on the
    // signing path or on device resolution.
    expect((await probe(r, await forgeToken(built, { ...base, scope: "agent" }))).status).toBe(200);
  });

  test("a space-delimited scope list containing agent passes", async () => {
    const built = buildTestApp(pg.db, pg.url);
    const { user, cookie } = await payingUser("erin@example.com");
    const { deviceUuid } = await provisionAndMint(built, cookie);

    const token = await forgeToken(built, {
      uid: user.id,
      deviceUuid,
      scope: "openid agent",
    });
    expect((await probe(buildProbe(built), token)).status).toBe(200);
  });
});
