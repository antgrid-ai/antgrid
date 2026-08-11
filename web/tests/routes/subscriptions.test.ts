import { describe, test, expect, beforeAll, afterAll, beforeEach } from "bun:test";
import { startTestPg, type PgHandle } from "../helpers/pg.js";
import { buildTestApp } from "../helpers/app.js";
import { createTestUser, createTestSubscription, createTestSession } from "../helpers/fixtures.js";
import { PLAN_UUID } from "../../src/models/plan.js";

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

describe("GET /subscriptions/me", () => {
  test("returns the active subscription shape", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const user = await createTestUser(pg.db);
    await createTestSubscription(pg.db, user.id, { tier: "pro", workerLimit: 3 });
    const { cookie } = await createTestSession(pg.db, user.id);
    const res = await app.request("/subscriptions/me", { headers: { cookie } });
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.subscription.tier).toBe("pro");
    expect(body.subscription.worker_limit).toBe(3);
    // Compatibility mirror for app builds already in the field.
    expect(body.subscription.session_limit).toBe(3);
    expect(body.subscription.plan_id).toBe(PLAN_UUID.pro_yearly);
    expect(body.active_devices).toBe(0);
  });

  test("returns promotional pro subscription when user has no paid plan", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const user = await createTestUser(pg.db);
    const { cookie } = await createTestSession(pg.db, user.id);
    const res = await app.request("/subscriptions/me", { headers: { cookie } });
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.subscription).toMatchObject({
      tier: "pro",
      worker_limit: 3,
      session_limit: 3,
      plan_id: PLAN_UUID.pro_yearly,
      promotional: true,
      cancelled_at: null,
    });
    expect(body.tier).toBe("pro");
    expect(body.worker_limit).toBe(3);
    expect(body.session_limit).toBe(3);
    expect(body.promotional).toBe(true);
    expect(body.active_devices).toBe(0);
  });

  test("requires auth", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const res = await app.request("/subscriptions/me");
    expect(res.status).toBe(401);
  });
});
