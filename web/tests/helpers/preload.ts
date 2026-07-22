import { afterAll } from "bun:test";
import { randomBytes } from "node:crypto";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";
import postgres from "postgres";
import { toPostgresUri, withDatabase } from "../../src/db/connection-string.js";

// Build a single migrated "template" database ONCE per `bun test` process.
// Every test file then clones it via `CREATE DATABASE ... TEMPLATE` (a fast
// server-side file copy) instead of re-running `prisma migrate deploy` — the
// per-file subprocess that dominated the suite's wall-clock. The cloned name is
// published on globalThis for startTestPg (tests/helpers/pg.ts) to consume.
const WEB_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..", "..");

const raw = process.env.PG_DATABASE_URL;
if (!raw) {
  throw new Error(
    "PG_DATABASE_URL not set. Expected a local Postgres connection string " +
      "(URI form 'postgres://user:pass@host:port/db' or ADO.NET 'Host=..;Password=..;...')."
  );
}
const adminUri = toPostgresUri(raw);
const templateName = `antgrid_tmpl_${randomBytes(6).toString("hex")}`;

const admin = postgres(adminUri, { max: 1, prepare: false, onnotice: () => {} });
try {
  await admin.unsafe(`CREATE DATABASE "${templateName}"`);
} finally {
  await admin.end();
}

const r = spawnSync("bunx", ["--bun", "prisma", "migrate", "deploy"], {
  cwd: WEB_ROOT,
  env: { ...process.env, PG_DATABASE_URL: withDatabase(adminUri, templateName) },
  stdio: "pipe",
  encoding: "utf8",
  shell: process.platform === "win32",
});
if (r.status !== 0) {
  throw new Error(`template migrate deploy failed: ${r.stderr || r.stdout}`);
}

(globalThis as Record<string, unknown>).__ANTGRID_TEMPLATE_DB__ = templateName;

afterAll(async () => {
  const cleanup = postgres(adminUri, { max: 1, prepare: false, onnotice: () => {} });
  try {
    await cleanup.unsafe(`DROP DATABASE IF EXISTS "${templateName}" WITH (FORCE)`);
  } finally {
    await cleanup.end();
  }
});
