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

export function createAuth(deps: CreateAuthDeps) {
  const database =
    deps.databaseOverride ?? prismaAdapter(deps.db, { provider: "postgresql" });

  return betterAuth({
    database,
    secret: deps.env.BETTER_AUTH_SECRET,
    baseURL: deps.env.BETTER_AUTH_URL,
    account: {
      accountLinking: {
        enabled: true,
        trustedProviders: ["github", "google"],
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
    rateLimit: {
      customRules: {
        "/sign-in/cross-device/start": { window: 60, max: 5 },
        "/sign-in/cross-device/approve": { window: 60, max: 10 },
        "/sign-in/cross-device/status": { window: 60, max: 60 },
      },
    },
  });
}

export type Auth = ReturnType<typeof createAuth>;
