// SPDX-FileCopyrightText: 2026 Radha AI Products
// SPDX-License-Identifier: LicenseRef-Elastic-2.0

import { getOAuthState, isAPIError, createAuthMiddleware } from "better-auth/api";
import { scopedAuthDb, authTransaction, authScope, lockAuthAccount } from "./transaction.js";
import { createRequestFlow } from "./request-flow.js";
import { classifyJourney, createFlow, linkFlowUser, recordStage } from "./flows.js";
import { jwtVerify } from "jose";
import { FlowResultSchema, safeReturnPath, requestOrigin } from "./contracts.js";
import { recipientLimit, sharedIpLimit } from "./recipient-limit.js";
import { nativeAuth, digest } from "./native-plugin.js";
import { authEmail } from "./templates.js";
import { APIError } from "better-auth/api";
import { betterAuth } from "better-auth";
import { oneTimeToken } from "better-auth/plugins";
import { appleClientSecret } from "./apple-client-secret.js";
import { crossDeviceMagicLink } from "./cross-device-plugin.js";
import { abOAuthProviderPlugins } from "./oauth-provider.js";
import { prismaAdapter } from "better-auth/adapters/prisma";
import type { PrismaClient } from "../generated/prisma/client.js";
import type { SendEmail } from "./email.js";
import type { Env } from "../env.js";
import { findProductAccountByUserId } from "../models/product-account.js";
import { findActiveMembership } from "../models/account-member.js";
import { ensureDefaultSubscription, provisionProductAccountForUser } from "../models/subscription.js";
import { purgeUnprovenPasswordCredential } from "../models/credential.js";

function normalizeEmail(email: string): string {
  return email.toLowerCase().trim();
}

export type CreateAuthDeps = {
  env: Env;
  db: PrismaClient;
  sendEmail: SendEmail;
  /** Test hook: inject an adapter (e.g. `memoryAdapter`) in place of the
   *  Prisma adapter. Production always uses the default. */
  databaseOverride?: Parameters<typeof betterAuth>[0]["database"];
};

async function provisionBillingAccount(db: PrismaClient, userId: string) {
  const existing = await findProductAccountByUserId(db, userId);
  // A member keeps the personal account they owned before joining, so this is
  // the branch that fires for them — and it fires on every sign-in and every
  // token mint. Left ungated it re-mints a promotional Pro grant on that orphan
  // account for the rest of the member's life: never read (entitlement resolves
  // to the team), so nothing surfaces it, while it silently un-spends the
  // grandfather grant accepting an invite is supposed to cost.
  const membership = await findActiveMembership(db, userId);
  if (membership && membership.accountId !== existing?.id) return;
  if (existing) {
    await ensureDefaultSubscription(db, existing.id);
    return;
  }
  await provisionProductAccountForUser(db, userId);
}

/** Landing page for the emailed verification link. Handles both outcomes:
 *  Better-Auth redirects here bare on success and with `?error=<CODE>` when the
 *  token is expired or forged. */
const VERIFY_EMAIL_CALLBACK = "/login/verified";

/** Landing page for the emailed reset link. Better-Auth's
 *  `/reset-password/:token` callback validates the token first, then redirects
 *  here with `?token=` (valid) or `?error=INVALID_TOKEN` (expired/forged), so
 *  the form is only ever rendered against a token that was live a moment ago. */
const RESET_PASSWORD_CALLBACK = "/reset-password";

/** Providers Better-Auth may auto-link to an existing address — and therefore
 *  the providers whose link can verify that address as a side effect. Feeds
 *  both `accountLinking.trustedProviders` and the credential purge below, so
 *  the two cannot drift. */
const TRUSTED_SOCIAL_PROVIDERS = ["github", "google", "apple"] as const;

/** Floor for a password guarding remote control of the user's dev machine.
 *  Above Better-Auth's default of 8; the reset and account forms state it. */
export const MIN_PASSWORD_LENGTH = 12;

/** Better-Auth's own ceiling (`maxPasswordLength`, default 128). Restated here
 *  so the forms can enforce it and say so: PASSWORD_TOO_LONG is thrown ahead of
 *  every other check, so an unhandled one reads as a generic "try again" that
 *  can never succeed. Keep in lockstep with the option below. */
