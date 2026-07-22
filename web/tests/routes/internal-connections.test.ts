import { test, expect, beforeAll, afterAll, beforeEach } from "bun:test";
import { startTestPg, type PgHandle } from "../helpers/pg.js";
import { buildTestApp } from "../helpers/app.js";
import { createTestUser, createTestSession } from "../helpers/fixtures.js";

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

const OPERATOR = "bharathm@radhaai.com";

test("operator email → 200 renders the connections page", async () => {
  const { app } = buildTestApp(pg.db, pg.url);
  const user = await createTestUser(pg.db, OPERATOR);
  const { cookie } = await createTestSession(pg.db, user.id);

  const res = await app.request("/internal/connections", { headers: { cookie } });
  expect(res.status).toBe(200);
  expect(await res.text()).toContain("Relay connections");
});

test("operator email is matched case-insensitively", async () => {
  const { app } = buildTestApp(pg.db, pg.url);
  const user = await createTestUser(pg.db, "BharathM@Radhaai.com");
  const { cookie } = await createTestSession(pg.db, user.id);

  const res = await app.request("/internal/connections", { headers: { cookie } });
  expect(res.status).toBe(200);
});

test("signed-in non-operator → 404 (route existence not revealed)", async () => {
  const { app } = buildTestApp(pg.db, pg.url);
  const user = await createTestUser(pg.db, "someone-else@test.local");
  const { cookie } = await createTestSession(pg.db, user.id);

  const res = await app.request("/internal/connections", { headers: { cookie } });
  expect(res.status).toBe(404);
});

test("unauthenticated → redirect to /login", async () => {
  const { app } = buildTestApp(pg.db, pg.url);
  const res = await app.request("/internal/connections");
  expect(res.status).toBe(302);
  expect(res.headers.get("location")).toBe("/login");
});
