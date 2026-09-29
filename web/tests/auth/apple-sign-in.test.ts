// SPDX-FileCopyrightText: 2026 Radha AI Products
// SPDX-License-Identifier: LicenseRef-Elastic-2.0

import { describe, expect, test } from "bun:test";
import { generateKeyPairSync } from "node:crypto";
import { decodeProtectedHeader, jwtVerify } from "jose";
import { appleClientSecret } from "../../src/auth/apple-client-secret.js";
import { createAuth } from "../../src/auth/better-auth.js";
import { loadEnv, type Env } from "../../src/env.js";

const { privateKey, publicKey } = generateKeyPairSync("ec", { namedCurve: "prime256v1" });
const pem = privateKey.export({ type: "pkcs8", format: "pem" }).toString();

const apple = {
  APPLE_CLIENT_ID: "ai.radhaai.antgrid.web",
  APPLE_TEAM_ID: "TEAM123456",
  APPLE_KEY_ID: "KEY1234567",
  APPLE_PRIVATE_KEY: pem,
};

const baseSource = {
  PG_DATABASE_URL: "postgres://u:p@h:5432/db",
  BETTER_AUTH_SECRET: "x".repeat(32),
  BETTER_AUTH_URL: "http://localhost:8787",
  GITHUB_CLIENT_ID: "gh",
  GITHUB_CLIENT_SECRET: "ghs",
  GOOGLE_CLIENT_ID: "gl",
  GOOGLE_CLIENT_SECRET: "gls",
  CORS_ORIGINS: "http://a",
  PORT: "8787",
};

const DAY_MS = 24 * 60 * 60 * 1000;

describe("Apple client secret", () => {
  test("is an ES256 JWT Apple can verify against the key", async () => {
    const mint = appleClientSecret({
      teamId: apple.APPLE_TEAM_ID,
      keyId: apple.APPLE_KEY_ID,
      clientId: apple.APPLE_CLIENT_ID,
      privateKey: pem,
    });
    const token = mint();

    expect(decodeProtectedHeader(token)).toEqual({ alg: "ES256", kid: apple.APPLE_KEY_ID });
    const { payload } = await jwtVerify(token, publicKey, {
      issuer: apple.APPLE_TEAM_ID,
      audience: "https://appleid.apple.com",
      subject: apple.APPLE_CLIENT_ID,
    });
    // Apple refuses a secret that lives longer than six months.
    expect(payload.exp! - payload.iat!).toBeLessThanOrEqual(180 * 24 * 60 * 60);
  });

  test("is reused until a month before expiry, then re-minted", () => {
    let now = Date.UTC(2026, 0, 1);
    const mint = appleClientSecret({
      teamId: apple.APPLE_TEAM_ID,
      keyId: apple.APPLE_KEY_ID,
      clientId: apple.APPLE_CLIENT_ID,
      privateKey: pem,
      now: () => now,
    });
    const first = mint();
    now += 149 * DAY_MS;
    expect(mint()).toBe(first);
    now += 2 * DAY_MS;
    expect(mint()).not.toBe(first);
  });

  test("refuses a key that is not P-256", () => {
    const rsa = generateKeyPairSync("rsa", { modulusLength: 2048 })
      .privateKey.export({ type: "pkcs8", format: "pem" })
      .toString();
    expect(() =>
      appleClientSecret({ teamId: "t", keyId: "k", clientId: "c", privateKey: rsa }),
    ).toThrow("P-256");
  });
});

describe("Apple env", () => {
  test("is off when unset", () => {
    expect(loadEnv(baseSource).APPLE_CLIENT_ID).toBeUndefined();
  });

  test("a partial set fails the boot rather than the first sign-in", () => {
    const { APPLE_KEY_ID: _, ...partial } = apple;
    expect(() => loadEnv({ ...baseSource, ...partial })).toThrow("APPLE_KEY_ID");
  });

  test("accepts the .p8 PEM with its newlines escaped onto one line", () => {
    const oneLine = pem.trim().replace(/\n/g, "\\n");
    const env = loadEnv({ ...baseSource, ...apple, APPLE_PRIVATE_KEY: oneLine });
    expect(env.APPLE_PRIVATE_KEY).toBe(pem.trim());
    expect(env.APPLE_APP_BUNDLE_ID).toBe("ai.radhaai.antgrid");
  });

  test("rejects a private key that does not parse", () => {
    expect(() =>
      loadEnv({ ...baseSource, ...apple, APPLE_PRIVATE_KEY: "not a key" }),
    ).toThrow();
  });
});

describe("Apple provider", () => {
  async function providers(env: Env) {
    const auth = createAuth({ env, db: {} as never, sendEmail: async () => {} });
    return (await auth.$context).socialProviders;
  }

  test("is registered only when configured", async () => {
    const off = await providers(loadEnv(baseSource));
    expect(off.map((p) => p.id)).not.toContain("apple");

    const on = await providers(loadEnv({ ...baseSource, ...apple }));
    expect(on.map((p) => p.id)).toContain("apple");
  });

  // Pins the library behaviour the getter relies on: Better-Auth must hand the
  // provider our options object itself, not a copy that froze the secret.
  test("reads a live client secret through the provider", async () => {
    const on = await providers(loadEnv({ ...baseSource, ...apple }));
    const provider = on.find((p) => p.id === "apple")!;
    const descriptor = Object.getOwnPropertyDescriptor(provider.options, "clientSecret");
    expect(typeof descriptor?.get).toBe("function");
    await jwtVerify(provider.options!.clientSecret as string, publicKey);
  });
});
