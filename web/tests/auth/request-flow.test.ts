// SPDX-FileCopyrightText: 2026 Radha AI Products
// SPDX-License-Identifier: LicenseRef-Elastic-2.0

import { beforeAll, afterAll, beforeEach, test, expect } from "bun:test";
import { startTestPg, type PgHandle } from "../helpers/pg.js";
import { buildTestApp } from "../helpers/app.js";
import { createTestUser } from "../helpers/fixtures.js";
import { createDb } from "../../src/db/index.js";
import { createRequestFlow } from "../../src/auth/request-flow.js";

let pg: PgHandle;
beforeAll(async () => { pg = await startTestPg(); });
afterAll(async () => { await pg.stop(); });
beforeEach(async () => { await pg.truncate(); });

test("resends preserve the current journey and correcting the email starts a new journey", async () => {
  const jar = new Map<string, string>();
  const start = (email: string, method = "reset") => createRequestFlow(pg.db, "test-secret", email, method,
    new Headers({ cookie: [...jar].map(([k,v]) => k+"="+v).join("; ") }),
    (name) => jar.get(name), (name,value,age) => { if (age) jar.set(name,value); else jar.delete(name); });
  const first = await start("first@example.com");
  const resend = await start("first@example.com", "verification");
  expect(resend.id).not.toBe(first.id);
  expect(resend.journeyId).toBe(first.journeyId);
  const corrected = await start("corrected@example.com");
  expect(corrected.journeyId).not.toBe(first.journeyId);
  const changedBack = await start("first@example.com");
  expect(changedBack.journeyId).not.toBe(first.journeyId);
  await pg.db.authFlowEvent.create({ data: { flowId: changedBack.id, stage: "first_client_use" } });
  expect((await start("first@example.com")).journeyId).not.toBe(changedBack.journeyId);
});

test("known and unknown reset requests persist uniform public receipts", async () => {
  const delivered: unknown[] = [];
  const { app } = buildTestApp(pg.db, pg.url, { sendEmail: async (mail) => { delivered.push(mail); } });
  const user = await createTestUser(pg.db, "known@example.com");
  const request = (email: string) => app.request("/api/auth/request-password-reset", {
    method: "POST", headers: { "content-type": "application/json", origin: "http://localhost:8787" }, body: JSON.stringify({ email }),
  });
  const known = await request(user.email);
  const unknown = await request("unknown@example.com");
  expect(known.status).toBe(200);
  expect(unknown.status).toBe(200);
  const knownBody = await known.json();
  const unknownBody = await unknown.json();
  for (const body of [knownBody,unknownBody]) {
    expect(body.flow.status).toBe("pending");
    expect(body.flow.delivery).toBe("accepted");
    expect(await pg.db.authFlow.count({ where: { id: body.flow.id } })).toBe(1);
  }
  const shape = ({ flow, ...rest }: any) => ({ ...rest, flow: { status: flow.status, delivery: flow.delivery } });
  expect(shape(knownBody)).toEqual(shape(unknownBody));
  expect(delivered).toHaveLength(1);
  const historical = await pg.db.user.findUniqueOrThrow({ where: { id: user.id } });
  expect(historical.registrationOrigin).toBeNull();
  expect(historical.activationOrigin).toBeNull();
});


test("production pooled connections preserve UTC authentication deadlines", async () => {
  const db = createDb(pg.url);
  try {
    const timezone = await db.$queryRaw<{ TimeZone: string }[]>`SHOW TimeZone`;
    expect(timezone[0].TimeZone).toBe("UTC");
    const journey = await db.authJourney.create({ data: { origin: { surface: "unknown", platform: "unknown", method: "reset", quality: "unknown", version: null } } });
    const flow = await db.authFlow.create({ data: { journeyId: journey.id, expiresAt: new Date(Date.now()+600000) } });
    const rows = await db.$queryRaw<{ remaining: number }[]>`SELECT EXTRACT(EPOCH FROM expires_at-now())::float8 AS remaining FROM auth_flows WHERE id=${flow.id}::uuid`;
    expect(rows[0].remaining).toBeGreaterThan(590);
    expect(rows[0].remaining).toBeLessThanOrEqual(600);
  } finally { await db.$disconnect(); }
});
