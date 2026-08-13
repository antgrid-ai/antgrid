-- Enterprise differs from Pro on four independent axes, and `slug` was carrying
-- three of them at once. Splitting them into columns is what lets Enterprise be
-- ONE plan row plus per-customer values on its own subscription — no table per
-- contract and no second billing pipeline, since `provider` is already a free
-- string. See docs/plans/2026-08-12-seat-billing.md.
--
--   billing_period   how often the charge recurs   none | yearly | lifetime | contract
--   sales_motion     how the row is bought         self_serve | contact_sales
--   capabilities     what the row unlocks          jsonb, validated on read

-- AlterTable
-- Both plans a card can buy today are yearly, so 'yearly' is the value that
-- backfills the self-serve rows correctly; every row that is not yearly states
-- its own period below.
ALTER TABLE "plans" ADD COLUMN "billing_period" TEXT NOT NULL DEFAULT 'yearly';
ALTER TABLE "plans" ADD COLUMN "sales_motion" TEXT NOT NULL DEFAULT 'self_serve';
-- A boolean column per feature would be a migration per feature, so the shape
-- is Zod-validated on read instead (src/billing/capabilities.ts). PERMANENT
-- default, unlike the transient one 20260626000000_device_limit adds and drops:
-- the matching @default in schema.prisma is what stops the next `migrate dev`
-- emitting an ALTER … DROP DEFAULT, after which every create that omits the
-- column fails on a NOT NULL constraint.
ALTER TABLE "plans" ADD COLUMN "capabilities" JSONB NOT NULL DEFAULT '{}';

-- seedPlans() upserts with `update: {}`, so a CATALOG_PLANS edit alone never
-- reaches an existing database — every catalog change needs its statement here,
-- and the two move in the same commit.
--
-- Blanket first, exceptions after, and all of it before the Enterprise INSERT:
-- Enterprise is the one row none of these values fit, so an unqualified UPDATE
-- reordered below it would silently sell the contract at the list motion.
UPDATE "plans" SET "sales_motion" = 'self_serve';
UPDATE "plans" SET "capabilities" = '{}'::jsonb;
UPDATE "plans" SET "billing_period" = 'yearly';
UPDATE "plans" SET "billing_period" = 'none' WHERE slug = 'free';
-- The retired row is deactivated, not deleted, and subscriptions still point at
-- it, so its period has to record what was actually sold rather than inherit the
-- self-serve default.
UPDATE "plans" SET "billing_period" = 'lifetime' WHERE slug = 'pro_lifetime';

-- Enterprise is one row, not a row per customer. The plan carries list-price
-- defaults — worker_limit and app_device_limit are Pro's numbers, a starting
-- point rather than a promise — and each contract's negotiated values live on
-- its own subscription, written with provider 'manual', which is exactly what
-- the re-sync at the bottom of this file then refuses to touch.
--
-- max_seats NULL is how a contract says "unlimited"; it is the value the column
-- was made nullable for in 20260813000000_account_members.
--
-- The id continues the PLAN_UUID series in src/models/plan.ts. `…0003` is
-- retired (pro_lifetime) and must never be reused, so this is `…0005`.
--
-- active = true is deliberate: `active` says the catalog carries the row and
-- `sales_motion` says it is not bought with a card. Hiding Enterprise behind
-- `active = false` would put two meanings back into one column, which is the
-- conflation these columns exist to undo — and seedPlans()' create branch
-- hardcodes active:true, so a row seeded inactive would come back active the
-- first time it went missing, with nothing to warn that the two disagreed.
-- Nothing sells it in the meantime: every checkout path gates on isPlanId
-- (src/billing/plans.ts), whose union this migration does not widen.
--
-- sort_order 4, not 3: 3 belongs to the retired pro_lifetime row, which still
-- exists in every migrated database, and a tie leaves listActivePlans' ORDER BY
-- to pick by physical row order.
INSERT INTO "plans" (
  "id", "slug", "label", "tier", "worker_limit", "app_device_limit", "max_seats",
  "recurring", "trial", "active", "sort_order", "billing_period", "sales_motion",
  "capabilities"
)
VALUES (
  '00000000-0000-4000-8000-000000000005', 'enterprise', 'Enterprise', 'enterprise',
  10, 10, NULL, true, false, true, 4, 'contract', 'contact_sales',
  '{"sso": true, "audit": true, "ipAllowlist": true}'
)
ON CONFLICT ("id") DO NOTHING;

-- AlterTable
-- The subscription is the contract: it snapshots the plan's capabilities at
-- apply time, so a negotiated set outlives a change to the list price. Same
-- permanent-default rule as the plans column above.
ALTER TABLE "subscriptions" ADD COLUMN "capabilities" JSONB NOT NULL DEFAULT '{}';

-- Re-sync the snapshot onto live subscriptions, in the shape
-- 20260730000000_worker_limit established. The provider guard is what stops a
-- negotiated contract being overwritten with the list price — the snapshot is
-- only a contract if something guards it.
--
-- `IS DISTINCT FROM`, never `<>`: provider is nullable (String?), and a plain
-- inequality evaluates to NULL — not true — for every row that never went
-- through a gateway. Free rows and dev grants are exactly those rows, so `<>`
-- silently skips the ones this statement exists to move while still reading
-- like it guards them.
UPDATE "subscriptions" s
SET "capabilities" = p."capabilities"
FROM "plans" p
WHERE s."plan_id" = p."id" AND s."provider" IS DISTINCT FROM 'manual';
