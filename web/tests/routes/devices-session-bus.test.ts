// SPDX-FileCopyrightText: 2026 Radha AI Products
// SPDX-License-Identifier: LicenseRef-Elastic-2.0

import { describe, test, expect, beforeAll, afterAll, beforeEach } from "bun:test";
import { randomBytes, randomUUID } from "node:crypto";
import { startTestPg, type PgHandle } from "../helpers/pg.js";
import { buildTestApp } from "../helpers/app.js";
import { createTestUser, createTestSession, createTestSubscription } from "../helpers/fixtures.js";

let pg: PgHandle;
beforeAll(async () => { pg = await startTestPg(); });
afterAll(async () => { await pg.stop(); });
beforeEach(async () => { await pg.truncate(); });

async function setup() {
  const { app } = buildTestApp(pg.db, pg.url);
  const user = await createTestUser(pg.db, "alice@example.com");
  const { cookie } = await createTestSession(pg.db, user.id);
  await createTestSubscription(pg.db, user.id, { tier: "pro" });
  const device = (userId: string, kind: "agent" | "app", extra: Record<string, unknown> = {}) =>
    pg.db.device.create({ data: { userId, deviceId: randomUUID(), publicKey: randomBytes(32),
      kind, platform: kind === "agent" ? "windows" : "android", displayName: kind, ...extra } });
  const patch = (id: string, body: unknown, headers: Record<string, string> = { cookie }) =>
    app.request(`/account/devices/${id}/session-bus`, { method: "PATCH",
      headers: { ...headers, "content-type": "application/json" }, body: JSON.stringify(body) });
  return { app, user, cookie, device, patch };
}

describe("PATCH /account/devices/:id/session-bus", () => {
  test("the owner raises grants and the response carries both values", async () => {
    const { device, user, patch } = await setup();
    const agent = await device(user.id, "agent");
    const res = await patch(agent.id, { orchestrator: true });
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ orchestrator: true, busControl: false });
    expect(await (await patch(agent.id, { busControl: true })).json()).toEqual({ orchestrator: true, busControl: true });
    expect(await (await patch(agent.id, { orchestrator: false })).json()).toEqual({ orchestrator: false, busControl: true });
  });

  test("another user's device, an app device, a revoked device and a bad id are 404 and unchanged", async () => {
    const { device, user, patch } = await setup();
    const other = await createTestUser(pg.db, "bob@example.com");
    const foreign = await device(other.id, "agent");
    const phone = await device(user.id, "app");
    const revoked = await device(user.id, "agent", { revokedAt: new Date() });
    for (const id of [foreign.id, phone.id, revoked.id, randomUUID(), "not-a-uuid"]) {
      expect((await patch(id, { orchestrator: true })).status).toBe(404);
    }
    for (const row of [foreign, phone, revoked]) {
      expect(await pg.db.device.findUniqueOrThrow({ where: { id: row.id } }))
        .toMatchObject({ orchestrator: false, busControl: false });
    }
  });

  test("requires a session and a valid body", async () => {
    const { device, user, patch } = await setup();
    const agent = await device(user.id, "agent");
    expect((await patch(agent.id, { orchestrator: true }, {})).status).toBe(401);
    expect((await patch(agent.id, {})).status).toBe(400);
    expect((await patch(agent.id, { orchestrator: true, other: 1 })).status).toBe(400);
  });

  test("does not bump policyGeneration or enqueue a policy push", async () => {
    const { device, user, patch } = await setup();
    const agent = await device(user.id, "agent");
    const policy = () => pg.db.peerAuthorizationPolicy.findUnique({ where: { userId: user.id } });
    const before = await policy();
    const outbox = await pg.db.peerAuthorizationOutbox.count({ where: { userId: user.id } });
    expect((await patch(agent.id, { orchestrator: true, busControl: true })).status).toBe(200);
    expect((await policy())?.generation).toEqual(before?.generation);
    expect(await pg.db.peerAuthorizationOutbox.count({ where: { userId: user.id } })).toBe(outbox);
  });

  test("GET /account/devices carries both flags for agent devices only", async () => {
    const { app, cookie, device, user, patch } = await setup();
    const agent = await device(user.id, "agent");
    await device(user.id, "app");
    await patch(agent.id, { busControl: true });
    const body = await (await app.request("/account/devices", { headers: { cookie } })).json() as
      { devices: Array<{ kind: string; orchestrator?: boolean; busControl?: boolean }> };
    expect(body.devices.find((d) => d.kind === "agent")).toMatchObject({ orchestrator: false, busControl: true });
    expect("orchestrator" in body.devices.find((d) => d.kind === "app")!).toBe(false);
  });
});
