import { describe, test, expect, beforeAll, afterAll } from "bun:test";
import { startTestPg, type PgHandle } from "./helpers/pg.js";
import { buildTestApp } from "./helpers/app.js";

let pg: PgHandle;
beforeAll(async () => { pg = await startTestPg(); });
afterAll(async () => { await pg.stop(); });

describe("GET /health", () => {
  test("returns ok", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const res = await app.request("/health");
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ ok: true, service: "web" });
  });
});