export const MAX_PASSWORD_LENGTH = 128;

/** Whether this deployment offers Sign in with Apple. env.ts accepts the four
 *  keys only as a set, so any one of them stands for all. */
export function appleSignInConfigured(env: Env): boolean {
  return env.APPLE_CLIENT_ID !== undefined;
}

/**
 * Apple's provider options, or undefined when the deployment has not
 * configured Sign in with Apple (env.ts accepts the four keys only as a set).
 *
 * `clientSecret` is a getter, not a value: Better-Auth hands this same object
 * to the provider and reads the property at each token exchange, which is
 * what lets the six-month JWT re-mint on a long-running process.
 */
function appleProvider(env: Env) {
  if (!env.APPLE_CLIENT_ID || !env.APPLE_TEAM_ID || !env.APPLE_KEY_ID || !env.APPLE_PRIVATE_KEY) {
    return undefined;
  }
  const secret = appleClientSecret({
    teamId: env.APPLE_TEAM_ID,
    keyId: env.APPLE_KEY_ID,
    clientId: env.APPLE_CLIENT_ID,
    privateKey: env.APPLE_PRIVATE_KEY,
  });
  return {
    clientId: env.APPLE_CLIENT_ID,
    appBundleIdentifier: env.APPLE_APP_BUNDLE_ID,
    get clientSecret() {
      return secret();
    },
    // An identity token's audience is whoever asked Apple for it: the bundle
    // ID from the native iOS app, the Services ID from the web.
    // When set, this list overrides appBundleIdentifier in token verification.
    audience: [env.APPLE_APP_BUNDLE_ID, env.APPLE_CLIENT_ID],
  };
}

