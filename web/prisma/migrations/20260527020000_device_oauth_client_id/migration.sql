-- Add oauth_client_id to devices for Better-Auth OAuth Provider link
ALTER TABLE "devices" ADD COLUMN "oauth_client_id" TEXT;
CREATE UNIQUE INDEX "devices_oauth_client_id_key" ON "devices"("oauth_client_id");

-- Drop legacy enrollment_tokens table (replaced by Better-Auth OAuth device flow)
DROP TABLE "enrollment_tokens";

-- Drop legacy device_tokens table (replaced by Better-Auth OAuth access/refresh tokens)
ALTER TABLE "device_tokens" DROP CONSTRAINT IF EXISTS "device_tokens_device_id_fkey";
DROP TABLE "device_tokens";
