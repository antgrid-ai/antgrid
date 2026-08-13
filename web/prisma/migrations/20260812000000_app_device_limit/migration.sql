-- Collapse the two device caps into one axis. The cap that was fair-use across
-- every device kind becomes an abuse bound on `kind:'app'` rows alone, so the
-- name has to stop claiming otherwise. RENAME, never drop+add — subscriptions
-- carry a snapshotted limit that must survive (same reason as
-- 20260730000000_worker_limit).
ALTER TABLE "plans" RENAME COLUMN "device_limit" TO "app_device_limit";
ALTER TABLE "subscriptions" RENAME COLUMN "device_limit" TO "app_device_limit";

-- Machines are now the only server-enforced paywall, so Free lands on the wall
-- at 1 and Pro's count stops being a pricing lever. seedPlans() upserts with
-- `update: {}`, so a CATALOG_PLANS edit alone never reaches an existing
-- database — every catalog change needs its statement here, and the two move in
-- the same commit. Keep in lockstep with FREE_WORKER_LIMIT (src/billing/plans.ts)
-- and CATALOG_PLANS.workerLimit (src/models/plan.ts).
UPDATE "plans" SET "worker_limit" = 1 WHERE slug = 'free';
-- Label only: a new slug or UUID for Pro would strand every subscription
-- already pointing at this row.
UPDATE "plans" SET "worker_limit" = 10, "label" = 'Pro' WHERE slug = 'pro_yearly';
-- Trial is a Pro preview, so it tracks Pro's machines.
UPDATE "plans" SET "worker_limit" = 10 WHERE slug = 'trial';

-- DEACTIVATE, never DELETE. Two reasons, either one fatal:
-- subscriptions_plan_id_fkey is ON DELETE RESTRICT, so any subscription still
-- pointing here aborts the migration; and seedPlans() upserts by id with a live
-- `create` branch, so a row deleted here is re-created on the next boot at the
-- pre-migration values and active.
UPDATE "plans" SET "active" = false WHERE slug = 'pro_lifetime';

-- Re-sync the snapshotted limit onto live subscriptions. The provider guard is
-- what stops a negotiated contract being overwritten with the list price — the
-- snapshot is only a contract if something guards it. `IS DISTINCT FROM`, not
-- `<>`: provider is nullable, and a plain inequality is NULL for every row that
-- never went through a gateway (free and dev grants), silently skipping exactly
-- the rows this statement exists to move.
UPDATE "subscriptions" s
SET "worker_limit" = p."worker_limit"
FROM "plans" p
WHERE s."plan_id" = p."id" AND s."provider" IS DISTINCT FROM 'manual';
