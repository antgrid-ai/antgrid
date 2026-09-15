import { afterAll, beforeAll, beforeEach, expect, test } from "bun:test";
import { createHmac } from "node:crypto";
import { startTestPg, type PgHandle } from "../helpers/pg.js";
import { deliverPeerPolicyBatch } from "../../src/relay/peer-policy-outbox.js";

let pg: PgHandle;
const targets = [{ url: "http://central.internal/internal/peer-policy", secret: "central-test-secret" },
  { url: "https://iroh.internal/internal/disconnect", secret: "iroh-test-secret" }];
beforeAll(async () => { pg = await startTestPg(); });
afterAll(async () => { await pg?.stop(); });
beforeEach(async () => {
  await pg.truncate();
  await pg.db.peerAuthorizationOutbox.create({ data: { userId: "account", generation: 4n } });
});

test("no central target leaves durable rows pending", async () => {
  expect(await deliverPeerPolicyBatch(pg.db, [])).toEqual({ attempted: 0, delivered: 0 });
  expect(await deliverPeerPolicyBatch(pg.db, [targets[1]])).toEqual({ attempted: 0, delivered: 0 });
  expect((await pg.db.peerAuthorizationOutbox.findFirstOrThrow()).deliveredAt).toBeNull();
});

test("signed metadata fans out to every target and marks delivered only after all acknowledge", async () => {
  const seen: string[] = [];
  const fetchImpl = (async (url: string | URL | Request, init: RequestInit) => {
    const target = targets.find((item) => item.url === String(url))!;
    const body = String(init.body);
    expect(new Headers(init.headers).get("x-antgrid-signature")).toBe(createHmac("sha256", target.secret).update(body).digest("hex"));
    expect(JSON.parse(body)).toEqual({ userId: "account", generation: "4", issuedAt: expect.any(Number) });
    expect(init.redirect).toBe("error");
    expect(init.signal).toBeInstanceOf(AbortSignal);
    seen.push(String(url));
    return new Response(null, { status: 204 });
  }) as typeof fetch;
  expect(await deliverPeerPolicyBatch(pg.db, targets, fetchImpl)).toEqual({ attempted: 1, delivered: 1 });
  expect(seen).toHaveLength(2);
  expect((await pg.db.peerAuthorizationOutbox.findFirstOrThrow()).deliveredAt).not.toBeNull();
});

test("partial failure schedules a durable retry and does not acknowledge the row", async () => {
  const fetchImpl = (async (url: string | URL | Request) => new Response(null,
    { status: String(url) === targets[0].url ? 204 : 503 })) as typeof fetch;
  expect(await deliverPeerPolicyBatch(pg.db, targets, fetchImpl)).toEqual({ attempted: 1, delivered: 0 });
  const row = await pg.db.peerAuthorizationOutbox.findFirstOrThrow();
  expect(row.deliveredAt).toBeNull();
  expect(row.attempts).toBe(1);
  expect(row.nextAttemptAt.getTime()).toBeGreaterThan(Date.now());
});

test("concurrent workers share a transaction lock and deliver each row once per attempt", async () => {
  let calls = 0;
  const fetchImpl = (async () => { calls++; await new Promise((resolve) => setTimeout(resolve, 50)); return new Response(null, { status: 204 }); }) as unknown as typeof fetch;
  const results = await Promise.all([deliverPeerPolicyBatch(pg.db, targets, fetchImpl), deliverPeerPolicyBatch(pg.db, targets, fetchImpl)]);
  expect(results.reduce((sum, row) => sum + row.delivered, 0)).toBe(1);
  expect(calls).toBe(2);
});
