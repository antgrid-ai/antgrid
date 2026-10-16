-- Provider identities: a provider user seen on one integration, and the account
-- member it resolves to when there is one. Additive: one new table.
--
-- Better-Auth's `account` row stores the provider's numeric user id in
-- `account_id` and never the login, so an inbound assignee is unmatchable
-- without this table. Explicit ON UPDATE CASCADE on both keys for the same
-- reason as the integrations migration: Prisma's implicit onUpdate is Cascade,
-- and omitting the clause makes the next `migrate dev` emit a spurious
-- DropForeignKey/AddForeignKey pair.
CREATE TABLE "integration_identities" (
    "id" UUID NOT NULL DEFAULT gen_random_uuid(),
    "integration_id" UUID NOT NULL REFERENCES "integrations"("id") ON DELETE CASCADE ON UPDATE CASCADE,
    -- NULL for a provider user who is not an Antgrid member. The row is still
    -- worth holding: the login and avatar are what the UI renders for an
    -- assignee we cannot resolve. SET NULL rather than CASCADE, so a deleted
    -- user leaves an unresolved identity rather than erasing the login an
    -- imported task still displays.
    "user_id" TEXT REFERENCES "user"("id") ON DELETE SET NULL ON UPDATE CASCADE,
    "provider" TEXT NOT NULL,
    -- The provider's own stable user id. `external_login` is renameable and is
    -- display only — never a key, or a rename orphans every row keyed on it.
    "external_user_id" TEXT NOT NULL,
    "external_login" TEXT NOT NULL,
    "avatar_url" TEXT,
    -- When user_id was resolved. Resolution is one-way: nothing on the inbound
    -- path clears a link, so this is never reset to NULL.
    "linked_at" TIMESTAMPTZ(6),
    "created_at" TIMESTAMPTZ(6) NOT NULL DEFAULT now(),
    "updated_at" TIMESTAMPTZ(6) NOT NULL DEFAULT now(),

    CONSTRAINT "integration_identities_pkey" PRIMARY KEY ("id")
);

-- Scoped to the integration, deliberately NOT to (provider, external_user_id).
-- Two Antgrid accounts can each hold issues assigned to the same GitHub user;
-- one globally-unique row carrying a user_id would resolve that GitHub user
-- into a member of whichever account wrote the row first — the same
-- cross-tenant mis-assignment integrations_provider_installation_key exists to
-- prevent for routing, arriving through identity instead. integration_id is
-- account-scoped, so the row is per-tenant by construction; the cost is one row
-- per account per provider user.
CREATE UNIQUE INDEX "integration_identities_integration_external_key"
  ON "integration_identities"("integration_id", "external_user_id");

-- The read that renders an integration's resolved members, and the one the
-- inbound resolver uses to skip identities it has already linked.
CREATE INDEX "integration_identities_integration_user_idx"
  ON "integration_identities"("integration_id", "user_id");
