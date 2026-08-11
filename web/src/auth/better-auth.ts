import { betterAuth } from "better-auth";
import { oneTimeToken } from "better-auth/plugins";
import { crossDeviceMagicLink } from "./cross-device-plugin.js";
import { abOAuthProviderPlugins } from "./oauth-provider.js";
import { prismaAdapter } from "better-auth/adapters/prisma";
import type { PrismaClient } from "../generated/prisma/client.js";
import type { SendEmail } from "./email.js";
import type { Env } from "../env.js";
import { findProductAccountByUserId } from "../models/product-account.js";
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
const TRUSTED_SOCIAL_PROVIDERS = ["github", "google"] as const;

/** Floor for a password guarding remote control of the user's dev machine.
 *  Above Better-Auth's default of 8; the sign-up and reset forms state it. */
export const MIN_PASSWORD_LENGTH = 12;

/** Better-Auth's own ceiling (`maxPasswordLength`, default 128). Restated here
 *  so the forms can enforce it and say so: PASSWORD_TOO_LONG is thrown ahead of
 *  every other check, so an unhandled one reads as a generic "try again" that
 *  can never succeed. Keep in lockstep with the option below. */
export const MAX_PASSWORD_LENGTH = 128;

export function createAuth(deps: CreateAuthDeps) {
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

  return betterAuth({
    database,
    secret: deps.env.BETTER_AUTH_SECRET,
    baseURL: deps.env.BETTER_AUTH_URL,
    account: {
      accountLinking: {
        enabled: true,
        trustedProviders: [...TRUSTED_SOCIAL_PROVIDERS],
        allowDifferentEmails: false,
      },
    },
    databaseHooks: {
      user: {
        create: {
          before: async (user) => {
            if (typeof user.email === "string") {
              return { data: { ...user, email: normalizeEmail(user.email) } };
            }
            return { data: user };
          },
          after: async (user) => {
            await provisionBillingAccount(deps.db, user.id);
          },
        },
      },
      session: {
        create: {
          after: async (session) => {
            // Backfill billing account for users created before hooks or via
            // internalAdapter.createUser (cross-device), and on every sign-in.
            await provisionBillingAccount(deps.db, session.userId);
          },
        },
      },
      account: {
        create: {
          before: async (account) => {
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
    // Take the outbound email off the response path. Two reasons, both load
    // bearing: `runInBackgroundOrAwait` otherwise AWAITS the send, which (a)
    // makes the enumeration-safe endpoints answer a known address a full
    // ZeptoMail round trip slower than an unknown one, and (b) puts a mail
    // outage inside the try that wraps OAuth user creation, failing a
    // first-time GitHub sign-up with "unable to create user" after the rows
    // are already committed.
    //
    // Keep the `.catch`. `runInBackgroundOrAwait` attaches its own before
    // calling us, so this one never fires for a send — but the sibling
    // `runInBackground` passes the promise RAW and only falls back to a
    // catch-all when no handler is configured, i.e. supplying one opts out of
    // the guard. An unhandled rejection there takes the Bun process down.
    advanced: {
      backgroundTasks: {
        handler: (p) => {
          p.catch((e) => console.error("background task failed", e));
        },
      },
    },
    // Secondary to the magic link and OAuth, and the only path that can create
    // a user we have NOT already proven owns the address — those two prove it
    // before the row exists. So: no session until the address is verified.
    // `databaseHooks.user.create.after` provisions a real ProductAccount, and
    // autoSignIn would hand that account to whoever typed the address.
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
        await deps.sendEmail({
          to: user.email,
          subject: "Reset your Antgrid password",
          text:
            `Reset your password: ${resetPasswordUrl(token)}\n\n` +
            `Link expires in 1 hour. If you did not request this, ignore this ` +
            `email — your password is unchanged.`,
        });
      },
      // A reset is the account-takeover recovery path, so it must also sever
      // whatever the attacker was holding. Sessions only — device tokens are
      // revoked from /devices, and killing them here would strand every agent
      // machine on a routine password change.
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
        console.info(
          JSON.stringify({ evt: "auth.password.reset", userId: user.id, at: new Date().toISOString() })
        );
      },
    },
    emailVerification: {
      sendOnSignUp: true,
      // OFF on purpose. The resend an unverified sign-in needs is issued by
      // /ui/login/password instead, so it spends the same per-IP email budget
      // as the resend button. Left on, the token is a stateless JWT with no
      // cooldown of any kind, and the sign-in bucket (12/min) is 12x looser
      // than the email bucket — enough to bomb an address you signed up for
      // yourself and never verified.
      sendOnSignIn: false,
      autoSignInAfterVerification: true,
      sendVerificationEmail: async ({ user, token }) => {
        await deps.sendEmail({
          to: user.email,
          subject: "Verify your email for Antgrid",
          text:
            `Verify your email: ${verifyEmailUrl(token)}\n\n` +
            `Link expires in 1 hour. If you did not create an Antgrid account, ` +
            `ignore this email.`,
        });
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
    },
    plugins: [
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
}

export type Auth = ReturnType<typeof createAuth>;
