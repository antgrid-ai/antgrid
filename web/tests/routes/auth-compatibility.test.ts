// SPDX-FileCopyrightText: 2026 Radha AI Products
// SPDX-License-Identifier: LicenseRef-Elastic-2.0

import { beforeAll, afterAll, beforeEach, test, expect } from "bun:test";
import { startTestPg, type PgHandle } from "../helpers/pg.js";
import { buildTestApp } from "../helpers/app.js";

let pg: PgHandle;
beforeAll(async () => { pg = await startTestPg(); });
afterAll(async () => { await pg.stop(); });
beforeEach(async () => { await pg.truncate(); });
const json = (body: unknown, cookie?: string) => ({ method: "POST", headers: { "content-type": "application/json", origin: "http://localhost:8787", ...cookie ? { cookie } : {} }, body: JSON.stringify(body) });
const cookiePairs = (response: Response) => response.headers.getSetCookie().map((cookie) => cookie.split(";")[0]);

test("released native magic-link clients can approve and poll using only the legacy binding", async () => {
  const mail: { text: string }[] = [];
  const { app } = buildTestApp(pg.db, pg.url, { sendEmail: async (message) => { mail.push(message); } });
  const started = await app.request("/api/auth/sign-in/cross-device/start", json({ email: "legacy@example.com" }));
  expect(started.status).toBe(200);
  const { id } = await started.json();
  const legacy = cookiePairs(started).find((cookie) => cookie.startsWith("antgrid.cross_device_token="))!;
  expect(legacy).toMatch(new RegExp(`^antgrid\\.cross_device_token=${id}\\.[A-Za-z0-9_-]{43}$`));
  const link = new URL(mail[0].text.match(/https?:\/\/\S+/)![0]);
  expect((await app.request("/api/auth/sign-in/cross-device/approve", json({ id, token: link.searchParams.get("t") }))).status).toBe(200);
  const poll = () => app.request("/api/auth/sign-in/cross-device/status", { headers: { cookie: legacy } });
  const ready = await poll();
  expect((await ready.json()).status).toBe("ready");
  expect(cookiePairs(ready).some((cookie) => cookie.startsWith("better-auth.session_token="))).toBe(true);
  const retry = await poll();
  expect(cookiePairs(retry)).toEqual(cookiePairs(ready));
  expect(await pg.db.session.count()).toBe(1);
});

test("a legacy alias cannot authorize another flow or disrupt modern concurrent bindings", async () => {
  const mail: { text: string }[] = [];
  const { app } = buildTestApp(pg.db, pg.url, { sendEmail: async (message) => { mail.push(message); } });
  const a = await app.request("/api/auth/sign-in/cross-device/start", json({ email: "first@example.com" }));
  const first = await a.json();
  const b = await app.request("/api/auth/sign-in/cross-device/start", json({ email: "second@example.com" }, cookiePairs(a).join("; ")));
  const second = await b.json();
  const legacyA = cookiePairs(a).find((cookie) => cookie.startsWith("antgrid.cross_device_token="))!;
  const wrong = await app.request(`/api/auth/sign-in/cross-device/status?id=${second.id}`, { headers: { cookie: legacyA } });
  expect((await wrong.json()).status).toBe("unbound");
  const secretA = legacyA.slice(legacyA.indexOf(".", legacyA.indexOf("=") + 1) + 1);
  const forged = await app.request(`/api/auth/sign-in/cross-device/status?id=${second.id}`, {
    headers: { cookie: `antgrid.cross_device_token=${second.id}.${secretA}` },
  });
  expect((await forged.json()).status).toBe("expired");
  const link = new URL(mail[0].text.match(/https?:\/\/\S+/)![0]);
  expect((await app.request("/api/auth/sign-in/cross-device/approve", json({ id: first.id, token: link.searchParams.get("t") }))).status).toBe(200);
  const jar = new Map<string, string>();
  for (const pair of [...cookiePairs(a), ...cookiePairs(b)]) jar.set(pair.slice(0, pair.indexOf("=")), pair);
  const cookie = [...jar.values()].join("; ");
  const own = await app.request(`/api/auth/sign-in/cross-device/status?id=${first.id}`, { headers: { cookie } });
  expect((await own.json()).status).toBe("ready");
  const pending = await app.request(`/api/auth/sign-in/cross-device/status?id=${second.id}`, { headers: { cookie } });
  expect((await pending.json()).status).toBe("pending");
  expect(await pg.db.session.count()).toBe(1);
});
