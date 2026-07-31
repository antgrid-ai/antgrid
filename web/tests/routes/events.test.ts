import { describe, test, expect, beforeAll, afterAll, beforeEach } from "bun:test";
import { startTestPg, type PgHandle } from "../helpers/pg.js";
import { buildTestApp } from "../helpers/app.js";

let pg: PgHandle;
beforeAll(async () => { pg = await startTestPg(); });
afterAll(async () => { await pg.stop(); });
beforeEach(async () => { await pg.truncate(); });

const validEvent = {
  installId: "11111111-1111-4111-8111-111111111111",
  name: "session_opened",
  ts: new Date().toISOString(),
  platform: "android",
  appVersion: "1.0.0",
  props: { surface: "mobile" },
};

describe("POST /events", () => {
  test("persists a valid batch, no auth required", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const res = await app.request("/events", {
      method: "POST",
      headers: { "content-type": "application/json", "x-forwarded-for": "203.0.113.1" },
      body: JSON.stringify({ events: [validEvent] }),
    });
    expect(res.status).toBe(202);
    const rows = await pg.db.analyticEvent.findMany();
    expect(rows).toHaveLength(1);
    expect(rows[0].name).toBe("session_opened");
    expect(rows[0].installId).toBe("11111111-1111-4111-8111-111111111111");
  });

  test("rejects an unknown event name", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const res = await app.request("/events", {
      method: "POST",
      headers: { "content-type": "application/json", "x-forwarded-for": "203.0.113.2" },
      body: JSON.stringify({ events: [{ ...validEvent, name: "not_a_real_event" }] }),
    });
    expect(res.status).toBe(400);
    expect(await pg.db.analyticEvent.count()).toBe(0);
  });

  test("rejects an oversized batch", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const events = Array.from({ length: 51 }, () => validEvent);
    const res = await app.request("/events", {
      method: "POST",
      headers: { "content-type": "application/json", "x-forwarded-for": "203.0.113.3" },
      body: JSON.stringify({ events }),
    });
    expect(res.status).toBe(400);
  });

  test("accepts a macos platform event and persists it", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const res = await app.request("/events", {
      method: "POST",
      headers: { "content-type": "application/json", "x-forwarded-for": "203.0.113.5" },
      body: JSON.stringify({ events: [{ ...validEvent, platform: "macos" }] }),
    });
    expect(res.status).toBe(202);
    const rows = await pg.db.analyticEvent.findMany();
    expect(rows).toHaveLength(1);
    expect(rows[0].platform).toBe("macos");
  });

  test("accepts the 'unknown' platform fallback (fringe TargetPlatform)", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const res = await app.request("/events", {
      method: "POST",
      headers: { "content-type": "application/json", "x-forwarded-for": "203.0.113.6" },
      body: JSON.stringify({ events: [{ ...validEvent, platform: "unknown" }] }),
    });
    expect(res.status).toBe(202);
    const rows = await pg.db.analyticEvent.findMany();
    expect(rows[0].platform).toBe("unknown");
  });

  test("no peer address (and whatever XFF) still ingests via the 'unknown' bucket", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    // Without a socket peer the resolver yields null — the request must fall
    // through to the shared "unknown" bucket, never trust the header.
    const res = await app.request("/events", {
      method: "POST",
      headers: { "content-type": "application/json", "x-forwarded-for": "" },
      body: JSON.stringify({ events: [validEvent] }),
    });
    expect(res.status).toBe(202);
  });

  test("forged leftmost XFF hops cannot mint fresh rate-limit buckets", async () => {
    const { app } = buildTestApp(pg.db, pg.url, {
      envOverrides: { TRUSTED_PROXY_IPS: ["172.28.0.0/16"] },
    });
    // Fake Bun server env (what Bun.serve passes in production): the peer is
    // a trusted proxy, so resolution walks XFF right-to-left.
    const proxyPeer = { requestIP: () => ({ address: "172.28.0.9" }) };
    const post = (xff: string) =>
      app.request(
        "/events",
        {
          method: "POST",
          headers: { "content-type": "application/json", "x-forwarded-for": xff },
          body: JSON.stringify({ events: [validEvent] }),
        },
        proxyPeer,
      );

    // One real client (rightmost, proxy-appended) cycling forged leftmost
    // entries: every request lands in the SAME bucket, so the burst (60)
    // exhausts. 70 requests absorbs the 1/sec refill without flaking.
    let limited = false;
    for (let i = 0; i < 70 && !limited; i++) {
      const res = await post(`10.0.0.${i}, 203.0.113.99`);
      limited = res.status === 429;
    }
    expect(limited).toBe(true);

    // A different REAL client (different rightmost hop) has its own bucket
    // and is unaffected by the exhausted one.
    const other = await post("203.0.113.100");
    expect(other.status).toBe(202);
  });

  test("does not store the client IP anywhere on the row", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    await app.request("/events", {
      method: "POST",
      headers: { "content-type": "application/json", "x-forwarded-for": "203.0.113.4" },
      body: JSON.stringify({ events: [validEvent] }),
    });
    const row = (await pg.db.analyticEvent.findFirst())!;
    expect(JSON.stringify(row)).not.toContain("203.0.113.4");
  });
});
