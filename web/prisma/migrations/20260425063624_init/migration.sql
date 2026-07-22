-- CreateTable
CREATE TABLE "paddle_customers" (
    "user_id" TEXT NOT NULL,
    "paddle_customer_id" TEXT NOT NULL,

    CONSTRAINT "paddle_customers_pkey" PRIMARY KEY ("user_id")
);

-- CreateTable
CREATE TABLE "subscriptions" (
    "id" UUID NOT NULL DEFAULT gen_random_uuid(),
    "user_id" TEXT NOT NULL,
    "paddle_subscription_id" TEXT,
    "tier" TEXT NOT NULL,
    "status" TEXT NOT NULL,
    "trial_started_at" TIMESTAMPTZ(6),
    "trial_ends_at" TIMESTAMPTZ(6),
    "current_period_end" TIMESTAMPTZ(6),
    "device_limit" INTEGER NOT NULL,
    "created_at" TIMESTAMPTZ(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updated_at" TIMESTAMPTZ(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "subscriptions_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "license_keys" (
    "id" UUID NOT NULL DEFAULT gen_random_uuid(),
    "subscription_id" UUID NOT NULL,
    "key_hash" BYTEA NOT NULL,
    "rotated_at" TIMESTAMPTZ(6),
    "created_at" TIMESTAMPTZ(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "license_keys_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "devices" (
    "id" UUID NOT NULL DEFAULT gen_random_uuid(),
    "user_id" TEXT NOT NULL,
    "device_id" TEXT NOT NULL,
    "kind" TEXT NOT NULL,
    "platform" TEXT NOT NULL,
    "display_name" TEXT NOT NULL,
    "public_key" BYTEA,
    "activated_at" TIMESTAMPTZ(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "last_seen_at" TIMESTAMPTZ(6),
    "revoked_at" TIMESTAMPTZ(6),

    CONSTRAINT "devices_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "device_tokens" (
    "id" UUID NOT NULL DEFAULT gen_random_uuid(),
    "device_id" UUID NOT NULL,
    "jti" TEXT NOT NULL,
    "issued_at" TIMESTAMPTZ(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "expires_at" TIMESTAMPTZ(6) NOT NULL,
    "revoked_at" TIMESTAMPTZ(6),

    CONSTRAINT "device_tokens_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "activation_codes" (
    "user_code" TEXT NOT NULL,
    "device_code" TEXT NOT NULL,
    "device_id_raw" BYTEA NOT NULL,
    "user_id" TEXT,
    "device_kind" TEXT NOT NULL,
    "platform" TEXT NOT NULL,
    "display_name_suggestion" TEXT NOT NULL,
    "expires_at" TIMESTAMPTZ(6) NOT NULL,
    "approved_at" TIMESTAMPTZ(6),
    "claimed_at" TIMESTAMPTZ(6),
    "approved_device_id" UUID,

    CONSTRAINT "activation_codes_pkey" PRIMARY KEY ("user_code")
);

-- CreateTable
CREATE TABLE "user" (
    "id" TEXT NOT NULL,
    "name" TEXT NOT NULL,
    "email" TEXT NOT NULL,
    "emailVerified" BOOLEAN NOT NULL DEFAULT false,
    "image" TEXT,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" TIMESTAMP(3) NOT NULL,

    CONSTRAINT "user_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "session" (
    "id" TEXT NOT NULL,
    "expiresAt" TIMESTAMP(3) NOT NULL,
    "token" TEXT NOT NULL,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" TIMESTAMP(3) NOT NULL,
    "ipAddress" TEXT,
    "userAgent" TEXT,
    "userId" TEXT NOT NULL,

    CONSTRAINT "session_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "account" (
    "id" TEXT NOT NULL,
    "accountId" TEXT NOT NULL,
    "providerId" TEXT NOT NULL,
    "userId" TEXT NOT NULL,
    "accessToken" TEXT,
    "refreshToken" TEXT,
    "idToken" TEXT,
    "accessTokenExpiresAt" TIMESTAMP(3),
    "refreshTokenExpiresAt" TIMESTAMP(3),
    "scope" TEXT,
    "password" TEXT,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" TIMESTAMP(3) NOT NULL,

    CONSTRAINT "account_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "verification" (
    "id" TEXT NOT NULL,
    "identifier" TEXT NOT NULL,
    "value" TEXT NOT NULL,
    "expiresAt" TIMESTAMP(3) NOT NULL,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" TIMESTAMP(3) NOT NULL,

    CONSTRAINT "verification_pkey" PRIMARY KEY ("id")
);

-- CreateIndex
CREATE UNIQUE INDEX "paddle_customers_paddle_customer_id_key" ON "paddle_customers"("paddle_customer_id");

-- CreateIndex
CREATE UNIQUE INDEX "subscriptions_paddle_subscription_id_key" ON "subscriptions"("paddle_subscription_id");

-- CreateIndex
CREATE INDEX "subscriptions_user_id_idx" ON "subscriptions"("user_id");

-- CreateIndex
CREATE UNIQUE INDEX "license_keys_key_hash_key" ON "license_keys"("key_hash");

-- CreateIndex
CREATE INDEX "license_keys_subscription_idx" ON "license_keys"("subscription_id");

-- CreateIndex
CREATE INDEX "devices_user_active_idx" ON "devices"("user_id");

-- CreateIndex
CREATE UNIQUE INDEX "devices_user_id_device_id_key" ON "devices"("user_id", "device_id");

-- CreateIndex
CREATE UNIQUE INDEX "device_tokens_jti_key" ON "device_tokens"("jti");

-- CreateIndex
CREATE INDEX "device_tokens_device_idx" ON "device_tokens"("device_id");

-- CreateIndex
CREATE UNIQUE INDEX "activation_codes_device_code_key" ON "activation_codes"("device_code");

-- CreateIndex
CREATE INDEX "activation_codes_expires_idx" ON "activation_codes"("expires_at");

-- CreateIndex
CREATE UNIQUE INDEX "user_email_key" ON "user"("email");

-- CreateIndex
CREATE INDEX "session_userId_idx" ON "session"("userId");

-- CreateIndex
CREATE UNIQUE INDEX "session_token_key" ON "session"("token");

-- CreateIndex
CREATE INDEX "account_userId_idx" ON "account"("userId");

-- CreateIndex
CREATE INDEX "verification_identifier_idx" ON "verification"("identifier");

-- AddForeignKey
ALTER TABLE "license_keys" ADD CONSTRAINT "license_keys_subscription_id_fkey" FOREIGN KEY ("subscription_id") REFERENCES "subscriptions"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "device_tokens" ADD CONSTRAINT "device_tokens_device_id_fkey" FOREIGN KEY ("device_id") REFERENCES "devices"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "session" ADD CONSTRAINT "session_userId_fkey" FOREIGN KEY ("userId") REFERENCES "user"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "account" ADD CONSTRAINT "account_userId_fkey" FOREIGN KEY ("userId") REFERENCES "user"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- Application invariants not expressible in Prisma schema:
ALTER TABLE "subscriptions" ADD CONSTRAINT subscriptions_tier_check CHECK (tier IN ('trial','pro'));
ALTER TABLE "subscriptions" ADD CONSTRAINT subscriptions_status_check CHECK (status IN ('active','past_due','canceled','expired'));
ALTER TABLE "subscriptions" ADD CONSTRAINT subscriptions_device_limit_check CHECK (device_limit > 0);
ALTER TABLE "devices" ADD CONSTRAINT devices_kind_check CHECK (kind IN ('agent','app'));
ALTER TABLE "devices" ADD CONSTRAINT devices_platform_check CHECK (platform IN ('macos','windows','linux','ios','android'));
ALTER TABLE "activation_codes" ADD CONSTRAINT activation_codes_device_kind_check CHECK (device_kind IN ('agent','app'));
ALTER TABLE "activation_codes" ADD CONSTRAINT activation_codes_platform_check CHECK (platform IN ('macos','windows','linux','ios','android'));

-- Partial index for active-device lookups (cannot express in Prisma `@@index`):
DROP INDEX IF EXISTS "devices_user_active_idx";
CREATE INDEX "devices_user_active_idx" ON "devices"(user_id) WHERE revoked_at IS NULL;

-- Required extensions for default expressions and citext usage:
CREATE EXTENSION IF NOT EXISTS "pgcrypto";
CREATE EXTENSION IF NOT EXISTS "citext";
