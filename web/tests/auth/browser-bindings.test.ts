// SPDX-FileCopyrightText: 2026 Radha AI Products
// SPDX-License-Identifier: LicenseRef-Elastic-2.0

import { beforeAll, afterAll, beforeEach, test, expect } from "bun:test";
import { startTestPg, type PgHandle } from "../helpers/pg.js";
import { createFlow } from "../../src/auth/flows.js";
import { createRequestFlow } from "../../src/auth/request-flow.js";
import { createPending, checkNonce } from "../../src/models/pending-sign-in.js";
import { digest } from "../../src/auth/native-plugin.js";
import { BROWSER_ID_COOKIE } from "../../src/auth/browser-bindings.js";
import { expireEmailPayloads } from "../../src/auth/email-outbox.js";

let pg: PgHandle;
beforeAll(async () => { pg = await startTestPg(); });
afterAll(async () => { await pg.stop(); });
beforeEach(async () => { await pg.truncate(); });

test("the five-binding budget spans native, request and cross-device flows and revokes evicted bindings", async () => {
  const secret = "binding-test-secret";
  const jar = new Map<string, string>();
  const origin = { surface: "web", platform: "windows", method: "magic_link", version: null, quality: "inferred" } as const;
  const first = await createFlow(pg.db, origin, 600);
  await pg.db.authFlow.update({ where: { id: first.id }, data: { createdAt: new Date(0) } });
  await createPending(pg.db, { id: first.id, journeyId: first.journeyId, email: "owner@example.com", nonce: "nonce",
    browserToken: "first-binding", secret, requesterUa: null, requesterIp: null });
  jar.set(`antgrid.cross_device_token.${first.id}`, "first-binding");
  for (let i = 0; i < 4; i++) {
    const flow = await createFlow(pg.db, { ...origin, method: "github" }, 600);
    await pg.db.authFlow.update({ where: { id: flow.id }, data: { bindingHash: digest(`native-${i}`) } });
    jar.set(`antgrid.native.${flow.id}`, `native-${i}`);
  }
  const headers = new Headers({ cookie: [...jar].map(([name, value]) => name + "=" + value).join("; ") });
  const newest = await createRequestFlow(pg.db, secret, "other@example.com", "reset", headers,
    (name) => jar.get(name), (name, value, age) => { if (age) jar.set(name, value); else jar.delete(name); });
  expect(jar.size).toBe(6);
  expect(jar.has(BROWSER_ID_COOKIE)).toBe(true);
  expect(jar.has(`antgrid.request_flow.${newest.id}`)).toBe(true);
  expect(jar.has(`antgrid.cross_device_token.${first.id}`)).toBe(false);
  const pending = await pg.db.pendingSignIn.findUniqueOrThrow({ where: { id: first.id } });
  expect(checkNonce(pending.browserTokenHash, "first-binding", secret)).toBe(false);
  expect(checkNonce(pending.nonceHash, "nonce", secret)).toBe(true);
});

test("expired and forged flow cookies do not consume the browser binding budget", async () => {
  const jar = new Map<string, string>();
  const origin = { surface: "web", platform: "unknown", method: "reset", version: null, quality: "unknown" } as const;
  for (let i = 0; i < 6; i++) {
    const flow = await createFlow(pg.db, origin, i === 0 ? -1 : 600);
    jar.set(`antgrid.request_flow.${flow.id}`, "forged-binding");
  }
  const newest = await createRequestFlow(pg.db, "secret", "owner@example.com", "reset",
    new Headers({ cookie: [...jar].map(([name, value]) => name + "=" + value).join("; ") }),
    (name) => jar.get(name), (name, value, age) => { if (age) jar.set(name, value); else jar.delete(name); });
  expect([...jar.keys()]).toEqual([BROWSER_ID_COOKIE, `antgrid.request_flow.${newest.id}`]);
});

test("simultaneous starts sharing a browser identity cannot exceed five valid bindings", async () => {
  const jar = new Map<string, string>();
  const start = (index: number, snapshot: Map<string, string>) => createRequestFlow(pg.db, "secret", `owner-${index}@example.com`, "reset",
    new Headers({ cookie: [...snapshot].map(([name, value]) => name + "=" + value).join("; ") }),
    (name) => snapshot.get(name), (name, value, age) => { if (age) jar.set(name, value); else jar.delete(name); });
  await start(0, new Map(jar));
  const shared = new Map(jar);
  await Promise.all(Array.from({ length: 8 }, (_, index) => start(index + 1, shared)));
  expect(await pg.db.authFlow.count({ where: { bindingHash: { not: null } } })).toBe(5);
  expect(await pg.db.authRateBucket.count({ where: { key: { startsWith: "auth-browser-binding:" } } })).toBe(5);
  const bound = await pg.db.authFlow.findMany({ where: { bindingHash: { not: null } } });
  await pg.db.authFlow.updateMany({ where: { id: { in: bound.map((flow) => flow.id) } }, data: { expiresAt: new Date(0) } });
  const remaining = await start(10, new Map(jar));
  expect(await pg.db.authRateBucket.count({ where: { key: { startsWith: "auth-browser-binding:" } } })).toBe(1);
  await pg.db.authFlow.delete({ where: { id: remaining.id } });
  expect(await pg.db.authRateBucket.count({ where: { key: { startsWith: "auth-browser-binding:" } } })).toBe(0);
  await start(11, new Map(jar));
  await pg.db.authRateBucket.updateMany({ where: { key: { startsWith: "auth-browser-binding:" } }, data: { stamps: [new Date(0)] } });
  await expireEmailPayloads(pg.db);
  expect(await pg.db.authRateBucket.count({ where: { key: { startsWith: "auth-browser-binding:" } } })).toBe(0);
});
