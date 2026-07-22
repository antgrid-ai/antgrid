-- DropTable
DROP TABLE IF EXISTS "activation_codes";

-- CreateTable
CREATE TABLE "enrollment_tokens" (
  "id" UUID NOT NULL DEFAULT gen_random_uuid(),
  "token_hash" BYTEA NOT NULL,
  "user_id" TEXT NOT NULL,
  "created_at" TIMESTAMPTZ(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,
  "expires_at" TIMESTAMPTZ(6) NOT NULL,
  "consumed_at" TIMESTAMPTZ(6),
  "consumed_device_id" UUID,

  CONSTRAINT "enrollment_tokens_pkey" PRIMARY KEY ("id")
);

-- CreateIndex
CREATE UNIQUE INDEX "enrollment_tokens_token_hash_key" ON "enrollment_tokens"("token_hash");
CREATE INDEX "enrollment_tokens_user_idx" ON "enrollment_tokens"("user_id");
CREATE INDEX "enrollment_tokens_expires_idx" ON "enrollment_tokens"("expires_at");
