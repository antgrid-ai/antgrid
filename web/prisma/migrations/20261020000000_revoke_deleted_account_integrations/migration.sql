-- Accounts deleted before deleteUserAccount erased integrations kept them
-- live: the webhook drain, the reconcile poll and the push outbox all route
-- through `revoked_at IS NULL`, so those accounts went on importing issues.
-- Revoking rather than deleting: the uninstall on GitHub's side never ran for
-- them, and a revoked row is what makes a later install by another account on
-- the same organization safe to route.
UPDATE "integrations" AS i
SET "revoked_at" = now(), "status" = 'revoked'
FROM "product_accounts" AS a
WHERE i."account_id" = a."id"
  AND a."deleted_at" IS NOT NULL
  AND i."revoked_at" IS NULL;
