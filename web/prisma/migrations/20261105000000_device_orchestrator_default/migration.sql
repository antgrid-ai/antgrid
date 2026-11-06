-- Agent machines are orchestrators unless their owner turns it off, and that
-- applies to machines registered under the earlier default too. Bus reach is
-- one local switch on each machine, so no account-held control grant remains.
ALTER TABLE "devices"
  ALTER COLUMN "orchestrator" SET DEFAULT TRUE,
  DROP COLUMN "bus_control";

UPDATE "devices" SET "orchestrator" = TRUE
  WHERE "kind" = 'agent' AND "revoked_at" IS NULL;
