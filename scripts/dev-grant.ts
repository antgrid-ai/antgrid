/**
 * Grant a Pro subscription to an existing user, identified by email.
 *
 *   bun run scripts/dev-grant.ts <email>
 *
 * Use this for dev/eval setups where you've signed into the web
 * via OAuth (creating a real user row) and need a subscription attached.
 * `npm run setup` only seeds the synthetic `dev@antgrid.local` user.
 */
import { existsSync, readFileSync } from "node:fs";
import { resolve } from "node:path";

const ROOT = resolve(import.meta.dir, "..");
const LICENSE_ENV_PATH = resolve(ROOT, "web/.env");

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

async function main() {
  const email = process.argv[2];
  if (!email) {
    console.error("Usage: bun run scripts/dev-grant.ts <email>");
    process.exit(1);
  }

  if (!existsSync(LICENSE_ENV_PATH)) {
    console.error(
      `web/.env not found at ${LICENSE_ENV_PATH}. Run \`npm run setup\` first.`,
    );
    process.exit(1);
  }
  const env = parseEnv(readFileSync(LICENSE_ENV_PATH, "utf8"));
  if (!env.PG_DATABASE_URL) {
    console.error("PG_DATABASE_URL missing from web/.env.");
    process.exit(1);
  }

  const { createDb } = await import("../web/src/db/index.js");
  const db = createDb(env.PG_DATABASE_URL);

  try {
    const user = await db.user.findUnique({ where: { email } });
    if (!user) {
      console.error(
        `No user with email ${email}. Sign in via OAuth (browser) first, then re-run.`,
      );
      process.exit(1);
    }

    const { grantDevSubscription } = await import("../web/src/models/subscription.js");
    const sub = await grantDevSubscription(db, user.id);
    console.log(
      `Granted Pro subscription to ${email} (sub=${sub.id}, tier=${sub.tier}, expires=${sub.currentPeriodEnd?.toISOString()}).`,
    );
  } finally {
    await db.$disconnect();
  }
}

main().catch((err) => {
  console.error("\ndev-grant failed:", err);
  process.exit(1);
});
