-- `project_bindings.device_id` is client-chosen and unique only per user
-- (see the column's comment on `devices`), so it cannot by itself tell two
-- different users' devices apart when they happen to hold the same string.
-- `user_id` snapshots the owner at bind time, which is what lets
-- `bindLocalProject` re-point its own caller's binding across an account
-- switch while still refusing a stranger presenting the same device id.
ALTER TABLE "project_bindings" ADD COLUMN "user_id" TEXT;

-- Best-effort backfill for rows written before this column existed. A
-- `device_id` can match more than one user's device (it is unique only per
-- user), so pick one deterministically rather than leaving an existing
-- binding without an owner at all.
UPDATE "project_bindings" pb
SET "user_id" = d.user_id
FROM (
  SELECT DISTINCT ON (device_id) device_id, user_id
  FROM "devices"
  ORDER BY device_id, activated_at ASC
) d
WHERE pb.device_id = d.device_id
  AND pb."user_id" IS NULL;

-- A binding whose device row cannot be found at all (should not happen —
-- devices are revoked, never deleted) falls back to the project's own
-- account owner, so the column can always be made NOT NULL.
UPDATE "project_bindings" pb
SET "user_id" = pa.user_id
FROM "projects" p
JOIN "product_accounts" pa ON pa.id = p.account_id
WHERE pb.project_id = p.id
  AND pb."user_id" IS NULL;

ALTER TABLE "project_bindings" ALTER COLUMN "user_id" SET NOT NULL;
