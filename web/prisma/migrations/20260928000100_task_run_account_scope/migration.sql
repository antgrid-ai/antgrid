-- `task_runs_device_session_key` was global over `(device_id, session_id)`,
-- but `device_id` is client-chosen and unique only per user (see the column's
-- comment) — so two different ACCOUNTS could present the same pair. Scoping
-- the uniqueness by `account_id` removes the collision surface entirely
-- instead of relying on the model's own tenancy check to catch it after the
-- fact.
ALTER TABLE "task_runs" ADD COLUMN "account_id" UUID;

UPDATE "task_runs" tr
SET "account_id" = t.account_id
FROM "tasks" t
WHERE tr.task_id = t.id
  AND tr."account_id" IS NULL;

ALTER TABLE "task_runs" ALTER COLUMN "account_id" SET NOT NULL;

DROP INDEX "task_runs_device_session_key";
CREATE UNIQUE INDEX "task_runs_account_device_session_key"
  ON "task_runs" ("account_id", "device_id", "session_id");
