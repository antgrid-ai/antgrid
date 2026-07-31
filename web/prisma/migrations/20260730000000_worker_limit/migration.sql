-- Retire the concurrent-remote-agent axis (session_limit) in favour of a worker
-- cap: how many machines an account may run an agent on. RENAME, never
-- drop+add — subscriptions carry a snapshotted limit that must survive.
ALTER TABLE "plans" RENAME COLUMN "session_limit" TO "worker_limit";
ALTER TABLE "subscriptions" RENAME COLUMN "session_limit" TO "worker_limit";

-- Free ships at 2 and drops to 1 on the day billing goes live; see the
-- launch-day checklist in docs/plans/2026-07-30-worker-limit-pricing.md.
UPDATE "plans" SET "worker_limit" = 2 WHERE "slug" = 'free';
UPDATE "plans" SET "worker_limit" = 2 WHERE "slug" = 'trial';
UPDATE "plans" SET "worker_limit" = 3 WHERE "slug" IN ('pro_yearly', 'pro_lifetime');

-- Re-sync live subscriptions from their plan (mirrors the device_limit migration).
UPDATE "subscriptions" s
SET "worker_limit" = p."worker_limit"
FROM "plans" p
WHERE s."plan_id" = p."id";
