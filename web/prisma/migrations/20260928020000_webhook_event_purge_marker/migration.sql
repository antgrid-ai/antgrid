-- `payload_purged_at` is the purge's own working-set marker: comparing
-- `payload` to the purge marker directly is not index-served and only gets
-- slower as retention keeps more already-purged rows below its cutoff.
ALTER TABLE "webhook_events" ADD COLUMN "payload_purged_at" TIMESTAMPTZ(6);

-- Rows already carrying the `payload` purge marker are already-purged work;
-- stamp them so the new column finds nothing left to do for them.
UPDATE "webhook_events"
SET "payload_purged_at" = "processed_at"
WHERE "payload" = '{"purged":true}'::jsonb
  AND "payload_purged_at" IS NULL;

CREATE INDEX "webhook_events_provider_purge_idx"
  ON "webhook_events" ("provider", "payload_purged_at", "processed_at");
