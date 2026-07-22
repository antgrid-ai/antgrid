-- Product billing: account-scoped subscriptions + plan catalog.

-- Drop legacy subscription invariants (device_limit / paddle columns removed).
ALTER TABLE "subscriptions" DROP CONSTRAINT IF EXISTS subscriptions_tier_check;
ALTER TABLE "subscriptions" DROP CONSTRAINT IF EXISTS subscriptions_status_check;
ALTER TABLE "subscriptions" DROP CONSTRAINT IF EXISTS subscriptions_device_limit_check;

-- Pre-release: no production billing rows to preserve.
DELETE FROM "subscriptions";

-- DropForeignKey
ALTER TABLE "license_keys" DROP CONSTRAINT IF EXISTS "license_keys_subscription_id_fkey";

-- DropIndex
DROP INDEX IF EXISTS "subscriptions_paddle_subscription_id_key";
DROP INDEX IF EXISTS "subscriptions_user_id_idx";

-- DropTable
DROP TABLE IF EXISTS "license_keys";
DROP TABLE IF EXISTS "paddle_customers";

-- CreateTable
CREATE TABLE "product_accounts" (
    "id" UUID NOT NULL DEFAULT gen_random_uuid(),
    "user_id" TEXT NOT NULL,
    "country" CHAR(2),
    "country_source" TEXT,
    "billing_provider" TEXT,
    "created_at" TIMESTAMPTZ(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updated_at" TIMESTAMPTZ(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "product_accounts_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "plans" (
    "id" UUID NOT NULL,
    "slug" TEXT NOT NULL,
    "label" TEXT NOT NULL,
    "tier" TEXT NOT NULL,
    "session_limit" INTEGER NOT NULL,
    "recurring" BOOLEAN NOT NULL,
    "trial" BOOLEAN NOT NULL,
    "active" BOOLEAN NOT NULL DEFAULT true,
    "sort_order" INTEGER NOT NULL DEFAULT 0,

    CONSTRAINT "plans_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "billing_customers" (
    "account_id" UUID NOT NULL,
    "provider" TEXT NOT NULL,
    "provider_customer_id" TEXT NOT NULL,

    CONSTRAINT "billing_customers_pkey" PRIMARY KEY ("account_id","provider")
);

-- CreateTable
CREATE TABLE "webhook_events" (
    "id" UUID NOT NULL DEFAULT gen_random_uuid(),
    "provider" TEXT NOT NULL,
    "provider_event_id" TEXT NOT NULL,
    "type" TEXT NOT NULL,
    "payload" JSONB NOT NULL,
    "received_at" TIMESTAMPTZ(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "processed_at" TIMESTAMPTZ(6),

    CONSTRAINT "webhook_events_pkey" PRIMARY KEY ("id")
);

-- AlterTable
ALTER TABLE "subscriptions" DROP COLUMN "device_limit",
DROP COLUMN "paddle_subscription_id",
DROP COLUMN "user_id",
ADD COLUMN     "account_id" UUID NOT NULL,
ADD COLUMN     "cancelled_at" TIMESTAMPTZ(6),
ADD COLUMN     "plan_id" UUID NOT NULL,
ADD COLUMN     "provider" TEXT,
ADD COLUMN     "provider_subscription_id" TEXT,
ADD COLUMN     "provider_transaction_id" TEXT,
ADD COLUMN     "session_limit" INTEGER NOT NULL;

-- AlterTable
ALTER TABLE "user" ADD COLUMN     "account_id" UUID,
ALTER COLUMN "email" SET DATA TYPE CITEXT;

-- CreateIndex
CREATE UNIQUE INDEX "product_accounts_user_id_key" ON "product_accounts"("user_id");

-- CreateIndex
CREATE UNIQUE INDEX "plans_slug_key" ON "plans"("slug");

-- CreateIndex
CREATE UNIQUE INDEX "billing_customer_provider_cust_key" ON "billing_customers"("provider", "provider_customer_id");

-- CreateIndex
CREATE UNIQUE INDEX "webhook_events_provider_event_id_key" ON "webhook_events"("provider_event_id");

-- CreateIndex
CREATE UNIQUE INDEX "subscriptions_provider_subscription_id_key" ON "subscriptions"("provider_subscription_id");

-- CreateIndex
CREATE UNIQUE INDEX "subscriptions_provider_transaction_id_key" ON "subscriptions"("provider_transaction_id");

-- CreateIndex
CREATE INDEX "subscriptions_account_id_idx" ON "subscriptions"("account_id");

-- CreateIndex
CREATE INDEX "subscriptions_account_status_idx" ON "subscriptions"("account_id", "status");

-- CreateIndex
CREATE UNIQUE INDEX "user_account_id_key" ON "user"("account_id");

-- AddForeignKey
ALTER TABLE "product_accounts" ADD CONSTRAINT "product_accounts_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "user"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "subscriptions" ADD CONSTRAINT "subscriptions_account_id_fkey" FOREIGN KEY ("account_id") REFERENCES "product_accounts"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "subscriptions" ADD CONSTRAINT "subscriptions_plan_id_fkey" FOREIGN KEY ("plan_id") REFERENCES "plans"("id") ON DELETE RESTRICT ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "billing_customers" ADD CONSTRAINT "billing_customers_account_id_fkey" FOREIGN KEY ("account_id") REFERENCES "product_accounts"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "user" ADD CONSTRAINT "user_account_id_fkey" FOREIGN KEY ("account_id") REFERENCES "product_accounts"("id") ON DELETE SET NULL ON UPDATE CASCADE;

-- Seed catalog plans (stable UUIDs — see web/src/models/plan.ts PLAN_UUID).
INSERT INTO "plans" ("id", "slug", "label", "tier", "session_limit", "recurring", "trial", "active", "sort_order")
VALUES
  ('00000000-0000-4000-8000-000000000001', 'free',         'Free',         'free',  0, false, false, true, 0),
  ('00000000-0000-4000-8000-000000000004', 'trial',        'Trial',        'trial', 2, true,  true,  true, 1),
  ('00000000-0000-4000-8000-000000000002', 'pro_yearly',   'Pro Yearly',   'pro',   3, true,  false, true, 2),
  ('00000000-0000-4000-8000-000000000003', 'pro_lifetime', 'Pro Lifetime', 'pro',   3, false, false, true, 3)
ON CONFLICT ("id") DO NOTHING;
