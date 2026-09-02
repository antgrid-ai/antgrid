import { describe, test, expect, beforeAll, afterAll, beforeEach } from "bun:test";
import { startTestPg, type PgHandle } from "../helpers/pg.js";
import { buildTestApp } from "../helpers/app.js";
import { parseTrustedProxies } from "antgrid-wire";

let pg: PgHandle;
beforeAll(async () => { pg = await startTestPg(); });
afterAll(async () => { await pg.stop(); });
beforeEach(async () => { await pg.truncate(); });

// The limiter is module-scoped, so every buildTestApp in this file shares its
// buckets. Give each test its own key by resolving through a trusted proxy and
// varying the client hop — otherwise the second test inherits a drained bucket.
const TRUSTED = { TRUSTED_PROXY_IPS: parseTrustedProxies("172.28.0.0/16") };
const PROXY_PEER = { requestIP: () => ({ address: "172.28.0.9" }) };

type TestApp = ReturnType<typeof buildTestApp>["app"];

function post(app: TestApp, clientIp: string, body: unknown) {
  return app.request(
    "/api/waitlist",
    {
      method: "POST",
      headers: { "content-type": "application/json", "x-forwarded-for": clientIp },
      body: JSON.stringify(body),
    },
    PROXY_PEER,
  );
}

describe("POST /api/waitlist", () => {
  test("records a signup, no auth required", async () => {
    const { app } = buildTestApp(pg.db, pg.url, { envOverrides: TRUSTED });
    const res = await post(app, "203.0.113.1", { email: "founder@example.com", source: "pricing" });

    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ ok: true });

    const rows = await pg.db.waitlistSignup.findMany();
    expect(rows).toHaveLength(1);
    expect(rows[0].email).toBe("founder@example.com");
    expect(rows[0].source).toBe("pricing");
  });

  test("normalises the address so casing cannot split the unique index", async () => {
    const { app } = buildTestApp(pg.db, pg.url, { envOverrides: TRUSTED });
    const res = await post(app, "203.0.113.2", { email: "  Mixed.Case@Example.COM", source: "hero" });

    expect(res.status).toBe(200);
    const rows = await pg.db.waitlistSignup.findMany();
    expect(rows).toHaveLength(1);
    expect(rows[0].email).toBe("mixed.case@example.com");
  });

  test("rejects a malformed email with 400 and writes nothing", async () => {
    const { app } = buildTestApp(pg.db, pg.url, { envOverrides: TRUSTED });
    const res = await post(app, "203.0.113.3", { email: "not-an-email", source: "security" });

    expect(res.status).toBe(400);
    const body = (await res.json()) as { ok: boolean; error: string };
    expect(body.ok).toBe(false);
    expect(body.error).toBe("BAD_REQUEST");
    expect(await pg.db.waitlistSignup.count()).toBe(0);
  });

  test("rejects a body missing source", async () => {
    const { app } = buildTestApp(pg.db, pg.url, { envOverrides: TRUSTED });
    const res = await post(app, "203.0.113.4", { email: "someone@example.com" });

    expect(res.status).toBe(400);
    expect(await pg.db.waitlistSignup.count()).toBe(0);
  });

  test("a duplicate email answers 200 and is indistinguishable from a first signup", async () => {
    const { app } = buildTestApp(pg.db, pg.url, { envOverrides: TRUSTED });
    const first = await post(app, "203.0.113.5", { email: "twice@example.com", source: "hero" });
    const second = await post(app, "203.0.113.5", { email: "twice@example.com", source: "pricing" });

    expect(first.status).toBe(200);
    expect(second.status).toBe(200);
    // Byte-identical bodies: the response must not leak list membership.
    expect(await second.json()).toEqual(await first.json());

    const rows = await pg.db.waitlistSignup.findMany();
    expect(rows).toHaveLength(1);
    // The original capture surface wins — a repeat submit is a no-op, not an update.
    expect(rows[0].source).toBe("hero");
  });

  test("does not store the client IP anywhere on the row", async () => {
    const { app } = buildTestApp(pg.db, pg.url, { envOverrides: TRUSTED });
    await post(app, "203.0.113.6", { email: "private@example.com", source: "pricing" });

    const row = (await pg.db.waitlistSignup.findFirst())!;
    expect(JSON.stringify(row)).not.toContain("203.0.113.6");
  });

  test("rate-limits a single client, leaving other clients unaffected", async () => {
    const { app } = buildTestApp(pg.db, pg.url, { envOverrides: TRUSTED });
    let limited = false;
    for (let i = 0; i < 12 && !limited; i++) {
      const res = await post(app, "203.0.113.7", { email: `burst${i}@example.com`, source: "hero" });
      limited = res.status === 429;
    }
    expect(limited).toBe(true);

    const other = await post(app, "203.0.113.8", { email: "calm@example.com", source: "hero" });
    expect(other.status).toBe(200);
  });

  test("answers the marketing origin's preflight with CORS headers", async () => {
    const { app } = buildTestApp(pg.db, pg.url, {
      envOverrides: { ...TRUSTED, CORS_ORIGINS: ["https://antgrid.ai"] },
    });
    const res = await app.request("/api/waitlist", {
      method: "OPTIONS",
      headers: {
        origin: "https://antgrid.ai",
        "access-control-request-method": "POST",
        "access-control-request-headers": "content-type",
      },
    });

    expect(res.headers.get("access-control-allow-origin")).toBe("https://antgrid.ai");
    expect(res.headers.get("access-control-allow-methods")).toContain("POST");
  });
});
