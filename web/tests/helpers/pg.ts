import { randomBytes } from "node:crypto";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";
import postgres from "postgres";
import { PrismaClient } from "../../src/generated/prisma/client.js";
import { PrismaPg } from "@prisma/adapter-pg";
import { toPostgresUri, withDatabase } from "../../src/db/connection-string.js";

// Resolve web root so `prisma migrate deploy` can find prisma/schema.prisma
// regardless of which package's cwd the tests are run from (web or evals).
const LICENSE_API_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..", "..");

export type PgHandle = {
  db: PrismaClient;
  url: string;
  stop: () => Promise<void>;
  truncate: () => Promise<void>;
};

const APP_TABLES = [
  "oauth_consent",
  "oauth_access_token",
  "oauth_refresh_token",
  "oauth_client",
  "jwks",
  "devices",
  "webhook_events",
  "billing_customers",
  "subscriptions",
  "product_accounts",
  "pending_sign_in",
  "analytic_event",
  "session",
  "account",
  "verification",
  '"user"',
];

/**
 * Spin an ephemeral per-file test database. Admin DDL (CREATE DATABASE /
 * DROP DATABASE) goes through the `postgres` driver — Prisma can't issue
 * those against the connection it's bound to. Application access is via
 * Prisma against the freshly-created DB.
 */
export async function startTestPg(): Promise<PgHandle> {
  const raw = process.env.PG_DATABASE_URL;
  if (!raw) {
    throw new Error(
      "PG_DATABASE_URL not set. Expected a local Postgres connection string " +
        "(URI form 'postgres://user:pass@host:port/db' or ADO.NET 'Host=..;Password=..;...')."
    );
  }
  const adminUri = toPostgresUri(raw);
  const dbName = `antgrid_test_${randomBytes(6).toString("hex")}`;

  // The preload (tests/helpers/preload.ts) migrates one template DB up front;
  // cloning it is a fast server-side copy. Fall back to create-then-migrate when
  // the preload didn't run (e.g. a file executed without the [test] preload).
  const template = (globalThis as Record<string, unknown>).__ANTGRID_TEMPLATE_DB__ as
    | string
    | undefined;

  const admin = postgres(adminUri, { max: 1, prepare: false, onnotice: () => {} });
  try {
    if (template) {
      await admin.unsafe(`CREATE DATABASE "${dbName}" TEMPLATE "${template}"`);
    } else {
      await admin.unsafe(`CREATE DATABASE "${dbName}"`);
    }
  } finally {
    await admin.end();
  }

  const testUri = withDatabase(adminUri, dbName);

  if (!template) {
    // Apply migrations via Prisma CLI against the new DB. Set cwd to the
    // web package root so prisma can locate prisma/schema.prisma even
    // when invoked from another package (e.g. evals).
    const r = spawnSync("bunx", ["--bun", "prisma", "migrate", "deploy"], {
      cwd: LICENSE_API_ROOT,
      env: { ...process.env, PG_DATABASE_URL: testUri },
      stdio: "pipe",
      encoding: "utf8",
      shell: process.platform === "win32",
    });
    if (r.status !== 0) {
      throw new Error(`prisma migrate deploy failed: ${r.stderr || r.stdout}`);
    }
  }

  const adapter = new PrismaPg({ connectionString: testUri });
  const db = new PrismaClient({ adapter });

  return {
    db,
    url: testUri,
    stop: async () => {
      await db.$disconnect();
      const cleanup = postgres(adminUri, { max: 1, prepare: false, onnotice: () => {} });
      try {
        await cleanup.unsafe(`DROP DATABASE IF EXISTS "${dbName}" WITH (FORCE)`);
      } finally {
        await cleanup.end();
      }
    },
    truncate: async () => {
      await db.$executeRawUnsafe(
        `TRUNCATE TABLE ${APP_TABLES.join(", ")} RESTART IDENTITY CASCADE`
      );
    },
  };
}