export function createAuth(deps: CreateAuthDeps) {
  const send = deps.sendEmail;
  deps = { ...deps, sendEmail: async (mail) => {
    try { return await send(mail); }
    catch (error) { if (authScope.getStore()) authScope.getStore()!.enqueueFailed = true; throw error; }
  } };
  const rateDb = deps.db;
  deps = { ...deps, db: scopedAuthDb(deps.db) };
  const database =
    deps.databaseOverride ?? prismaAdapter(deps.db, { provider: "postgresql" });
  const baseURL = deps.env.BETTER_AUTH_URL;

  // Build both emailed links here rather than using the `url` Better-Auth
  // hands the callback: that one carries whatever `callbackURL` rode on the
  // request that triggered the send (sign-up form, sign-in retry, resend
  // button), so the landing page would silently differ per entry point.
  function verifyEmailUrl(token: string): string {
    const url = new URL("/api/auth/verify-email", baseURL);
    url.searchParams.set("token", token);
    url.searchParams.set("callbackURL", VERIFY_EMAIL_CALLBACK);
    return url.toString();
  }

  function resetPasswordUrl(token: string): string {
    const url = new URL(`/api/auth/reset-password/${token}`, baseURL);
    url.searchParams.set("callbackURL", RESET_PASSWORD_CALLBACK);
    return url.toString();
  }

  const auth = betterAuth({
    database,
    logger: { level: "error", log: (level, message) => console.error("[auth] operation failed", { level, category: message.startsWith("Failed") ? "failure" : "auth" }) },
    secret: deps.env.BETTER_AUTH_SECRET,
    baseURL: deps.env.BETTER_AUTH_URL,
    // Apple returns the web flow by POSTing the authorization to our callback
    // from its own origin; Better-Auth's origin check refuses it otherwise.
    // Trusted only where Apple is offered, so no other deployment widens it.
    trustedOrigins: appleSignInConfigured(deps.env) ? ["https://appleid.apple.com"] : [],
    account: {
      accountLinking: {
        enabled: true,
        trustedProviders: [...TRUSTED_SOCIAL_PROVIDERS],
        allowDifferentEmails: false,
      },
      // Keyed on BETTER_AUTH_SECRET, so rotating that secret also makes every
      // stored provider token unreadable, not just every session. Rows written
      // before this was on stay readable: a token that does not look like
      // ciphertext is returned as-is, and the next sign-in rewrites it
      // encrypted. Code outside Better-Auth that touches these columns goes
      // through setTokenUtil / decryptOAuthToken (services/apple-account.ts).
      encryptOAuthTokens: true,
    },
    hooks: {
      before: createAuthMiddleware(async (ctx) => {
        if ((ctx.path === "/one-time-token/generate" && (deps.env.LEGACY_NATIVE_OAUTH === false || deps.env.LEGACY_NATIVE_OAUTH_ISSUANCE === false)) ||
          (ctx.path === "/one-time-token/verify" && deps.env.LEGACY_NATIVE_OAUTH === false)) {
          throw new APIError("FORBIDDEN", { code: "UPGRADE_REQUIRED", message: "Update Antgrid to continue signing in." });
        }
        const email = typeof ctx.body?.email === "string" ? normalizeEmail(ctx.body.email) : undefined;
        const mailPaths = ["/sign-up/email", "/request-password-reset", "/send-verification-email", "/sign-in/cross-device/start"];
        if (email && mailPaths.includes(ctx.path)) {
          const retry = await rateDb.$transaction((tx) => recipientLimit(tx as PrismaClient, deps.env.BETTER_AUTH_SECRET, email));
          if (retry) { authScope.getStore()!.retryAfter = retry; ctx.setHeader("Retry-After", String(retry)); throw new APIError("TOO_MANY_REQUESTS", { code: "EMAIL_THROTTLED", message: "Please wait before requesting another email" }); }
        }
        const rules: Record<string, [number, number]> = {
          "/sign-in/email": [10, 0.2], "/sign-up/email": [10, 1 / 360], "/request-password-reset": [5, 1 / 60],
          "/send-verification-email": [5, 1 / 60], "/sign-in/cross-device/start": [5, 0.2],
        };
        const rule = rules[ctx.path];
        if (rule) {
          const ip = ctx.headers?.get("x-forwarded-for") ?? "unresolved";
          const retry = await rateDb.$transaction((tx) => sharedIpLimit(tx as PrismaClient, ip, ctx.path, ...rule));
          if (retry) { authScope.getStore()!.retryAfter = retry; ctx.setHeader("Retry-After", String(retry)); throw new APIError("TOO_MANY_REQUESTS"); }
        }

        const accountEmails = new Set<string>();
        if (email) accountEmails.add(email);
        let approvalFlowId: string | undefined;
        let approvalMethod: "verification" | "reset" | undefined;
        if (ctx.path === "/verify-email" && ctx.query?.token) {
          const verified = await jwtVerify(String(ctx.query.token), new TextEncoder().encode(ctx.context.secret), { algorithms: ["HS256"] }).catch(() => null);
          if (typeof verified?.payload.email === "string") accountEmails.add(normalizeEmail(verified.payload.email));
          const record = await deps.db.verification.findFirst({ where: { identifier: "auth-review:" + digest(String(ctx.query.token)).toString("hex"), expiresAt: { gt: new Date() } } });
          if (record && authScope.getStore()) {
            approvalFlowId = record.value;
            approvalMethod = "verification";
            const flow = await deps.db.authFlow.findUnique({ where: { id: record.value }, include: { journey: { include: { user: true } } } });
            if (flow?.journey.user) accountEmails.add(normalizeEmail(flow.journey.user.email));
          }
        }
        if (["/sign-out", "/reset-password", "/change-password", "/set-password", "/change-email", "/delete-user"].includes(ctx.path)) {
          const current = await ctx.context.internalAdapter.findSession(await ctx.getSignedCookie(ctx.context.authCookies.sessionToken.name, ctx.context.secret) || "");
          if (current) accountEmails.add(normalizeEmail(current.user.email));
          if (ctx.path === "/reset-password" && ctx.body?.token) {
            const receipt = await deps.db.verification.findFirst({ where: { identifier: "auth-reset:" + digest(String(ctx.body.token)).toString("hex") } });
            if (receipt && authScope.getStore()) { approvalFlowId = receipt.value; approvalMethod = "reset"; }
            const token = await deps.db.verification.findFirst({ where: { identifier: "reset-password:" + String(ctx.body.token) } });
            const user = token && await deps.db.user.findUnique({ where: { id: token.value } });
            if (user) accountEmails.add(normalizeEmail(user.email));
          }
        }
        // Recovery may target a different account from the browser's current
        // session; a stable order prevents reciprocal requests from deadlocking.
        for (const accountEmail of [...accountEmails].sort()) await lockAuthAccount(deps.db, accountEmail);
        if (email && mailPaths.includes(ctx.path)) {
          if (ctx.path !== "/sign-in/cross-device/start") await createRequestFlow(deps.db,ctx.context.secret,email,
            ctx.path === "/sign-up/email" ? "password" : ctx.path === "/request-password-reset" ? "reset" : "verification",ctx.headers ?? null,
            (name) => ctx.getCookie(name),(name,value,maxAge) => { ctx.setCookie(name,value,{ httpOnly: true,secure: baseURL.startsWith("https:"),sameSite: "lax",path: "/",maxAge }); });
        }
        if (ctx.path === "/sign-in/email" || (ctx.path === "/sign-in/social" && ctx.body?.idToken)) {
          if (email) await createRequestFlow(deps.db,ctx.context.secret,email,"password",ctx.headers ?? null,
            (name) => ctx.getCookie(name),(name,value,maxAge) => { ctx.setCookie(name,value,{ httpOnly: true,secure: baseURL.startsWith("https:"),sameSite: "lax",path: "/",maxAge }); });
          else await createFlow(deps.db,requestOrigin(ctx.headers ?? null,String(ctx.body?.provider ?? "oauth")),600);
        }
        if (approvalFlowId && approvalMethod && authScope.getStore()) {
          authScope.getStore()!.flowId = approvalFlowId;
          await recordStage(deps.db, approvalFlowId, "approval_submitted");
          await deps.db.authFlow.update({ where: { id: approvalFlowId }, data: { approvalOrigin: requestOrigin(ctx.headers ?? null, approvalMethod) } });
        }
      }),
    },
    databaseHooks: {
      user: {
        update: {
          before: async (data, ctx) => {
            if (data.emailVerified === true && ctx?.path.startsWith("/callback/")) {
              const state = await getOAuthState().catch(() => null);
              if (state?.callbackURL) {
                const url = new URL(state.callbackURL, baseURL);
                const flowId = ["/oauth/handoff", "/oauth/web-complete"].includes(url.pathname) ? url.searchParams.get("flow") : null;
                if (flowId) authScope.getStore()!.flowId = flowId;
              }
            }
            return { data };
          },
        },
        create: {
          before: async (user) => {
            const state = await getOAuthState().catch(() => null);
            if (state?.callbackURL) {
              const url = new URL(state.callbackURL, baseURL);
              const flow = ["/oauth/handoff", "/oauth/web-complete"].includes(url.pathname) ? url.searchParams.get("flow") : null;
              if (flow && authScope.getStore()) authScope.getStore()!.flowId = flow;
            }
            if (typeof user.email === "string") {
              await lockAuthAccount(deps.db, normalizeEmail(user.email));
              return { data: { ...user, email: normalizeEmail(user.email) } };
            }
            return { data: user };
          },
          after: async (user) => {
            await linkFlowUser(deps.db, user.id, "user_created");
            if (user.emailVerified) { await linkFlowUser(deps.db, user.id, "ownership_verified"); await provisionBillingAccount(deps.db, user.id); }
          },
        },
      },
      session: {
        create: {
          before: async (session) => {
            const state = await getOAuthState().catch(() => null);
            if (state?.callbackURL) {
              const url = new URL(state.callbackURL, baseURL);
              const flow = ["/oauth/handoff", "/oauth/web-complete"].includes(url.pathname) ? url.searchParams.get("flow") : null;
              if (flow && authScope.getStore()) authScope.getStore()!.flowId = flow;
            }
            const user = await deps.db.user.findUnique({ where: { id: session.userId } });
            if (user) await lockAuthAccount(deps.db, user.email);
            return { data: session };
          },
          after: async (session) => {
            // Backfill billing account for users created before hooks or via
            // internalAdapter.createUser (cross-device), and on every sign-in.
            await linkFlowUser(deps.db, session.userId, "ownership_verified");
            await provisionBillingAccount(deps.db, session.userId);
            const flowId = authScope.getStore()?.flowId;
            if (flowId) await deps.db.authFlow.update({ where: { id: flowId }, data: { sessionId: session.id } });
            await recordStage(deps.db, flowId, "session_issued");
          },
        },
      },
      account: {
        create: {
          before: async (account) => {
            const owner = await deps.db.user.findUnique({ where: { id: String(account.userId) } });
            const state = await getOAuthState().catch(() => null);
            if (state?.callbackURL) {
              const url = new URL(state.callbackURL, baseURL);
              const flow = ["/oauth/handoff", "/oauth/web-complete"].includes(url.pathname) ? url.searchParams.get("flow") : null;
              if (flow) authScope.getStore()!.flowId = flow;
            }
            if (owner) { await lockAuthAccount(deps.db, owner.email); await classifyJourney(deps.db, owner.id, owner.emailVerified); }
            // Linking a trusted social account to a user who is NOT yet
            // verified is about to flip `emailVerified` for them
            // (oauth2/link-account.mjs), which would arm any password a
            // squatter planted on this address before the owner ever showed
            // up. Drop it here, while the row still says unverified — after
            // the flip the two cases are indistinguishable. The magic-link
            // path does the same at its own flip (cross-device-plugin.ts).
            if (!TRUSTED_SOCIAL_PROVIDERS.some((p) => p === account.providerId)) return;
            const user = await deps.db.user.findUnique({
              where: { id: String(account.userId) },
              select: { emailVerified: true },
            });
            if (user && !user.emailVerified) {
              await purgeUnprovenPasswordCredential(deps.db, String(account.userId));
            }
          },
        },
      },
    },
    emailAndPassword: {
      enabled: true,
      autoSignIn: false,
      requireEmailVerification: true,
      minPasswordLength: MIN_PASSWORD_LENGTH,
      maxPasswordLength: MAX_PASSWORD_LENGTH,
      // Email control is already full account access here (the magic link is
      // exactly that), so letting a reset MINT a credential for a
      // magic-link/OAuth-only user grants nothing new — and it is the recovery
      // path for a user who never had a password. Better-Auth creates the
      // credential row when none exists (api/routes/password.mjs).
      sendResetPassword: async ({ user, token }) => {
        try {
        const flowId = authScope.getStore()?.flowId;
        if (flowId) {
          const flow = await deps.db.authFlow.findUniqueOrThrow({ where: { id: flowId } });
          await deps.db.authJourney.update({ where: { id: flow.journeyId }, data: { userId: user.id } });
          await classifyJourney(deps.db, user.id, user.emailVerified);
          await deps.db.verification.create({ data: { id: crypto.randomUUID(), identifier: "auth-reset:" + digest(token).toString("hex"), value: flowId, expiresAt: new Date(Date.now() + 3600000) } });
        }
        await deps.sendEmail({
          to: user.email,
          ...authEmail({ action: "Reset your Antgrid password", url: resetPasswordUrl(token),
            description: "Continue only if you requested a password reset.", createdAt: new Date(), expiresAt: new Date(Date.now() + 3600000) }),
          expiresAt: new Date(Date.now() + 3600000),
        });
        } catch (error) { if (authScope.getStore()) authScope.getStore()!.enqueueFailed = true; throw error; }
      },
      // A reset is the account-takeover recovery path, so it must also sever
      // whatever the attacker was holding. Sessions only — device tokens are
      // revoked from /devices, and killing them here would strand every agent
      // machine on a routine password change.
      resetPasswordTokenExpiresIn: 3600,
      revokeSessionsOnPasswordReset: true,
      onPasswordReset: async ({ user }) => {
        // Opening the emailed reset link is the same proof of address ownership
        // the verification link asks for, and Better-Auth does not record it
        // (api/routes/password.mjs never touches emailVerified). Without this,
        // a user who never got the original verification mail resets their
        // password, is told to sign in with it, and is bounced straight back to
        // "check your email" by the password they just set.
        if (!user.emailVerified) {
          await deps.db.user.update({
            where: { id: user.id },
            data: { emailVerified: true },
          });
        }
        await linkFlowUser(deps.db, user.id, "ownership_verified");
        await provisionBillingAccount(deps.db, user.id);
        console.info(
          JSON.stringify({ evt: "auth.password.reset", userId: user.id, at: new Date().toISOString() })
        );
      },
    },
    emailVerification: {
      expiresIn: 3600,
      afterEmailVerification: async (user) => {
        await linkFlowUser(deps.db, user.id, "ownership_verified");
        await provisionBillingAccount(deps.db, user.id);
      },
      sendOnSignUp: true,
      // OFF on purpose. The resend an unverified sign-in needs is issued by
      // /ui/login/password instead, so it spends the same per-IP email budget
      // as the resend button. Left on, the token is a stateless JWT with no
      // cooldown of any kind, and the sign-in bucket (12/min) is 12x looser
      // than the email bucket — enough to bomb an address you signed up for
      // yourself and never verified.
      sendOnSignIn: false,
      autoSignInAfterVerification: false,
      sendVerificationEmail: async ({ user, token }) => {
        try {
        const flowId = authScope.getStore()?.flowId;
        if (flowId) {
          const flow = await deps.db.authFlow.findUniqueOrThrow({ where: { id: flowId } });
          await deps.db.authJourney.update({ where: { id: flow.journeyId }, data: { userId: user.id } });
          await classifyJourney(deps.db, user.id, user.emailVerified);
        }
        if (flowId) await deps.db.verification.create({ data: { id: crypto.randomUUID(), identifier: "auth-review:" + digest(token).toString("hex"), value: flowId, expiresAt: new Date(Date.now() + 3600000) } });
        await deps.sendEmail({
          to: user.email,
          ...authEmail({ action: "Verify your email for Antgrid", url: verifyEmailUrl(token),
            description: "Review this request before verifying your email address.", createdAt: new Date(), expiresAt: new Date(Date.now() + 3600000) }),
          expiresAt: new Date(Date.now() + 3600000),
        });
        } catch (error) { if (authScope.getStore()) authScope.getStore()!.enqueueFailed = true; throw error; }
      },
    },
    socialProviders: {
      github: {
        clientId: deps.env.GITHUB_CLIENT_ID,
        clientSecret: deps.env.GITHUB_CLIENT_SECRET,
      },
      google: {
        clientId: deps.env.GOOGLE_CLIENT_ID,
        clientSecret: deps.env.GOOGLE_CLIENT_SECRET,
      },
      apple: appleProvider(deps.env),
    },
    plugins: [
      nativeAuth(deps.db, baseURL),
      crossDeviceMagicLink({
        db: deps.db,
        sendEmail: deps.sendEmail,
        baseURL: deps.env.BETTER_AUTH_URL,
      }),
      oneTimeToken({
        storeToken: "hashed",
        disableClientRequest: true,
        expiresIn: 3,
      }),
      ...abOAuthProviderPlugins({ db: deps.db, env: deps.env }),
    ],
    session: {
      expiresIn: 60 * 60 * 24 * 30,
      updateAge: 60 * 60 * 24,
      cookieOptions: {
        sameSite: "lax",
        secure: deps.env.NODE_ENV === "production" || deps.env.NODE_ENV === "staging",
      },
    },
    // Buckets are keyed `<ip>|<path>` and customRules are resolved LAST, so
    // each entry here overrides Better-Auth's built-in default for that path
    // (`/sign-in*` and `/sign-up*` are 3/10s out of the box). These cover the
    // PUBLIC /api/auth/* surface only, and only in production —
    // `rateLimit.enabled` defaults to `isProduction`, and the limiter runs in
    // the router's onRequest, which an in-process `auth.api.*` call never
    // reaches. Every /ui/* form must therefore carry its own tokenBucket
    // (routes/ui.tsx); nothing here is a backstop for one that doesn't.
    rateLimit: {
      customRules: {
        // app.ts applies a refilling token bucket to this endpoint. The
        // built-in counter resets only after an idle window, so even steady
        // lease refresh traffic eventually exhausts it at any finite max.
        "/oauth2/token": false,
        "/sign-in/cross-device/start": { window: 60, max: 5 },
        "/sign-in/cross-device/approve": { window: 60, max: 10 },
        "/sign-in/cross-device/status": { window: 60, max: 60 },
        // Password sign-in is the only endpoint here that can be ground against
        // a stolen credential dump. Per-IP is the wrong axis for stuffing (one
        // guess per account, spread across IPs) but it is what Better-Auth
        // gives us; keep the cap loose enough that a shared office NAT signing
        // in at 9am doesn't trip it.
        "/sign-in/email": { window: 60, max: 10 },
        "/sign-up/email": { window: 3600, max: 10 },
        "/request-password-reset": { window: 3600, max: 5 },
        "/reset-password": { window: 3600, max: 10 },
        "/send-verification-email": { window: 3600, max: 5 },
      },
    },
  });
  const invoke = async <T>(fn: () => Promise<T>): Promise<T> => {
    if (deps.databaseOverride && typeof rateDb.$transaction !== "function") return fn();
    class RejectedResponse { constructor(public response: T) {} }
    try { return await authTransaction(deps.db, async () => {
      let result: T = await fn();
      const scope = authScope.getStore()!;
      if (scope.enqueueFailed) {
        if (result instanceof Response) throw new RejectedResponse(new Response(JSON.stringify({ code: "EMAIL_UNAVAILABLE", message: "Email service unavailable" }), { status: 503, headers: { "content-type": "application/json" } }) as T);
        throw new APIError("SERVICE_UNAVAILABLE", { code: "EMAIL_UNAVAILABLE", message: "Email service unavailable" });
      }
      if (result instanceof Response && result.ok && scope.flowId) {
        const flow = await deps.db.authFlow.findUnique({ where: { id: scope.flowId } });
        if (flow && result.headers.get("content-type")?.includes("application/json")) {
          const body = await result.clone().json();
          const receipt = FlowResultSchema.parse({ id: flow.id, journeyId: flow.journeyId, status: flow.sessionId ? "ready" : "pending",
            serverTime: new Date().toISOString(), expiresAt: flow.expiresAt.toISOString(), retryAt: new Date(flow.createdAt.getTime()+45000).toISOString(), delivery: "accepted" });
          result = new Response(JSON.stringify({ ...body, flow: receipt }), { status: result.status,headers: result.headers }) as T;
        }
      }
      if (result instanceof Response && scope.retryAfter) {
        const headers = new Headers(result.headers); headers.set("Retry-After", String(scope.retryAfter));
        result = new Response(result.body, { status: result.status, statusText: result.statusText, headers }) as T;
      }
      if (result instanceof Response && result.status >= 400) throw new RejectedResponse(result);
      return result;
    }); } catch (err) { if (err instanceof RejectedResponse) return err.response; throw err; }
  };
  return new Proxy(auth, { get(target, key) {
    if (key === "handler") return (request: Request) => invoke(() => target.handler(request));
    if (key === "api") return new Proxy(target.api, { get(api, name) {
      const fn = Reflect.get(api, name);
      return typeof fn === "function" ? (...args: unknown[]) => invoke(async () => {
        try { return await fn(...args); }
        catch (error) {
          if ((args[0] as { asResponse?: boolean } | undefined)?.asResponse && isAPIError(error)) {
            const retry = authScope.getStore()?.retryAfter;
            return new Response(JSON.stringify(error.body ?? { code: "AUTH_FAILED" }), { status: error.statusCode,
              headers: { "content-type": "application/json", ...retry ? { "Retry-After": String(retry) } : {} } });
          }
          throw error;
        }
      }) : fn;
    } });
    return Reflect.get(target, key);
  } });
}

export type Auth = ReturnType<typeof createAuth>;
