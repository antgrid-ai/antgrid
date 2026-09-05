/**
 * One-shot dev environment setup for the Antgrid stack.
 *
 *   bun run scripts/dev-setup.ts
 *
 * Idempotent. On first run:
 *   - Generates secrets and writes `web/.env` + `relay/.env` (and
 *     `relay/.env.example`).
 *   - Migrates the local Postgres DB pointed to by PG_DATABASE_URL.
 *   - Seeds a dev user + active "pro" subscription + a device row.
 *   - Mints a long-lived dev license JWT and prints the export commands
 *     you need to run the agent / app without going through the OAuth
 *     device flow.
 *
 * On subsequent runs the .env files are read, never rotated; only missing
 * fields are filled in. The dev token is reminted each run (cheap).
 */
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";
import { randomBytes } from "node:crypto";
import { spawnSync } from "node:child_process";
import { ensureDartMcp } from "./ensure-dart-mcp";
import { formatPreflightSummary, runPreflight } from "./preflight";

const ROOT = resolve(import.meta.dirname, "..");
const LICENSE_ENV = resolve(ROOT, "web/.env");
const RELAY_ENV = resolve(ROOT, "relay/.env");
const RELAY_ENV_EXAMPLE = resolve(ROOT, "relay/.env.example");

type EnvMap = Record<string, string>;

function parseEnv(text: string): EnvMap {
  const out: EnvMap = {};
  for (const line of text.split(/\r?\n/)) {
    const m = line.match(/^([A-Z0-9_]+)=(.*)$/);
    if (!m) continue;
    let v = m[2].trim();
    if ((v.startsWith('"') && v.endsWith('"')) || (v.startsWith("'") && v.endsWith("'"))) {
      v = v.slice(1, -1);
    }
    out[m[1]] = v;
  }
  return out;
}

function readEnvFile(path: string): EnvMap {
  if (!existsSync(path)) return {};
  return parseEnv(readFileSync(path, "utf8"));
}

function fillBlanks(env: EnvMap, defaults: EnvMap): { env: EnvMap; filled: string[] } {
  const out = { ...env };
  const filled: string[] = [];
  for (const [k, v] of Object.entries(defaults)) {
    if (!out[k] || out[k].length === 0) {
      out[k] = v;
      filled.push(k);
    }
  }
  return { env: out, filled };
}

function serializeEnv(env: EnvMap, header: string, order: string[]): string {
  const lines = [header, ""];
  const seen = new Set<string>();
  for (const k of order) {
    if (env[k] === undefined) continue;
    lines.push(`${k}=${env[k]}`);
    seen.add(k);
  }
  for (const [k, v] of Object.entries(env)) {
    if (seen.has(k)) continue;
    lines.push(`${k}=${v}`);
  }
  return lines.join("\n") + "\n";
}

function b64url(n: number): string {
  return randomBytes(n).toString("base64url");
}

function hex(n: number): string {
  return randomBytes(n).toString("hex");
}

const LICENSE_ORDER = [
  "NODE_ENV", "PG_DATABASE_URL",
  "BETTER_AUTH_SECRET", "BETTER_AUTH_URL",
  "GITHUB_CLIENT_ID", "GITHUB_CLIENT_SECRET",
  "GOOGLE_CLIENT_ID", "GOOGLE_CLIENT_SECRET",
  "ZEPTOMAIL_TOKEN", "EMAIL_FROM",
  "DEVICE_ID_HMAC_SALT",
  "RELAY_INTERNAL_URL", "RELAY_INTERNAL_SECRET",
  "CORS_ORIGINS", "PORT",
];
const RELAY_ORDER = [
  "PORT", "LICENSE_API_URL", "RELAY_INTERNAL_SECRET",
  "LOG_LEVEL", "LICENSE_CACHE_MAX_ENTRIES",
];

