-- Split the single per-account cap into two axes:
--   session_limit -> concurrent remote-running-agent cap (the paid axis)
--   device_limit  -> fair-use device-registration cap (generous, all tiers)
-- session_limit previously did double duty as the device cap; this migration
-- re-points it to its true meaning and adds the separate fair-use device cap.

-- Add the new column with a transient default so existing rows are backfilled,
-- then drop the default to match the schema (which carries no @default).
ALTER TABLE "plans" ADD COLUMN "device_limit" INTEGER NOT NULL DEFAULT 10;
ALTER TABLE "plans" ALTER COLUMN "device_limit" DROP DEFAULT;

ALTER TABLE "subscriptions" ADD COLUMN "device_limit" INTEGER NOT NULL DEFAULT 10;
ALTER TABLE "subscriptions" ALTER COLUMN "device_limit" DROP DEFAULT;

-- Repoint the catalog: paid tiers now allow 10 concurrent remote agents.
-- free stays 0, trial stays 2. device_limit is 10 everywhere (set by the
-- backfill default above).
UPDATE "plans" SET "session_limit" = 10 WHERE "slug" IN ('pro_yearly', 'pro_lifetime');

-- Re-sync existing subscriptions to their plan's new caps (pre-release: safe to
-- overwrite — no production billing rows depend on the old device-count value).
UPDATE "subscriptions" s
SET "session_limit" = p."session_limit",
    "device_limit"  = p."device_limit"
FROM "plans" p
WHERE s."plan_id" = p."id";
