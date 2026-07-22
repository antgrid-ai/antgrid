import { buildApp } from "../../src/app.js";
import { createAuth } from "../../src/auth/better-auth.js";
import { createEmailSender, type SendEmail } from "../../src/auth/email.js";
import type { PrismaClient } from "../../src/generated/prisma/client.js";
import type { Env } from "../../src/env.js";

/**
 * Fixed Better-Auth secret shared across all test runs so that
 * `createTestSession` (which needs the secret to sign the session cookie) and
 * `buildTestApp` (which verifies it) always agree on the key.
 */
export const TEST_BETTER_AUTH_SECRET = "antgrid-test-better-auth-secret-for-tests-only-not-prod";

export type BuildTestAppOptions = {
  /** Override the email sender. Defaults to the dev console sender. */
  sendEmail?: SendEmail;
  /**
   * @deprecated No-op. The Prisma adapter is now always used so that sessions
   * inserted via fixtures are visible to auth.api.getSession. Kept for
   * backwards compatibility; callers that pass `true` continue to work.
   */
  usePrismaAdapter?: boolean;
  /** Optional overrides applied on top of the default test env. */
  envOverrides?: Partial<Env>;
};

export function buildTestApp(
  db: PrismaClient,
  url: string,
  opts: BuildTestAppOptions = {}
) {
  const baseEnv: Env = {
    NODE_ENV: "test",
    PG_DATABASE_URL: url,
    // Use a fixed secret so that sessions signed by createTestSession are
    // verifiable by the app. See TEST_BETTER_AUTH_SECRET above.
    BETTER_AUTH_SECRET: TEST_BETTER_AUTH_SECRET,
    BETTER_AUTH_URL: "http://localhost:8787",
    GITHUB_CLIENT_ID: "gh",
    GITHUB_CLIENT_SECRET: "ghs",
    GOOGLE_CLIENT_ID: "gl",
    GOOGLE_CLIENT_SECRET: "gls",
    EMAIL_FROM: "Antgrid <no-reply@radhaai.org>",
    CORS_ORIGINS: ["http://localhost:4321"],
    PORT: 0,
  } as Env;
  const env: Env = { ...baseEnv, ...(opts.envOverrides ?? {}) };
  const sendEmail =
    opts.sendEmail ??
    createEmailSender({ zeptoToken: undefined, from: env.EMAIL_FROM });
  // Always use the real Prisma adapter so that sessions inserted via fixtures
  // (db.session.create) are visible to auth.api.getSession — the same path
  // the production middleware uses after the Better-Auth refactor.
  const auth = createAuth({ env, db, sendEmail });
  const relay = { baseUrl: env.RELAY_INTERNAL_URL, secret: env.RELAY_INTERNAL_SECRET };
  return {
    app: buildApp({ db, auth, env, corsOrigins: env.CORS_ORIGINS, relay }),
    env,
  };
}
