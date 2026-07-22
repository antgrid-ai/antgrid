/**
 * One-off backfill: upgrade every existing account to the temporary
 * promotional Pro grant (see ensureDefaultSubscription), so accounts
 * provisioned before the promo went live aren't left stuck on free.
 *
 *   bun run scripts/backfill-promo-pro.ts
 *
 * Idempotent — safe to re-run. Already-promoted or already-paid accounts are
 * no-ops (ensureDefaultSubscription returns early for any non-free tier).
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
  if (!existsSync(LICENSE_ENV_PATH)) {
    console.error(`web/.env not found at ${LICENSE_ENV_PATH}. Run \`npm run setup\` first.`);
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
    const { ensureDefaultSubscription } = await import("../web/src/models/subscription.js");

    const accounts = await db.productAccount.findMany({
      where: { deletedAt: null },
      select: { id: true },
    });
    console.log(`Scanning ${accounts.length} account(s)...`);

    let upgraded = 0;
    let unchanged = 0;
    let skipped = 0;

    for (const account of accounts) {
      try {
        const before = await db.subscription.findFirst({
          where: { accountId: account.id, status: "active" },
          select: { tier: true },
        });
        await db.$transaction((tx) => ensureDefaultSubscription(tx, account.id));
        if (before?.tier !== "pro") {
          upgraded++;
        } else {
          unchanged++;
        }
      } catch (err) {
        skipped++;
        console.warn(`  skipped account ${account.id}: ${(err as Error).message}`);
      }
    }

    console.log(
      `Done. scanned=${accounts.length} upgraded=${upgraded} unchanged=${unchanged} skipped=${skipped}`,
    );
  } finally {
    await db.$disconnect();
  }
}

main().catch((err) => {
  console.error("\nbackfill-promo-pro failed:", err);
  process.exit(1);
});
