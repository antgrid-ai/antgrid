// SPDX-FileCopyrightText: 2026 Radha AI Products
// SPDX-License-Identifier: LicenseRef-Elastic-2.0

import { afterAll, beforeAll, beforeEach, describe, expect, test } from "bun:test";
import { startTestPg, type PgHandle } from "../helpers/pg.js";
import { appleEnvOverrides, buildTestApp } from "../helpers/app.js";
import { createTestSession, createTestUser } from "../helpers/fixtures.js";
import { appleIdToken, fakeAppleFetch, type AppleCall } from "../helpers/fake-apple.js";
import { createAppleTokenClient } from "../../src/auth/apple-tokens.js";
import type { Env } from "../../src/env.js";

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

const apple = appleEnvOverrides();
const SERVICES_ID = apple.APPLE_CLIENT_ID!;
const BUNDLE_ID = apple.APPLE_APP_BUNDLE_ID!;

function appWithApple(respond: (call: AppleCall) => Response) {
  const fake = fakeAppleFetch(respond);
  const appleTokens = createAppleTokenClient(apple as Env, fake.fetchImpl);
  const { app } = buildTestApp(pg.db, pg.url, { envOverrides: apple, appleTokens });
  return { app, calls: fake.calls };
}

async function appleUser(appleUserId: string, tokens: { refreshToken?: string; idToken?: string } = {}) {
  const user = await createTestUser(pg.db);
  await pg.db.account.create({
    data: {
      id: crypto.randomUUID(),
      userId: user.id,
      providerId: "apple",
      accountId: appleUserId,
      refreshToken: tokens.refreshToken ?? null,
      idToken: tokens.idToken ?? null,
    },
  });
  const { cookie } = await createTestSession(pg.db, user.id);
  return { user, cookie };
}

function postCode(app: ReturnType<typeof appWithApple>["app"], cookie: string, code: string) {
  return app.request("/account/apple/authorization-code", {
    method: "POST",
    headers: { cookie, "content-type": "application/json" },
    body: JSON.stringify({ code }),
  });
}

describe("POST /account/apple/authorization-code", () => {
  test("keeps the refresh token on the user's own Apple account", async () => {
    const idToken = appleIdToken({ sub: "apple-1", aud: BUNDLE_ID });
    const { app } = appWithApple(() => Response.json({ refresh_token: "r-native", id_token: idToken }));
    const { user, cookie } = await appleUser("apple-1");

    expect((await postCode(app, cookie, "code")).status).toBe(204);
    const row = await pg.db.account.findFirstOrThrow({ where: { userId: user.id, providerId: "apple" } });
    expect(row.refreshToken).toBe("r-native");
    expect(row.idToken).toBe(idToken);
  });

  test("refuses tokens for an Apple user this account is not, and revokes them", async () => {
    const stranger = appleIdToken({ sub: "apple-someone-else", aud: BUNDLE_ID });
    const { app, calls } = appWithApple((call) =>
      call.url.endsWith("/token")
        ? Response.json({ refresh_token: "r-stranger", id_token: stranger })
        : new Response(null, { status: 200 }),
    );
    const { user, cookie } = await appleUser("apple-1");

    expect((await postCode(app, cookie, "code")).status).toBe(409);
    const row = await pg.db.account.findFirstOrThrow({ where: { userId: user.id, providerId: "apple" } });
    expect(row.refreshToken).toBeNull();
    const revoke = calls.find((c) => c.url.endsWith("/revoke"));
    expect(revoke?.form.get("token")).toBe("r-stranger");
  });

  test("a spent or expired code is a 400, Apple failing is a 502", async () => {
    const { cookie } = await appleUser("apple-1");
    const spent = appWithApple(() => Response.json({ error: "invalid_grant" }, { status: 400 }));
    expect((await postCode(spent.app, cookie, "code")).status).toBe(400);
    const down = appWithApple(() => new Response("upstream", { status: 503 }));
    expect((await postCode(down.app, cookie, "code")).status).toBe(502);
  });

  test("needs a session, and a deployment that offers Apple", async () => {
    const { app } = appWithApple(() => Response.json({}));
    const anonymous = await app.request("/account/apple/authorization-code", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ code: "code" }),
    });
    expect(anonymous.status).toBe(401);

    const { cookie } = await appleUser("apple-1");
    const off = buildTestApp(pg.db, pg.url).app;
    expect((await postCode(off, cookie, "code")).status).toBe(404);
  });
});

describe("account deletion revokes Apple", () => {
  test("each token is revoked as the client that obtained it", async () => {
    const { app, calls } = appWithApple(() => new Response(null, { status: 200 }));
    const { user, cookie } = await appleUser("apple-1", {
      refreshToken: "r-web",
      idToken: appleIdToken({ sub: "apple-1", aud: SERVICES_ID }),
    });
    // A second Apple identity on the same user, from the native app.
    await pg.db.account.create({
      data: {
        id: crypto.randomUUID(),
        userId: user.id,
        providerId: "apple",
        accountId: "apple-2",
        refreshToken: "r-native",
        idToken: appleIdToken({ sub: "apple-2", aud: BUNDLE_ID }),
      },
    });

    const res = await app.request("/account/me", { method: "DELETE", headers: { cookie } });
    expect(res.status).toBe(200);

    const revoked = calls
      .filter((c) => c.url.endsWith("/revoke"))
      .map((c) => [c.form.get("token"), c.form.get("client_id")])
      .sort();
    expect(revoked).toEqual([
      ["r-native", BUNDLE_ID],
      ["r-web", SERVICES_ID],
    ]);
    expect(await pg.db.account.count({ where: { userId: user.id } })).toBe(0);
  });

  test("Apple refusing the revoke does not stop the deletion", async () => {
    const { app, calls } = appWithApple(() => Response.json({ error: "invalid_client" }, { status: 400 }));
    const { user, cookie } = await appleUser("apple-1", {
      refreshToken: "r-web",
      idToken: appleIdToken({ sub: "apple-1", aud: SERVICES_ID }),
    });

    const res = await app.request("/account/me", { method: "DELETE", headers: { cookie } });
    expect(res.status).toBe(200);
    expect(calls.length).toBe(1);
    expect(await pg.db.account.count({ where: { userId: user.id } })).toBe(0);
  });

  test("an Apple account without a refresh token deletes without calling Apple", async () => {
    const { app, calls } = appWithApple(() => new Response(null, { status: 200 }));
    const { cookie } = await appleUser("apple-1");

    const res = await app.request("/account/me", { method: "DELETE", headers: { cookie } });
    expect(res.status).toBe(200);
    expect(calls.length).toBe(0);
  });
});
