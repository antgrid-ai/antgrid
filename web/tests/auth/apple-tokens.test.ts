// SPDX-FileCopyrightText: 2026 Radha AI Products
// SPDX-License-Identifier: LicenseRef-Elastic-2.0

import { describe, expect, test } from "bun:test";
import { createPublicKey } from "node:crypto";
import { jwtVerify } from "jose";
import { AppleTokenError, createAppleTokenClient } from "../../src/auth/apple-tokens.js";
import type { Env } from "../../src/env.js";
import { appleEnvOverrides } from "../helpers/app.js";
import { appleIdToken, fakeAppleFetch } from "../helpers/fake-apple.js";

const apple = appleEnvOverrides();
const env = apple as Env;
const publicKey = createPublicKey(apple.APPLE_PRIVATE_KEY!);
const SERVICES_ID = apple.APPLE_CLIENT_ID!;
const BUNDLE_ID = apple.APPLE_APP_BUNDLE_ID!;

/** Apple accepts a client secret only when its `sub` is the request's client. */
async function expectSecretFor(form: URLSearchParams, clientId: string) {
  expect(form.get("client_id")).toBe(clientId);
  await jwtVerify(form.get("client_secret")!, publicKey, {
    issuer: apple.APPLE_TEAM_ID,
    subject: clientId,
    audience: "https://appleid.apple.com",
  });
}

describe("Apple token client", () => {
  test("is absent when Sign in with Apple is not configured", () => {
    expect(createAppleTokenClient({} as Env)).toBeUndefined();
  });

  test("exchanges a native code as the bundle ID, without a redirect_uri", async () => {
    const idToken = appleIdToken({ sub: "apple-user-1", aud: BUNDLE_ID });
    const { calls, fetchImpl } = fakeAppleFetch(() =>
      Response.json({ refresh_token: "r1", id_token: idToken, access_token: "a1", expires_in: 3600 }),
    );
    const tokens = await createAppleTokenClient(env, fetchImpl)!.exchangeNativeCode("code-1");

    expect(tokens).toMatchObject({ refreshToken: "r1", idToken, accessToken: "a1", appleUserId: "apple-user-1" });
    const [call] = calls;
    expect(call!.url).toBe("https://appleid.apple.com/auth/token");
    expect(call!.form.get("grant_type")).toBe("authorization_code");
    expect(call!.form.get("code")).toBe("code-1");
    expect(call!.form.has("redirect_uri")).toBe(false);
    await expectSecretFor(call!.form, BUNDLE_ID);
  });

  test("surfaces Apple's error code", async () => {
    const { fetchImpl } = fakeAppleFetch(() => Response.json({ error: "invalid_grant" }, { status: 400 }));
    const err = await createAppleTokenClient(env, fetchImpl)!
      .exchangeNativeCode("stale")
      .catch((e: unknown) => e);
    expect(err).toBeInstanceOf(AppleTokenError);
    expect((err as AppleTokenError).code).toBe("invalid_grant");
  });

  test("revokes a refresh token as the client named", async () => {
    const { calls, fetchImpl } = fakeAppleFetch(() => new Response(null, { status: 200 }));
    await createAppleTokenClient(env, fetchImpl)!.revoke({ refreshToken: "r1", clientId: SERVICES_ID });

    const [call] = calls;
    expect(call!.url).toBe("https://appleid.apple.com/auth/revoke");
    expect(call!.form.get("token")).toBe("r1");
    expect(call!.form.get("token_type_hint")).toBe("refresh_token");
    await expectSecretFor(call!.form, SERVICES_ID);
  });

  test("names the client an id token was issued to, and only ours", () => {
    const client = createAppleTokenClient(env)!;
    expect(client.clientIdOf(appleIdToken({ sub: "u", aud: BUNDLE_ID }))).toBe(BUNDLE_ID);
    expect(client.clientIdOf(appleIdToken({ sub: "u", aud: SERVICES_ID }))).toBe(SERVICES_ID);
    expect(client.clientIdOf(appleIdToken({ sub: "u", aud: "com.someone.else" }))).toBeNull();
    expect(client.clientIdOf("not a jwt")).toBeNull();
    expect(client.clientIdOf(null)).toBeNull();
  });
});