async function main() {
  console.log("=== Antgrid dev-setup ===");

  // --- web/.env ---
  const license = readEnvFile(LICENSE_ENV);
  const RELAY_DEFAULT_PORT = "8080";
  const licenseDefaults: EnvMap = {
    NODE_ENV: "development",
    PG_DATABASE_URL: "postgres://postgres:postgres@localhost:5432/antgrid",
    BETTER_AUTH_SECRET: b64url(32),
    GITHUB_CLIENT_ID: "stub-github-client-id",
    GITHUB_CLIENT_SECRET: "stub-github-client-secret",
    GOOGLE_CLIENT_ID: "stub-google-client-id",
    GOOGLE_CLIENT_SECRET: "stub-google-client-secret",
    EMAIL_FROM: '"Antgrid <no-reply@radhaai.org>"',
    DEVICE_ID_HMAC_SALT: b64url(32),
    RELAY_INTERNAL_URL: `http://127.0.0.1:${RELAY_DEFAULT_PORT}`,
    RELAY_INTERNAL_SECRET: hex(32),
    CORS_ORIGINS: "http://localhost:4321,http://localhost:5173",
    PORT: "8787",
  };
  const { env: licenseEnv, filled: licenseFilled } = fillBlanks(license, licenseDefaults);
  // Self-heal a stale RELAY_INTERNAL_URL pointing at a long-dead ephemeral
  // port from an earlier setup run — the relay always listens on
  // RELAY_DEFAULT_PORT in dev. Without this, /internal/revoke push fails with
  // ConnectionRefused on every device deletion.
  const expectedRelayUrl = `http://127.0.0.1:${RELAY_DEFAULT_PORT}`;
  if (licenseEnv.RELAY_INTERNAL_URL && !licenseEnv.RELAY_INTERNAL_URL.includes(`:${RELAY_DEFAULT_PORT}`)) {
    licenseEnv.RELAY_INTERNAL_URL = expectedRelayUrl;
    licenseFilled.push("RELAY_INTERNAL_URL (resynced)");
  }
  if (licenseFilled.length > 0 || !existsSync(LICENSE_ENV)) {
    writeFileSync(
      LICENSE_ENV,
      serializeEnv(
        licenseEnv,
        "# Local dev env for web. Gitignored. Do not commit.",
        LICENSE_ORDER,
      ),
    );
    console.log(`  web/.env: ${licenseFilled.length > 0 ? `filled ${licenseFilled.join(", ")}` : "created"}`);
  } else {
    console.log("  web/.env: already populated");
  }

  // --- relay/.env (must share RELAY_INTERNAL_SECRET with web) ---
  const relay = readEnvFile(RELAY_ENV);
  const relayDefaults: EnvMap = {
    PORT: "8080",
    LICENSE_API_URL: `http://localhost:${licenseEnv.PORT}`,
    RELAY_INTERNAL_SECRET: licenseEnv.RELAY_INTERNAL_SECRET,
    LOG_LEVEL: "info",
    LICENSE_CACHE_MAX_ENTRIES: "100000",
  };
  const { env: relayEnv, filled: relayFilled } = fillBlanks(relay, relayDefaults);
  // Force-sync the shared secret if the two have drifted.
  if (relayEnv.RELAY_INTERNAL_SECRET !== licenseEnv.RELAY_INTERNAL_SECRET) {
    relayEnv.RELAY_INTERNAL_SECRET = licenseEnv.RELAY_INTERNAL_SECRET;
    relayFilled.push("RELAY_INTERNAL_SECRET (resynced)");
  }
  writeFileSync(
    RELAY_ENV,
    serializeEnv(
      relayEnv,
      "# Local dev env for relay. Gitignored. Do not commit.",
      RELAY_ORDER,
    ),
  );
  console.log(`  relay/.env: ${relayFilled.length > 0 ? relayFilled.join(", ") : "already populated"}`);

  // --- relay/.env.example (committed) ---
  if (!existsSync(RELAY_ENV_EXAMPLE)) {
    writeFileSync(
      RELAY_ENV_EXAMPLE,
      [
        "# Relay environment variables.",
        "",
        "PORT=8080",
        "LICENSE_API_URL=http://localhost:8787",
        "# Must match web/.env's RELAY_INTERNAL_SECRET. >= 16 chars.",
        "RELAY_INTERNAL_SECRET=",
        "LOG_LEVEL=info",
        "LICENSE_CACHE_MAX_ENTRIES=100000",
        "",
      ].join("\n"),
    );
    console.log("  relay/.env.example: created");
  }

  // --- Preflight ---
  console.log("");
  const preflight = await runPreflight(licenseEnv.PG_DATABASE_URL);
  for (const line of formatPreflightSummary(preflight, licenseEnv.PG_DATABASE_URL)) {
    console.log(line);
  }
  if (!preflight.postgresReachable) {
    console.error("\nPostgres isn't reachable yet, so migration below would fail anyway.");
    if (preflight.containerRuntime) {
      console.error(`Start it with ${preflight.containerRuntime}, e.g.:`);
      console.error(
        "  docker run -d --name antgrid-pg -p 5432:5432 \\\n" +
          "    -e POSTGRES_USER=postgres -e POSTGRES_PASSWORD=postgres -e POSTGRES_DB=antgrid \\\n" +
          "    postgres:16-alpine",
      );
    } else {
      console.error(
        "No container runtime found — start a system Postgres, or install Docker/Podman and re-run.",
      );
    }
    process.exit(1);
  }

  // --- DB migrate ---
  console.log("\nMigrating Postgres (prisma migrate deploy)...");
  const migrate = spawnSync("bun", ["run", "migrate"], {
    cwd: resolve(ROOT, "web"),
    stdio: "inherit",
    env: { ...process.env, ...licenseEnv },
  });
  if (migrate.status !== 0) {
    console.error("\nMigration failed. Is Postgres running and PG_DATABASE_URL correct?");
    console.error(`  PG_DATABASE_URL=${licenseEnv.PG_DATABASE_URL}`);
    process.exit(1);
  }

  // --- Seed dev user + subscription ---
  console.log("\nSeeding dev user + subscription...");
  // Late-imported so missing PG drives migrate failure first.
  const { createDb } = await import("../web/src/db/index.js");

  const db = createDb(licenseEnv.PG_DATABASE_URL);
  const { seedPlans } = await import("../web/src/models/plan.js");
  const { grantDevSubscription } = await import("../web/src/models/subscription.js");

  await seedPlans(db);
  const DEV_EMAIL = "dev@antgrid.local";
  const DEV_USER_ID = "00000000-0000-4000-8000-000000000010";

  await db.user.upsert({
    where: { email: DEV_EMAIL },
    create: { id: DEV_USER_ID, email: DEV_EMAIL, name: "dev", emailVerified: true },
    update: {},
  });

  await grantDevSubscription(db, DEV_USER_ID);

  await db.$disconnect();

  // --- Agent tooling: Dart MCP server ---
  console.log("\nRegistering the Dart MCP server for coding agents...");
  ensureDartMcp(ROOT);

  console.log("\n=== Done ===\n");
  console.log("Run the stack:");
  console.log("  npm run dev          # starts web, relay, agent, app concurrently\n");
  console.log("To sign in, use the OAuth flow (GitHub, Google, or magic link) at");
  console.log("http://localhost:8787 after starting the stack. Grant Pro subscriptions with:");
  console.log("  bun run scripts/dev-grant.ts <your-email>\n");
  console.log("Dev user (dev@antgrid.local) is automatically seeded with an active Pro subscription.");
}

main().catch((err) => {
  console.error("\ndev-setup failed:", err);
  process.exit(1);
});
