import { afterAll, beforeAll, beforeEach, describe, expect, test } from "bun:test";
import { startTestPg, type PgHandle } from "../helpers/pg.js";
import { buildTestApp } from "../helpers/app.js";
import { createTestSession, createTestUser } from "../helpers/fixtures.js";

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

describe("POST /logout", () => {
  test("clears the session cookie, deletes the session, redirects to root", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const user = await createTestUser(pg.db, "alice@example.com");
    const { sessionId, cookie } = await createTestSession(pg.db, user.id);

    const res = await app.fetch(
      new Request("http://localhost/logout", {
        method: "POST",
        headers: { cookie },
        redirect: "manual",
      })
    );

    // Redirects back to the app root (which itself bounces to /login when
    // signed out) — never dumps Better-Auth's JSON to the browser.
    expect(res.status).toBe(302);
    expect(res.headers.get("location")).toBe("/");

    // The session cookie is cleared (expired) on the redirect response.
    const setCookie = res.headers.get("set-cookie") ?? "";
    expect(setCookie).toContain("better-auth.session_token=");
    expect(setCookie.toLowerCase()).toMatch(/max-age=0|expires=/);

    // Server-side session row is gone.
    const row = await pg.db.session.findUnique({ where: { id: sessionId } });
    expect(row).toBeNull();
  });

  test("is a no-op redirect when there is no session", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const res = await app.fetch(
      new Request("http://localhost/logout", {
        method: "POST",
        redirect: "manual",
      })
    );
    expect(res.status).toBe(302);
    expect(res.headers.get("location")).toBe("/");
  });
});
