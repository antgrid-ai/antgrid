import { describe, test, expect, beforeAll, afterAll, beforeEach } from "bun:test";
import { startTestPg, type PgHandle } from "../helpers/pg.js";
import { buildTestApp } from "../helpers/app.js";
import { createTestUser, createTestSession } from "../helpers/fixtures.js";
import { ensureProductAccount } from "../../src/models/product-account.js";
import {
  ensureFreeSubscription,
  provisionProductAccountForUser,
} from "../../src/models/subscription.js";

let pg: PgHandle;
beforeAll(async () => { pg = await startTestPg(); });
afterAll(async () => { await pg.stop(); });
beforeEach(async () => { await pg.truncate(); });

describe("GET /account", () => {
  test("renders for a signed-in user and shows the delete control", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const user = await createTestUser(pg.db, "gita@example.com");
    const { cookie } = await createTestSession(pg.db, user.id);
    // GET /account re-provisions on every visit (provisionProductAccountForUser),
    // which upgrades a lingering free row back to the promotional grant — so
    // genuinely-free is not reachable here. A subscription pending
    // cancellation is the reachable "not blocked" state instead.
    const account = await provisionProductAccountForUser(pg.db, user.id);
    await pg.db.subscription.updateMany({
      where: { accountId: account.id, status: "active" },
      data: { cancelledAt: new Date(Date.now() + 24 * 3600 * 1000) },
    });

    const res = await app.request("/account", { headers: { cookie } });
    expect(res.status).toBe(200);
    const html = await res.text();
    expect(html).toContain("gita@example.com");
    expect(html).toContain("Delete account");
    // The confirm input MUST carry name="confirm" — the server now validates
    // body.confirm, so an unnamed input would silently break the legit path.
    expect(html).toContain('name="confirm"');
  });

  test("blocks deletion for an active promotional pro grant", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const user = await createTestUser(pg.db, "iris@example.com");
    const { cookie } = await createTestSession(pg.db, user.id);
    // No explicit subscription fixture — a fresh account defaults to the
    // promotional pro grant, which is treated like a real paid plan for
    // deletion purposes (accepted limitation during the promo).

    const res = await app.request("/account", { headers: { cookie } });
    expect(res.status).toBe(200);
    const html = await res.text();
    expect(html).toContain("You have an active subscription");
    expect(html).not.toContain('name="confirm"');
  });

  test("redirects to /login without a session", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const res = await app.request("/account", { redirect: "manual" });
    expect([302, 307]).toContain(res.status);
    expect(res.headers.get("location")).toBe("/login");
  });

  function deleteReq(
    app: ReturnType<typeof buildTestApp>["app"],
    cookie: string,
    confirm?: string,
  ) {
    const headers: Record<string, string> = { cookie };
    let body: string | undefined;
    if (confirm !== undefined) {
      headers["content-type"] = "application/x-www-form-urlencoded";
      body = new URLSearchParams({ confirm }).toString();
    }
    return app.request("/ui/account/delete", { method: "POST", headers, body, redirect: "manual" });
  }

  test("POST /ui/account/delete tombstones and redirects to /account/deleted", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const user = await createTestUser(pg.db, "hari@example.com");
    const { cookie } = await createTestSession(pg.db, user.id);
    const account = await ensureProductAccount(pg.db, user.id);
    await ensureFreeSubscription(pg.db, account.id);

    const res = await deleteReq(app, cookie, "DELETE");
    expect([302, 303]).toContain(res.status);
    expect(res.headers.get("location")).toBe("/account/deleted");

    const acct = await pg.db.productAccount.findUniqueOrThrow({ where: { userId: user.id } });
    expect(acct.deletedAt).not.toBeNull();
  });

  test("rejects deletion when the confirm word is missing or wrong", async () => {
    for (const confirm of [undefined, "", "delete", "DELETE ", "yes"]) {
      await pg.truncate();
      const { app } = buildTestApp(pg.db, pg.url);
      const user = await createTestUser(pg.db, "wrong@example.com");
      const { cookie } = await createTestSession(pg.db, user.id);
      const account = await ensureProductAccount(pg.db, user.id);
      await ensureFreeSubscription(pg.db, account.id);

      const res = await deleteReq(app, cookie, confirm);
      expect([302, 303]).toContain(res.status);
      expect(res.headers.get("location")).toBe("/account");

      // The account MUST survive — the guard ran before any mutation.
      const acct = await pg.db.productAccount.findUniqueOrThrow({ where: { userId: user.id } });
      expect(acct.deletedAt).toBeNull();
    }
  });
});
