-- seedPlans upserts with `update: {}`, so the catalog's new Pro seat ceiling
-- reaches an existing database only through this statement.
UPDATE "plans" SET "max_seats" = 5 WHERE slug = 'pro_yearly';

-- Promotional Pro grants were created at the column default of one seat, which
-- leaves no seat to invite into. Paid rows are left alone: their seat count is
-- what the payment provider bills, and only the provider may change it.
UPDATE "subscriptions" SET "seats" = 5
WHERE "promotional" = true AND "seats" = 1 AND "tier" = 'pro';
