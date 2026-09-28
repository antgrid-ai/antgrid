-- A failed `webhook_events` row was reclaimed on the very next drain pass, so
-- MAX_WEBHOOK_ATTEMPTS burned in the time it takes to run a handful of passes
-- rather than over any real spread. `next_attempt_at` gives the drain the same
-- exponential-backoff lease `task_sync_ops` already uses for the outbox.
ALTER TABLE "webhook_events" ADD COLUMN "next_attempt_at" TIMESTAMPTZ(6) NOT NULL DEFAULT now();
