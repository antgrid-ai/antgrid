import { describe, test, expect, beforeAll, afterAll, beforeEach } from "bun:test";
import { startTestPg, type PgHandle } from "../helpers/pg.js";
import { buildTestApp } from "../helpers/app.js";
import { createTestUser, createTestSession, createTestSubscription } from "../helpers/fixtures.js";

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

describe("DELETE /account/devices/:id", () => {
  test("removes both the OAuth client and the device row; subsequent mint fails", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const user = await createTestUser(pg.db, "alice@example.com");
    const { cookie } = await createTestSession(pg.db, user.id);
    await createTestSubscription(pg.db, user.id, { tier: "pro" });

    // Create a device with an OAuth client via POST /account/devices
    const deviceUuid = crypto.randomUUID();
    const createRes = await app.request("/account/devices", {
      method: "POST",
      headers: { cookie, "content-type": "application/json" },
      body: JSON.stringify({
        deviceUuid,
        ed25519Pub: Buffer.alloc(32, 1).toString("base64"),
        x25519Pub: Buffer.alloc(32, 2).toString("base64"),
        platform: "macos",
        displayName: "Alice's Mac",
      }),
    });
    expect(createRes.status).toBe(201);
    const created = (await createRes.json()) as {
      deviceUuid: string;
      clientId: string;
      clientSecret: string;
    };
    expect(created.clientId).toBeTruthy();
    expect(created.clientSecret).toBeTruthy();

    const dev = await pg.db.device.findFirstOrThrow({ where: { deviceId: created.deviceUuid } });

    // DELETE the device
    const res = await app.request(`/account/devices/${dev.id}`, {
      method: "DELETE",
      headers: { cookie },
    });
    expect(res.status).toBe(200);

    // Device row should have revokedAt set
    const after = await pg.db.device.findUniqueOrThrow({ where: { id: dev.id } });
    expect(after.revokedAt).not.toBeNull();

    // Minting a token with the OAuth client should now fail (client deleted)
    const mint = await app.request("/api/auth/oauth2/token", {
      method: "POST",
      headers: {
        "content-type": "application/x-www-form-urlencoded",
        authorization:
          "Basic " +
          Buffer.from(`${created.clientId}:${created.clientSecret}`).toString("base64"),
      },
      body: "grant_type=client_credentials&scope=agent",
    });
    expect([400, 401]).toContain(mint.status);
  });

  test("404 for unknown id", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const user = await createTestUser(pg.db, "bob@example.com");
    const { cookie } = await createTestSession(pg.db, user.id);
    const res = await app.request(`/account/devices/${crypto.randomUUID()}`, {
      method: "DELETE",
      headers: { cookie },
    });
    expect(res.status).toBe(404);
  });
});
