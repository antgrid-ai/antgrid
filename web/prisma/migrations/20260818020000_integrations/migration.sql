-- Integrations: a provider account connected to an Antgrid account, and the
-- repositories inside it with the per-repo consents that decide what crosses
-- the seam. Additive: two new tables, one foreign key on a column that already
-- exists and that nothing writes yet, and three widening changes to
-- `webhook_events`.
--
-- Every foreign key carries an explicit ON UPDATE CASCADE. Prisma's implicit
-- onUpdate is Cascade for both required and optional relations, so omitting the
-- clause here (-> Postgres NO ACTION) makes the next `migrate dev` emit a
-- spurious DropForeignKey/AddForeignKey pair. Same trap as tasks_core.
CREATE TABLE "integrations" (
    "id" UUID NOT NULL DEFAULT gen_random_uuid(),
    -- ON DELETE CASCADE is not the cleanup path for a deleted account:
    -- deleteUserAccount tombstones `product_accounts.deleted_at` and never
    -- deletes the row, so this cannot fire for it. Erasing a tombstoned
    -- account's integrations needs explicit deletes, exactly as tasks do.
    "account_id" UUID NOT NULL REFERENCES "product_accounts"("id") ON DELETE CASCADE ON UPDATE CASCADE,
    "provider" TEXT NOT NULL,
    -- The provider account the App was installed ON. Display and install-flow
    -- only — unique only within one Antgrid account, so it can never route an
    -- inbound delivery. See installation_id.
    "external_account_id" TEXT NOT NULL,
    -- The only key an inbound webhook may be resolved by. A delivery carries no
    -- account_id, so the routing lookup has nothing to scope by, and the
    -- account-scoped unique below is therefore unscoped by construction: two
    -- accounts may hold one external_account_id (A uninstalls with revoked_at
    -- set and the row retained, B then installs on the same org), and resolving
    -- through it writes a third party's issue bodies into the wrong tenant.
    -- Nullable for providers with no install concept; NULLs are distinct in a
    -- Postgres unique index, so the global unique costs them nothing.
    "installation_id" TEXT,
    "display_name" TEXT NOT NULL,
    -- active | suspended | revoked. A suspension lifts; revoked_at never does.
    "status" TEXT NOT NULL,
    -- ON DELETE RESTRICT, not Cascade: the integration belongs to the account
    -- and not to whoever clicked install, so a genuine user-row delete must fail
    -- loudly rather than silently disconnect the team's repositories.
    -- (deleteUserAccount scrubs the user row and never deletes it, so in
    -- practice this fires for nothing today.)
    "installed_by" TEXT NOT NULL REFERENCES "user"("id") ON DELETE RESTRICT ON UPDATE CASCADE,
    "created_at" TIMESTAMPTZ(6) NOT NULL DEFAULT now(),
    -- Set on uninstall and never cleared: a reinstall mints a new installation
    -- id, so it is a new row rather than a resurrected one.
    "revoked_at" TIMESTAMPTZ(6),

    CONSTRAINT "integrations_pkey" PRIMARY KEY ("id")
);

-- Identity within one account: what the install flow upserts on, and what the
-- UI lists. Never an inbound routing key.
CREATE UNIQUE INDEX "integrations_account_provider_external_key"
  ON "integrations"("account_id", "provider", "external_account_id");

-- The globally-unique inbound key. This index is the constraint that makes
-- cross-tenant mis-routing impossible rather than merely unlikely; every
-- resolution through it also filters revoked_at IS NULL, which is code
-- (models/integration.ts resolveInstallation) and not something an index can
-- hold.
CREATE UNIQUE INDEX "integrations_provider_installation_key"
  ON "integrations"("provider", "installation_id");

