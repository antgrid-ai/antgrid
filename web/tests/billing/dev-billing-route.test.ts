import { describe, test, expect, beforeAll, afterAll, beforeEach } from "bun:test";
import { startTestPg, type PgHandle } from "../helpers/pg.js";
import { buildTestApp } from "../helpers/app.js";
import { createTestUser } from "../helpers/fixtures.js";

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

type TestApp = ReturnType<typeof buildTestApp>["app"];

function post(app: TestApp, body: unknown) {
  return app.request("/dev/billing/subscription", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  });
}

describe("POST /dev/billing/subscription", () => {
  test("when enabled, grants a subscription for the given email", async () => {
    const { app } = buildTestApp(pg.db, pg.url, {
      envOverrides: { DEV_BILLING_ENABLED: true } as never,
    });
    const user = await createTestUser(pg.db);

    const res = await post(app, { email: user.email, planSlug: "pro_yearly" });
    expect(res.status).toBe(200);
    const json = (await res.json()) as { ok: boolean; subscription: { tier: string; provider: string } };
    expect(json.ok).toBe(true);
    expect(json.subscription.provider).toBe("dev");
    expect(json.subscription.tier).not.toBe("free");
  });

  test("unknown email returns 404 USER_NOT_FOUND", async () => {
    const { app } = buildTestApp(pg.db, pg.url, {
      envOverrides: { DEV_BILLING_ENABLED: true } as never,
    });
    const res = await post(app, { email: "nobody@test.local" });
    expect(res.status).toBe(404);
    expect((await res.json()) as { error: string; email: string }).toEqual({
      error: "USER_NOT_FOUND",
      email: "nobody@test.local",
    });
  });

  test("invalid body returns 400", async () => {
    const { app } = buildTestApp(pg.db, pg.url, {
      envOverrides: { DEV_BILLING_ENABLED: true } as never,
    });
    const res = await post(app, { email: "not-an-email" });
    expect(res.status).toBe(400);
  });

  test("route is absent when the flag is unset (default)", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const user = await createTestUser(pg.db);
    const res = await post(app, { email: user.email });
    expect(res.status).toBe(404);
    // Hono's default 404 (route unmounted) is plain text, not our handler's JSON.
    expect(await res.text()).not.toContain("USER_NOT_FOUND");
  });

  test("route is absent in production even if the flag is set", async () => {
    const { app } = buildTestApp(pg.db, pg.url, {
      envOverrides: { NODE_ENV: "production", DEV_BILLING_ENABLED: true } as never,
    });
    const user = await createTestUser(pg.db);
    const res = await post(app, { email: user.email });
    expect(res.status).toBe(404);
  });
});
