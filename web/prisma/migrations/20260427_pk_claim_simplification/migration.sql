-- Add public_key to activation_codes (required at /activate/start).
-- Pre-release: drop any in-flight activation rows (no pubkey yet) instead of backfilling.
DELETE FROM "activation_codes";
ALTER TABLE "activation_codes" ADD COLUMN "public_key" BYTEA NOT NULL;

-- Tighten devices.public_key: pre-release, drop any rows with NULL pubkey
-- (orphaned activations that never completed) and require NOT NULL.
DELETE FROM "devices" WHERE "public_key" IS NULL;
ALTER TABLE "devices" ALTER COLUMN "public_key" SET NOT NULL;