CREATE TABLE "integration_repos" (
    "id" UUID NOT NULL DEFAULT gen_random_uuid(),
    "integration_id" UUID NOT NULL REFERENCES "integrations"("id") ON DELETE CASCADE ON UPDATE CASCADE,
    -- The same normalized form as projects.repo_key (bridge/src/repo-key.ts,
    -- shape-gated by web's util/repo-key.ts). Reusing it is the whole mechanism
    -- by which a provider repository and a checkout on a machine resolve to one
    -- project; a second normalization would give two strings for one repository
    -- and the join would silently never match.
    "repo_key" TEXT NOT NULL,
    -- The provider's own repo id, stable across a rename — which is why it, and
    -- not repo_key, is the upsert key.
    "external_repo_id" TEXT NOT NULL,
    -- SET NULL rather than CASCADE: the link to a local checkout is a
    -- convenience, and deleting the project must not tear down the import that
    -- populated it.
    "project_id" UUID REFERENCES "projects"("id") ON DELETE SET NULL ON UPDATE CASCADE,
    -- public | private, and MUTABLE. It backs the "public if the repo is" line
    -- in the publish consent UI, so a private -> public transition
    -- retroactively exposes every issue published under the opposite assurance.
    "visibility" TEXT NOT NULL,

    "sync_enabled" BOOLEAN NOT NULL,
    -- Outbound writes, opt-in per repository and deliberately not implied by
    -- sync_enabled. The first integration is a one-way read-only import and
    -- users treat imported issues as a private notes layer; turning outbound
    -- writes on later changes the meaning of a link already accepted.
    "push_enabled" BOOLEAN NOT NULL DEFAULT false,
    "publish_new_by_default" BOOLEAN NOT NULL DEFAULT false,

    -- all | label | milestone | assigned_to_member. Unfiltered, a busy
    -- repository turns the account list into a mirror and buries the Running
    -- view in issues we imported on purpose.
    "import_filter_kind" TEXT NOT NULL DEFAULT 'all',
    "import_filter_value" TEXT,
    -- One provider page. Uncapped, a large repository is ~50k requests and
    -- roughly ten hours of primary rate budget; one page bounds it at one
    -- request per issue. A column rather than a constant because a constant
    -- cannot be raised for the one repository that needs it.
    "comment_import_cap" INTEGER NOT NULL DEFAULT 100,

    "last_full_sync_at" TIMESTAMPTZ(6),
    "last_cursor" TEXT,
    -- The conditional-request validator the next reconcile sends back as
    -- If-None-Match, which is what makes the poll cheap.
    "etag" TEXT,

    "created_at" TIMESTAMPTZ(6) NOT NULL DEFAULT now(),
    "updated_at" TIMESTAMPTZ(6) NOT NULL DEFAULT now(),

    CONSTRAINT "integration_repos_pkey" PRIMARY KEY ("id")
);

-- The filter vocabulary and its pairing with the value, in both directions:
-- `all` and `assigned_to_member` name no value, `label` and `milestone` are
-- meaningless without one. Prisma models neither a CHECK nor a partial index and
-- is blind to both on introspection, so nothing in schema.prisma declares this —
-- same convention as tasks_assignee_one_identity_check.
ALTER TABLE "integration_repos" ADD CONSTRAINT "integration_repos_import_filter_check"
  CHECK (
    ("import_filter_kind" IN ('all', 'assigned_to_member') AND "import_filter_value" IS NULL)
    OR ("import_filter_kind" IN ('label', 'milestone') AND "import_filter_value" IS NOT NULL)
  );

-- Both uniques are scoped to the integration, not global: one repository can
-- legitimately be connected by two different Antgrid accounts.
CREATE UNIQUE INDEX "integration_repos_integration_repo_key"
  ON "integration_repos"("integration_id", "repo_key");
CREATE UNIQUE INDEX "integration_repos_integration_external_key"
  ON "integration_repos"("integration_id", "external_repo_id");

-- tasks.integration_repo_id shipped in tasks_core with no reference, because
-- the table it points at did not exist yet. The key enforces EXISTENCE and
-- never tenancy — another account's repo id satisfies it perfectly — so callers
-- still re-resolve a supplied id under their own account_id before writing it.
-- SET NULL: unlinking a repository must not delete the tasks imported through
-- it, which keep their external identity columns.
ALTER TABLE "tasks" ADD CONSTRAINT "tasks_integration_repo_id_fkey"
  FOREIGN KEY ("integration_repo_id") REFERENCES "integration_repos"("id")
  ON DELETE SET NULL ON UPDATE CASCADE;

-- `webhook_events` was built for the two billing gateways and is about to
-- absorb a second kind of traffic. Three corrections, all widening.

-- The unique was on provider_event_id ALONE: one global id namespace shared by
-- every provider, in which one provider's delivery id can swallow another's as
-- a duplicate — and a swallowed delivery is never retried. Widening it to
-- (provider, provider_event_id) cannot fail on live data: every existing row
-- already satisfies the composite, because a set unique on its second column is
-- unique on any pair containing it.
DROP INDEX "webhook_events_provider_event_id_key";
CREATE UNIQUE INDEX "webhook_events_provider_event_key"
  ON "webhook_events"("provider", "provider_event_id");

-- Billing inserts its dedup row inside the effect's own transaction and stamps
-- processed_at at insert, so it never has an unprocessed state and never needed
-- these. A provider whose payloads are too large to merge on the request path
-- inserts first and drains later, which is a genuinely retryable state and
-- needs somewhere to record why a row keeps failing.
ALTER TABLE "webhook_events" ADD COLUMN "attempts" INTEGER NOT NULL DEFAULT 0;
ALTER TABLE "webhook_events" ADD COLUMN "last_error" TEXT;

-- The drain reads WHERE provider = ? AND processed_at IS NULL. The table had
-- exactly one non-PK index and is on course to become the largest in the
-- database, so that read starts as a sequential scan without this.
CREATE INDEX "webhook_events_provider_processed_idx"
  ON "webhook_events"("provider", "processed_at");
