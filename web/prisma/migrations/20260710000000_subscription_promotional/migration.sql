-- Marks a subscription as a temporary promotional grant (pro access without a
-- real purchase), so it can be identified and reconciled once in-app
-- purchases ship. Real purchases (applyPlanToAccountSubscription) always
-- leave this false.
ALTER TABLE "subscriptions" ADD COLUMN "promotional" BOOLEAN NOT NULL DEFAULT false;
