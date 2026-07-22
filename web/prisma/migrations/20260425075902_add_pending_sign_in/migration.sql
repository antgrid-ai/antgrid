-- CreateTable
CREATE TABLE "pending_sign_in" (
    "id" UUID NOT NULL DEFAULT gen_random_uuid(),
    "email" TEXT NOT NULL,
    "nonce_hash" BYTEA NOT NULL,
    "browser_token_hash" BYTEA NOT NULL,
    "requester_ua" TEXT,
    "requester_ip" TEXT,
    "approved_at" TIMESTAMPTZ(6),
    "approved_user_id" TEXT,
    "consumed_at" TIMESTAMPTZ(6),
    "expires_at" TIMESTAMPTZ(6) NOT NULL,
    "created_at" TIMESTAMPTZ(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "pending_sign_in_pkey" PRIMARY KEY ("id")
);

-- CreateIndex
CREATE INDEX "pending_sign_in_expires_idx" ON "pending_sign_in"("expires_at");

ALTER TABLE "pending_sign_in" ADD CONSTRAINT pending_sign_in_email_check
  CHECK (length(email) > 0 AND length(email) <= 320);
