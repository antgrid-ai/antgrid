import { beforeAll, describe, expect, test } from "bun:test";
import { Hono } from "hono";
import { exportJWK, generateKeyPair, SignJWT } from "jose";
import { requireDeviceBearerJwt } from "../../src/auth/jwt-bearer";
import type { Auth } from "../../src/auth/better-auth";
import type { AuthVars } from "../../src/auth/middleware";
import type { DB } from "../../src/db";
import type { Env } from "../../src/env";

const issuer = "https://account.example/api/auth";
const deviceId = "00000000-0000-4000-8000-000000000001";
const publicKey = Buffer.alloc(32, 7);
let keys: Awaited<ReturnType<typeof generateKeyPair>>;
let auth: Auth;
beforeAll(async () => {
  keys = await generateKeyPair("EdDSA");
  const jwk = await exportJWK(keys.publicKey);
  auth = { handler: async () => Response.json({ keys: [{ ...jwk, kid: "test", alg: "EdDSA" }] }) } as unknown as Auth;
});

async function request(options: {
  claims?: Record<string, unknown>; device?: Record<string, unknown>;
  credential?: Record<string, unknown>; missingCredential?: boolean; audience?: string;
} = {}) {
  const device = {
    id: "row", userId: "owner", deviceId, oauthClientId: "credential",
    revokedAt: null, publicKey, kind: "app", ...options.device,
  };
  const credential = {
    clientId: "credential", disabled: false, grantTypes: ["client_credentials"],
    metadata: { userId: "owner", deviceUuid: deviceId, ed25519Pub: publicKey.toString("base64") },
    ...options.credential,
  };
  const db = {
    device: { findUnique: async ({ where }: { where: { oauthClientId: string } }) =>
      where.oauthClientId === device.oauthClientId ? device : null },
    oauthClient: { findUnique: async () => options.missingCredential ? null : credential },
  } as unknown as DB;
  const app = new Hono<{ Variables: AuthVars }>();
  app.use("*", requireDeviceBearerJwt({ auth, db,
    env: { BETTER_AUTH_URL: "https://account.example", EXTRA_TOKEN_AUDIENCES: [] } as unknown as Env }));
  app.get("/", (c) => c.json(c.get("deviceAuthorization")));
  const token = await new SignJWT({ uid: "owner", deviceUuid: deviceId,
    azp: "credential", pk: publicKey.toString("base64"), ...options.claims })
    .setProtectedHeader({ alg: "EdDSA", kid: "test" }).setIssuer(issuer)
    .setAudience(options.audience ?? issuer).setIssuedAt().setExpirationTime("1m")
    .sign(keys.privateKey);
  return app.request("/", { headers: { authorization: `Bearer ${token}` } });
}

describe("device-bound bearer authentication", () => {
  test("resolves only the active device selected by azp", async () => {
    const response = await request();
    expect(response.status).toBe(200);
    expect((await response.json()).enrollmentId).toBe("credential");
  });
  test("account membership cannot select a sibling enrollment", async () => {
    expect((await request({ claims: { deviceUuid: "00000000-0000-4000-8000-000000000002" } })).status).toBe(401);
    expect((await request({ claims: { azp: "sibling" } })).status).toBe(401);
    expect((await request({ claims: { uid: "other-owner" } })).status).toBe(401);
  });
  test("rejects revoked, disabled and deleted credentials and stale keys", async () => {
    expect((await request({ device: { revokedAt: new Date() } })).status).toBe(401);
    expect((await request({ credential: { disabled: true } })).status).toBe(401);
    expect((await request({ missingCredential: true })).status).toBe(401);
    expect((await request({ device: { publicKey: Buffer.alloc(32, 8) } })).status).toBe(401);
  });
  test("cross-checks metadata and audience", async () => {
    expect((await request({ credential: { metadata: { userId: "other" } } })).status).toBe(401);
    expect((await request({ audience: "https://unrelated.example" })).status).toBe(401);
    expect((await request({ claims: { azp: undefined } })).status).toBe(401);
  });
  test("validates Better-Auth's serialized metadata without trusting malformed strings", async () => {
    expect((await request({ credential: { metadata: JSON.stringify({ userId: "owner", deviceUuid: deviceId,
      ed25519Pub: publicKey.toString("base64") }) } })).status).toBe(200);
    expect((await request({ credential: { metadata: "not-json" } })).status).toBe(401);
    expect((await request({ credential: { metadata: JSON.stringify({ userId: "other", deviceUuid: deviceId,
      ed25519Pub: publicKey.toString("base64") }) } })).status).toBe(401);
  });
});
