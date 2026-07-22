ALTER TABLE "devices"
  ADD COLUMN "mobile_access_enabled" BOOLEAN NOT NULL DEFAULT FALSE,
  ADD COLUMN "relay_url" TEXT NULL;

CREATE INDEX "device_user_mobile_idx"
  ON "devices" ("user_id", "mobile_access_enabled");
