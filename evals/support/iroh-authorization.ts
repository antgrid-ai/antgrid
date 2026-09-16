/// <reference path="../../web/src/ui/svg.d.ts" />
import { generateKeyPairSync, sign, type KeyObject } from "node:crypto";
import { EndpointChallengeSchema, PeerAuthorizationSnapshotSchema, endpointChallengeBytes } from "antgrid-wire";
import { startTestPg, type PgHandle } from "../../web/tests/helpers/pg";
import { buildTestApp } from "../../web/tests/helpers/app";
import { createTestSession, createTestSubscription, createTestUser } from "../../web/tests/helpers/fixtures";
import { loadEnv } from "../../web/src/env";
import type { Env } from "../../web/src/env";

export type EnrollmentDevice = {
  deviceId: string;
  token: string;
  clientId: string;
  clientSecret: string;
  privateKey: KeyObject;
  publicKey: string;
};

export function endpointKey() {
  const pair = generateKeyPairSync("ed25519");
  return { privateKey: pair.privateKey,
    endpointId: pair.publicKey.export({ type: "spki", format: "der" }).subarray(-32).toString("hex") };
}

/** Real HTTP/OAuth/Prisma authorization; only the signed-in user is a test fixture. */
export async function startIrohAuthorizationHarness(envOverrides: Partial<Env> = {}) {
  const previousPg = process.env.PG_DATABASE_URL;
  process.env.PG_DATABASE_URL ??= loadEnv().PG_DATABASE_URL;
  let pg: PgHandle | undefined;
  let server: ReturnType<typeof Bun.serve> | undefined;
  try {
    pg = await startTestPg();
    const database = pg;
    let handle: ((request: Request) => Response | Promise<Response>) | undefined;
    server = Bun.serve({ hostname: "127.0.0.1", port: 0,
      fetch: (request) => handle ? handle(request) : new Response(null, { status: 503 }) });
    const origin = server.url.origin;
    const { app } = buildTestApp(pg.db, pg.url, { envOverrides: {
      BETTER_AUTH_URL: origin, IROH_RELAY_URLS: ["https://iroh.staging.example/"], PEER_POLICY_TARGETS: [],
      ...envOverrides,
    } });
    handle = (request) => app.fetch(request);

    async function request(path: string, options: { token?: string; cookie?: string; method?: string; body?: unknown } = {}) {
      return fetch(`${origin}${path}`, { method: options.method ?? (options.body ? "POST" : "GET"),
        headers: { ...(options.token ? { authorization: `Bearer ${options.token}` } : {}),
          ...(options.cookie ? { cookie: options.cookie } : {}), "content-type": "application/json" },
        body: options.body === undefined ? undefined : JSON.stringify(options.body), signal: AbortSignal.timeout(10_000) });
    }
    async function user() {
      const user = await createTestUser(database.db);
      await createTestSubscription(database.db, user.id, { tier: "pro" });
      return { userId: user.id, ...(await createTestSession(database.db, user.id)) };
    }
    async function provision(cookie: string, kind: "app" | "agent"): Promise<EnrollmentDevice> {
      const pair = generateKeyPairSync("ed25519");
      const publicKey = pair.publicKey.export({ type: "spki", format: "der" }).subarray(-32).toString("base64");
      const deviceId = crypto.randomUUID();
      const created = await request("/account/devices", { cookie, body: { deviceUuid: deviceId,
        ed25519Pub: publicKey, x25519Pub: Buffer.alloc(32, 1).toString("base64"),
        platform: "linux", displayName: `Iroh qualification ${kind}`, kind } });
      if (created.status !== 201) throw new Error(`Device enrollment HTTP ${created.status}`);
      const credentials = await created.json() as { clientId: string; clientSecret: string };
      const minted = await fetch(`${origin}/api/auth/oauth2/token`, { method: "POST",
        headers: { "content-type": "application/x-www-form-urlencoded", authorization:
          `Basic ${Buffer.from(`${credentials.clientId}:${credentials.clientSecret}`).toString("base64")}` },
        body: new URLSearchParams({ grant_type: "client_credentials", scope: "agent", resource: `${origin}/api/auth` }),
        signal: AbortSignal.timeout(10_000) });
      if (minted.status !== 200) throw new Error(`Device token HTTP ${minted.status}`);
      const token = await minted.json() as { access_token: string };
      return { deviceId, clientId: credentials.clientId, clientSecret: credentials.clientSecret,
        token: token.access_token, privateKey: pair.privateKey, publicKey };
    }
    async function challenge(device: EnrollmentDevice, endpoint = endpointKey(), expectedGeneration = "0") {
      const response = await request("/account/devices/me/endpoint-challenge", { token: device.token,
        body: { endpointId: endpoint.endpointId, expectedGeneration } });
      if (!response.ok) throw new Error(`Endpoint challenge HTTP ${response.status}`);
      const challenge = EndpointChallengeSchema.parse(await response.json());
      const bytes = endpointChallengeBytes(challenge);
      return { endpoint, challenge, body: { challengeId: challenge.challengeId,
        deviceSignature: sign(null, bytes, device.privateKey).toString("base64"),
        endpointSignature: sign(null, bytes, endpoint.privateKey).toString("base64") } };
    }
    async function snapshot(device: EnrollmentDevice) {
      const response = await request("/account/devices/me/authorization", { token: device.token });
      if (!response.ok) throw new Error(`Authorization snapshot HTTP ${response.status}`);
      return PeerAuthorizationSnapshotSchema.parse(await response.json());
    }
    return { origin, db: pg.db, user, provision, request, challenge, snapshot, async stop() {
      server!.stop(true);
      await database.stop();
      if (previousPg === undefined) delete process.env.PG_DATABASE_URL;
      else process.env.PG_DATABASE_URL = previousPg;
    } };
  } catch (error) {
    server?.stop(true);
    await pg?.stop();
    if (previousPg === undefined) delete process.env.PG_DATABASE_URL;
    else process.env.PG_DATABASE_URL = previousPg;
    throw error;
  }
}
