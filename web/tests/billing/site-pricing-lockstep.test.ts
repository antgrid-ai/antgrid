import { describe, test, expect, beforeAll, afterAll } from "bun:test";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";
import { startTestPg, type PgHandle } from "../helpers/pg.js";
import { PRICING, TRIAL_DAYS } from "../../src/billing/plans.js";
import { PLAN_SLUG_FREE } from "../../src/models/plan.js";

/**
 * The marketing site keeps its own copy of the catalog (`site/src/data/pricing.ts`)
 * because it is a separate Bun project with no import path into `web/`. Its own
 * Playwright suite pins the rendered page to that copy, which catches a broken
 * card but never a stale one — Free sat at 2 machines and Pro at 3 for a whole
 * release after the catalog moved to 1 and 10, and every site test passed.
 * This is the only place the two sides are compared.
 *
 * The site file is read rather than imported: it pulls in `../config`, which is
 * Astro-resolved, and the numbers are the whole contract.
 */
const SITE_PRICING = resolve(
  dirname(fileURLToPath(import.meta.url)),
  "..",
  "..",
  "..",
  "site",
  "src",
  "data",
  "pricing.ts"
);

function siteConstant(name: string): number {
  const source = readFileSync(SITE_PRICING, "utf8");
  const match = source.match(new RegExp(`export const ${name} = (\\d+);`));
  if (!match) throw new Error(`site/src/data/pricing.ts no longer exports ${name}`);
  return Number(match[1]);
}

let pg: PgHandle;
beforeAll(async () => {
  pg = await startTestPg();
});
afterAll(async () => {
  await pg.stop();
});

describe("site marketing constants track the shipped catalog", () => {
  test("machine allowances match every plan row they quote", async () => {
    const [free, trial, pro] = await Promise.all([
      pg.db.plan.findUniqueOrThrow({ where: { slug: PLAN_SLUG_FREE } }),
      pg.db.plan.findUniqueOrThrow({ where: { slug: "trial" } }),
      pg.db.plan.findUniqueOrThrow({ where: { slug: "pro_yearly" } }),
    ]);

    expect({
      free: siteConstant("FREE_WORKERS"),
      trial: siteConstant("TRIAL_WORKERS"),
      pro: siteConstant("PRO_WORKERS"),
    }).toEqual({
      free: free.workerLimit,
      trial: trial.workerLimit,
      pro: pro.workerLimit,
    });
  });

  test("the advertised seat ceiling is the one checkout enforces", async () => {
    const { maxSeats } = await pg.db.plan.findUniqueOrThrow({ where: { slug: "pro_yearly" } });

    // `plans.max_seats` is nullable so a row can be uncapped. The site quotes a
    // ceiling, so an uncapped Pro is a false advert rather than a mismatched
    // number, and deserves to fail saying that.
    if (maxSeats === null) throw new Error("pro_yearly is uncapped, but the site advertises PRO_MAX_SEATS");

    expect(siteConstant("PRO_MAX_SEATS")).toBe(maxSeats);
  });

  test("both yearly prices match, in the units each side states them in", () => {
    const { listPriceCents, offerPriceCents } = PRICING.pro_yearly;

    // `offerPriceCents` is optional — a plan may carry list price only. The site
    // renders the offer struck through against the list, so its absence breaks
    // the card outright; compare only once there is something to compare.
    if (offerPriceCents === undefined) throw new Error("pro_yearly carries no offer price, but the site quotes one");

    expect({
      list: siteConstant("YEARLY_LIST_USD") * 100,
      offer: siteConstant("YEARLY_OFFER_USD") * 100,
    }).toEqual({ list: listPriceCents, offer: offerPriceCents });
  });

  test("the advertised trial length is the one billing grants", () => {
    expect(siteConstant("TRIAL_DAYS")).toBe(TRIAL_DAYS);
  });
});
