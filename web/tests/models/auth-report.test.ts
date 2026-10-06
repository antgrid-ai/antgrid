// SPDX-FileCopyrightText: 2026 Radha AI Products
// SPDX-License-Identifier: LicenseRef-Elastic-2.0

import { afterAll, beforeAll, beforeEach, expect, test } from "bun:test";
import { startTestPg, type PgHandle } from "../helpers/pg.js";
import { AuthReportQuery, loadAuthReport, retainAuthHistory } from "../../src/models/auth-report.js";
import { OriginSchema, requestOrigin } from "../../src/auth/contracts.js";
import { linkFlowUser, recordStage } from "../../src/auth/flows.js";
import { authScope } from "../../src/auth/transaction.js";
import { createTestUser } from "../helpers/fixtures.js";
import type { DB } from "../../src/db/index.js";

let pg: PgHandle;
beforeAll(async () => { pg = await startTestPg(); });
afterAll(async () => { await pg.stop(); });
beforeEach(async () => { await pg.truncate(); });

test("native attribution covers every platform and remains informational", () => {
  for (const platform of ["android", "ios", "macos", "windows", "linux"] as const) {
    const origin = requestOrigin(new Headers({ "x-antgrid-surface": "flutter", "x-antgrid-platform": platform, "x-antgrid-version": "1.0.0" }), "magic_link");
    expect(origin).toEqual({ surface: "flutter", platform, method: "magic_link", version: "1.0.0", quality: "reported" });
  }
  expect(requestOrigin(new Headers({ "user-agent": "Mozilla Windows" }), "password").platform).toBe("windows");
  expect(requestOrigin(null,"password").quality).toBe("unknown");
});

test("resends count once; 24-hour completion and later recovery remain distinct after retention", async () => {
  const createdAt = new Date(Date.now() - 40 * 86400000);
  const day = createdAt.toISOString().slice(0,10);
  const origin = requestOrigin(new Headers({ "x-antgrid-surface": "flutter", "x-antgrid-platform": "android", "x-antgrid-version": "1" }), "magic_link");
  for (const hours of [2,26]) {
    const journey = await pg.db.authJourney.create({ data: { origin,createdAt,category: "signup" } });
    const flows = await Promise.all([1,2].map(() => pg.db.authFlow.create({ data: { journeyId: journey.id,createdAt,expiresAt: createdAt } })));
    for (const flow of flows) await recordStage(pg.db,flow.id,"request_accepted");
    for (const stage of ["user_created","mail_queued","mail_accepted","approval_submitted","ownership_verified","session_issued","first_client_use"]) {
      await pg.db.authFlowEvent.create({ data: { flowId: flows[0].id, stage,at: new Date(createdAt.getTime()+hours*3600000) } });
    }
    await recordStage(pg.db,flows[1].id,"mail_failed","permanent");
  }
  const filter = AuthReportQuery.parse({ from: day,to: day, platform: "android" });
  const before = await loadAuthReport(pg.db,filter);
  expect(before.rows).toHaveLength(1);
  expect(before.rows[0]).toMatchObject({ accepted: 2,created: 2,queued: 2,mailAccepted: 2,approved: 2,completed: 1,recovered: 1,failures: 2,failureCategories: { permanent: 2 } });
  await retainAuthHistory(pg.db);
  expect(await pg.db.authJourney.count()).toBe(0);
  const after = await loadAuthReport(pg.db,filter);
  expect(after.rows).toEqual(before.rows);
  await retainAuthHistory(pg.db);
  expect((await loadAuthReport(pg.db,filter)).rows).toEqual(before.rows);
  expect((await loadAuthReport(pg.db,AuthReportQuery.parse({ from: day,to: day,platform: "ios" }))).rows).toHaveLength(0);
});

test("UTC cohort retention survives a database session in another timezone", async () => {
  const createdAt = new Date(Date.now()-40*86400000);
  createdAt.setUTCHours(0, 30, 0, 0);
  const day = createdAt.toISOString().slice(0,10);
  const journey = await pg.db.authJourney.create({ data: { origin: requestOrigin(null,"password"), createdAt } });
  await pg.db.$executeRaw`UPDATE auth_journeys SET created_at=${createdAt.toISOString()}::timestamptz WHERE id=${journey.id}::uuid`;
  await pg.db.$transaction(async (tx) => {
    await tx.$executeRaw`SET LOCAL TIME ZONE 'America/Los_Angeles'`;
    const database = new Proxy(tx, { get(target, property) {
      if (property === "$transaction") return async (callback: (client: typeof tx) => Promise<unknown>) => callback(tx);
      const value = Reflect.get(target, property);
      return typeof value === "function" ? value.bind(target) : value;
    } }) as DB;
    await retainAuthHistory(database);
  });
  expect(await pg.db.authJourney.count()).toBe(0);
  expect((await loadAuthReport(pg.db,AuthReportQuery.parse({ from: day,to: day }))).rows[0].accepted).toBe(1);
});

test("account origins stay immutable and deleted unverified users do not inflate registration totals", async () => {
  const user = await createTestUser(pg.db,"owner@example.com");
  const origins = ["ios","windows"].map((platform) => requestOrigin(new Headers({ "x-antgrid-surface": "flutter", "x-antgrid-platform": platform }),"magic_link"));
  const flows = await Promise.all(origins.map(async (origin) => {
    const journey = await pg.db.authJourney.create({ data: { origin, category: "activation" } });
    return pg.db.authFlow.create({ data: { journeyId: journey.id, expiresAt: new Date(Date.now()+600000) } });
  }));
  await Promise.all(flows.map((flow) => authScope.run({ tx: pg.db, flowId: flow.id, charged: new Set() },() => linkFlowUser(pg.db,user.id,"ownership_verified"))));
  const activated = await pg.db.user.findUniqueOrThrow({ where: { id: user.id } });
  expect(origins).toContainEqual(OriginSchema.parse(activated.activationOrigin));
  const other = flows[origins.findIndex((origin) => origin.platform !== (activated.activationOrigin as { platform: string }).platform)];
  await authScope.run({ tx: pg.db, flowId: other.id, charged: new Set() },() => linkFlowUser(pg.db,user.id,"ownership_verified"));
  expect((await pg.db.user.findUniqueOrThrow({ where: { id: user.id } })).activationOrigin).toEqual(activated.activationOrigin);
  const deleted = await createTestUser(pg.db,"tombstone@deleted.antgrid.invalid");
  await pg.db.user.update({ where: { id: deleted.id }, data: { emailVerified: false } });
  const report = await loadAuthReport(pg.db,AuthReportQuery.parse({}));
  expect(report.pendingUsers).toBe(0);
  expect(report.staleUsers).toBe(0);
});
