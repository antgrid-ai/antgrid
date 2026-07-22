import { describe, test, expect, beforeAll, afterAll, beforeEach } from "bun:test";
import { startTestPg, type PgHandle } from "../helpers/pg.js";
import { buildTestApp } from "../helpers/app.js";
import { safeCallbackURL } from "../../src/routes/oauth-start.js";

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

describe("/oauth/start", () => {
  test("github: 302s to the provider authorize URL and forwards Set-Cookie state", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const res = await app.request(
      "/oauth/start?provider=github&callbackURL=/dashboard"
    );
    expect(res.status).toBe(302);
    const loc = res.headers.get("location") ?? "";
    expect(loc.startsWith("https://github.com/login/oauth/authorize")).toBe(true);
    expect(loc.includes("client_id=gh")).toBe(true);
    // OAuth state / PKCE cookie must be forwarded, or callback validation fails.
    expect(res.headers.get("set-cookie")).toBeTruthy();
    expect(res.headers.get("cache-control")).toBe("no-store");
  });

  test("google: 302s to the Google authorize URL", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const res = await app.request(
      "/oauth/start?provider=google&callbackURL=/dashboard"
    );
    expect(res.status).toBe(302);
    const loc = res.headers.get("location") ?? "";
    expect(loc.includes("accounts.google.com")).toBe(true);
    expect(loc.includes("client_id=gl")).toBe(true);
  });

  test("defaults callbackURL to /dashboard when omitted", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const res = await app.request("/oauth/start?provider=github");
    expect(res.status).toBe(302);
    expect((res.headers.get("location") ?? "").includes("github.com")).toBe(true);
  });

  test("unknown provider → 400", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const res = await app.request("/oauth/start?provider=facebook");
    expect(res.status).toBe(400);
  });

  test("missing provider → 400", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const res = await app.request("/oauth/start");
    expect(res.status).toBe(400);
  });
});

describe("safeCallbackURL (open-redirect guard)", () => {
  test("passes same-origin relative paths through unchanged", () => {
    expect(safeCallbackURL("/dashboard")).toBe("/dashboard");
    expect(safeCallbackURL("/account/devices?tab=keys")).toBe("/account/devices?tab=keys");
    expect(safeCallbackURL("/")).toBe("/");
  });

  test("rejects absolute external URLs → /dashboard", () => {
    expect(safeCallbackURL("https://evil.com/harvest")).toBe("/dashboard");
    expect(safeCallbackURL("http://evil.com")).toBe("/dashboard");
    expect(safeCallbackURL("javascript:alert(1)")).toBe("/dashboard");
  });

  test("rejects protocol-relative and backslash tricks → /dashboard", () => {
    expect(safeCallbackURL("//evil.com")).toBe("/dashboard");
    expect(safeCallbackURL("/\\evil.com")).toBe("/dashboard");
    // A single leading slash to a path that merely contains a dot is still a
    // legitimate same-origin path — only "//" and "/\" are blocked.
    expect(safeCallbackURL("/evil.com")).toBe("/evil.com");
  });

  test("rejects non-path values and falls back → /dashboard", () => {
    expect(safeCallbackURL(undefined)).toBe("/dashboard");
    expect(safeCallbackURL("")).toBe("/dashboard");
    expect(safeCallbackURL("dashboard")).toBe("/dashboard"); // no leading slash
  });
});
