-- Tasks and integrations, squashed from the thirteen migrations this feature
-- accumulated before it shipped (project_identity through
-- revoke_deleted_account_integrations). Nothing had been deployed, so the
-- ALTERs are folded into their CREATEs and the backfills and data fixes, which
-- had no rows to act on, are gone.
--
-- Every foreign key carries an explicit ON UPDATE CASCADE. Prisma's implicit
-- onUpdate is Cascade, so omitting the clause (-> Postgres NO ACTION) makes the
-- next `migrate dev` emit a spurious DropForeignKey/AddForeignKey pair. Same
-- trap as account_members.
--
-- ON DELETE CASCADE on `account_id` is not the cleanup path for a deleted
-- account: deleteUserAccount tombstones `product_accounts.deleted_at` and never
-- deletes the row, so those FKs cannot fire for it. Erasing a tombstoned
-- account's projects, tasks and integrations needs explicit deletes.

-- Repository identity: a project is a REPOSITORY, addressed by its normalized
-- origin remote, and a binding is where that repository sits on one machine.
-- Splitting the two is what lets work follow a repository across a folder move
-- and between machines; folding the path onto `projects` would make the second
-- machine's checkout a second repository.
--
-- Both foreign keys carry an explicit ON UPDATE CASCADE. Prisma's implicit
-- onUpdate for a required relation is Cascade, so omitting the clause here
-- (→ Postgres NO ACTION) makes the next `migrate dev` emit a spurious
-- DropForeignKey/AddForeignKey pair. Same trap as account_members.
--
-- ON DELETE CASCADE on `account_id` is not the cleanup path for a deleted
-- account: deleteUserAccount tombstones `product_accounts.deleted_at` and never
-- deletes the row, so this FK cannot fire for it. It covers a genuine account
-- row deletion only; erasing a tombstoned account's projects needs explicit
-- deletes, exactly as account_members needs an explicit membership close.
CREATE TABLE "projects" (
    "id" UUID NOT NULL DEFAULT gen_random_uuid(),
    "account_id" UUID NOT NULL REFERENCES "product_accounts"("id") ON DELETE CASCADE ON UPDATE CASCADE,
    "repo_key" TEXT NOT NULL,
    "display_name" TEXT NOT NULL,
    "created_at" TIMESTAMPTZ(6) NOT NULL DEFAULT now(),
    "updated_at" TIMESTAMPTZ(6) NOT NULL DEFAULT now(),

    CONSTRAINT "projects_pkey" PRIMARY KEY ("id")
);

-- One row per repository per account, which is also the index the binding
-- upsert's resolve-or-create resolves against.
CREATE UNIQUE INDEX "projects_account_repo_key" ON "projects"("account_id", "repo_key");

-- `device_id` is `devices.device_id`, not `devices.id`, and carries no foreign
-- key on purpose: that column is unique only per user
-- (devices_user_id_device_id_key), so there is no global key to reference. The
-- binding route proves the device instead, by scoping to the caller's user_id.
CREATE TABLE "project_bindings" (
    "id" UUID NOT NULL DEFAULT gen_random_uuid(),
    "project_id" UUID NOT NULL REFERENCES "projects"("id") ON DELETE CASCADE ON UPDATE CASCADE,
    "device_id" TEXT NOT NULL,
    "local_project_id" TEXT NOT NULL,
    "local_path" TEXT NOT NULL,
    -- Owner snapshot taken at bind time. `device_id` is client-chosen and unique
    -- only per user, so it cannot by itself tell two users' devices apart when
    -- they hold the same string. This is what lets `bindLocalProject` re-point
    -- its own caller's binding across an account switch while still refusing a
    -- stranger presenting the same device id.
    "user_id" TEXT NOT NULL,
    "last_seen_at" TIMESTAMPTZ(6),

    CONSTRAINT "project_bindings_pkey" PRIMARY KEY ("id")
);

-- One binding per folder per machine. Note this is NOT account-scoped and cannot
-- be: a device uuid is client-chosen at registration and unique only per user,
-- so two accounts can name the same (device_id, local_project_id) pair. The
-- binding upsert therefore refuses a pair already held by another account rather
-- than re-pointing it (see models/project.ts).
CREATE UNIQUE INDEX "project_bindings_device_local_key" ON "project_bindings"("device_id", "local_project_id");

CREATE INDEX "project_bindings_project_idx" ON "project_bindings"("project_id");

-- Tasks core: an account-owned unit of work, its comments, and the label
-- vocabulary they are triaged by. Everything here is usable with no integration
-- at all; the external/sync columns on `tasks` ship now because they are part of
-- the row's shape and a later migration to bolt them on is pure churn.
--
-- Every foreign key carries an explicit ON UPDATE CASCADE. Prisma's implicit
-- onUpdate is Cascade for both required and optional relations, so omitting the
-- clause here (-> Postgres NO ACTION) makes the next `migrate dev` emit a
-- spurious DropForeignKey/AddForeignKey pair. Same trap as account_members.
--
-- ON DELETE CASCADE on `account_id` is not the cleanup path for a deleted
-- account: deleteUserAccount tombstones `product_accounts.deleted_at` and never
-- deletes the row, so this FK cannot fire for it. Erasing a tombstoned account's
-- tasks needs explicit deletes, and task bodies are exactly the private text the
-- trust posture is written about.
CREATE TABLE "tasks" (
    "id" UUID NOT NULL DEFAULT gen_random_uuid(),
    "account_id" UUID NOT NULL REFERENCES "product_accounts"("id") ON DELETE CASCADE ON UPDATE CASCADE,
    -- A task filed against no repository is ordinary (an idea, a chore), and a
    -- deleted project must not take its tasks with it.
    "project_id" UUID REFERENCES "projects"("id") ON DELETE SET NULL ON UPDATE CASCADE,
    -- Per-account display id (ANT-14). Allocated under
    -- pg_advisory_xact_lock(hashtext('task:' || account_id)) in models/task.ts,
    -- and never reused: reissuing a soft-deleted task's number would silently
    -- re-point a URL somebody already has.
    "number" INTEGER NOT NULL,
    "title" TEXT NOT NULL,
    "body" TEXT NOT NULL DEFAULT '',
    -- Antgrid vocabulary: open | in_progress | blocked | done | cancelled.
    -- Never a provider passthrough — GitHub can represent neither in_progress
    -- nor blocked, which is why the mapping lives at the seam (src/tasks/merge.ts).
    "status" TEXT NOT NULL,
    "priority" INTEGER,
    -- Fractional index: a lexicographic midpoint between neighbours, so a drag
    -- reorder is one row write and never a renumber.
    "sort_key" TEXT NOT NULL,
    -- Which system the task was born in. Never changes, and is NOT the same
    -- question as whether it currently has an external link.
    "source" TEXT NOT NULL DEFAULT 'local',

    -- `devices.device_id`, not `devices.id`, and FK-less for the same reason as
    -- project_bindings.device_id: that column is unique only per user, so there
    -- is no global key to reference.
    "run_target_device_id" TEXT,
    "run_target_project_id" UUID REFERENCES "projects"("id") ON DELETE SET NULL ON UPDATE CASCADE,

    -- Exactly one assignee identity. `assignee_login`/`assignee_avatar_url` are a
    -- read-only snapshot of a provider identity that maps to no member, so they
    -- mean nothing without `assignee_external_id`.
    "assignee_user_id" TEXT REFERENCES "user"("id") ON DELETE SET NULL ON UPDATE CASCADE,
    "assignee_external_id" TEXT,
    "assignee_login" TEXT,
    "assignee_avatar_url" TEXT,

    -- Which repo of the installation the issue lives in. No foreign key yet:
    -- `integration_repos` arrives with the GitHub App phase, and the reference is
    -- one ALTER at that point. Nothing writes this column before then.
    "integration_repo_id" UUID,
    "external_provider" TEXT,
    "external_id" TEXT,
    "external_key" TEXT,
    "external_url" TEXT,
    -- The last state both sides agreed on, in PROVIDER space.
    "remote_snapshot" JSONB,
    -- The local value that lost a conflict. Without it, "remote wins but we keep
    -- your edit" is silent data loss.
    "local_conflict" JSONB,
    -- Content hash of the field set we last pushed: echo suppression keys on what
    -- we wrote, never on when.
    "pushed_hash" TEXT,
    "remote_updated_at" TIMESTAMPTZ(6),
    "synced_at" TIMESTAMPTZ(6),
    -- null until linked: pending | synced | conflict | unlinked.
    "sync_state" TEXT,
    "sync_error" TEXT,
    -- Per-field counter of pushes that returned 200 and changed nothing:
    -- { field: { count, lastAt, reason } }. It lives on the task and not on the
    -- op because ops are superseded and replaced, so a counter there would reset
    -- every time the user edited the field again - which is precisely the loop
    -- being counted. Cleared for a field when a push of it finally takes effect.
    "push_blocked" JSONB,

    -- Restrict, not Cascade: the task belongs to the account and not to whoever
    -- typed it, so a genuine user-row delete must fail loudly rather than take
    -- the account's archive with it. (deleteUserAccount scrubs the user row and
    -- never deletes it, so in practice this fires for nothing today.)
    "created_by" TEXT NOT NULL REFERENCES "user"("id") ON DELETE RESTRICT ON UPDATE CASCADE,
    "created_at" TIMESTAMPTZ(6) NOT NULL DEFAULT now(),
    "updated_at" TIMESTAMPTZ(6) NOT NULL DEFAULT now(),
    "closed_at" TIMESTAMPTZ(6),
    "deleted_at" TIMESTAMPTZ(6),

    CONSTRAINT "tasks_pkey" PRIMARY KEY ("id")
);

-- The two identities are alternatives, not a pair. Nothing but this constraint
-- stands between a half-applied assignee write and a row whose member assignee
-- and provider snapshot disagree forever, and the disagreement is invisible in
-- every read that selects only one of them.
ALTER TABLE "tasks" ADD CONSTRAINT "tasks_assignee_one_identity_check"
  CHECK ("assignee_user_id" IS NULL OR "assignee_external_id" IS NULL);

-- The API addresses a task as `/tasks/ANT-14`, so this is a small sequential
-- key: any where-clause missing account_id is immediately enumerable rather
-- than theoretically exploitable.
CREATE UNIQUE INDEX "tasks_account_number_key" ON "tasks"("account_id", "number");

-- The whole inbound idempotency mechanism: every inbound path is an upsert on
-- this key. It constrains nothing for local tasks, because all three columns are
-- null and NULL != NULL — which is correct here, unlike the label case below: an
-- unlinked task has no external identity to collide with, whereas two
-- account-wide labels named `bug` genuinely do.
CREATE UNIQUE INDEX "tasks_account_external_key"
  ON "tasks"("account_id", "external_provider", "external_id");

CREATE INDEX "tasks_account_status_idx" ON "tasks"("account_id", "status");
CREATE INDEX "tasks_account_project_status_idx" ON "tasks"("account_id", "project_id", "status");
-- "Assigned to me" still anchors on account_id first: without it the view
-- returns a former employer's tasks the moment a membership closes.
CREATE INDEX "tasks_account_assignee_status_idx" ON "tasks"("account_id", "assignee_user_id", "status");
CREATE INDEX "tasks_account_sort_idx" ON "tasks"("account_id", "sort_key");

CREATE TABLE "task_comments" (
    "id" UUID NOT NULL DEFAULT gen_random_uuid(),
    "task_id" UUID NOT NULL REFERENCES "tasks"("id") ON DELETE CASCADE ON UPDATE CASCADE,
    "author_user_id" TEXT REFERENCES "user"("id") ON DELETE SET NULL ON UPDATE CASCADE,
    -- Snapshot of a provider author that maps to no member.
    "author_external_login" TEXT,
    "body" TEXT NOT NULL,
    "external_id" TEXT,
    "created_at" TIMESTAMPTZ(6) NOT NULL DEFAULT now(),
    "updated_at" TIMESTAMPTZ(6) NOT NULL DEFAULT now(),
    "deleted_at" TIMESTAMPTZ(6),

    CONSTRAINT "task_comments_pkey" PRIMARY KEY ("id")
);

-- What makes a re-import idempotent, which is the stated reason external_id
-- exists at all. Nulls are distinct, so comments written in Antgrid — the only
-- kind v1 creates — are unconstrained by it.
CREATE UNIQUE INDEX "task_comments_task_external_key" ON "task_comments"("task_id", "external_id");
CREATE INDEX "task_comments_task_created_idx" ON "task_comments"("task_id", "created_at");

CREATE TABLE "labels" (
    "id" UUID NOT NULL DEFAULT gen_random_uuid(),
    "account_id" UUID NOT NULL REFERENCES "product_accounts"("id") ON DELETE CASCADE ON UPDATE CASCADE,
    -- Cascade rather than SET NULL: a repo-scoped label means nothing without
    -- its project, and orphaning it into the account-wide namespace would
    -- collide with labels_account_name_unscoped_idx — turning a project delete
    -- into a unique violation.
    "project_id" UUID REFERENCES "projects"("id") ON DELETE CASCADE ON UPDATE CASCADE,
    -- CITEXT, matching `user.email` and `account_invites.email`. Plain text is
    -- case-SENSITIVE, so `Bug` and `bug` would become two local rows mapping to
    -- one provider label and the element-wise label merge would oscillate
    -- between them forever. The extension is installed by the init migration.
    "name" CITEXT NOT NULL,
    -- Six hex digits, no leading '#', stored verbatim so the round-trip to the
    -- provider is exact.
    "color" TEXT NOT NULL,
    "description" TEXT,
    "created_at" TIMESTAMPTZ(6) NOT NULL DEFAULT now(),

    CONSTRAINT "labels_pkey" PRIMARY KEY ("id")
);

-- Covers project-scoped labels only.
CREATE UNIQUE INDEX "labels_account_project_name_key" ON "labels"("account_id", "project_id", "name");

-- The index above does NOT constrain account-wide labels: `project_id` is
-- nullable and NULL != NULL in Postgres, so it permits unlimited duplicate
-- ('acct', NULL, 'needs-triage') rows. This partial index is the half that
-- reaches them.
--
-- PARTIAL index. Prisma cannot model one and is blind to it on introspection —
-- same convention and same reason as account_invites_one_pending_per_email_idx,
-- so there is deliberately no `@@unique` for it in schema.prisma. Declaring one
-- would make every `migrate dev` try to create a conflicting plain index.
CREATE UNIQUE INDEX "labels_account_name_unscoped_idx"
  ON "labels"("account_id", "name") WHERE "project_id" IS NULL;

-- Rows rather than an array column on `tasks`, because the label merge is
-- element-wise and needs the elements addressable.
CREATE TABLE "task_labels" (
    "task_id" UUID NOT NULL REFERENCES "tasks"("id") ON DELETE CASCADE ON UPDATE CASCADE,
    "label_id" UUID NOT NULL REFERENCES "labels"("id") ON DELETE CASCADE ON UPDATE CASCADE,

    CONSTRAINT "task_labels_pkey" PRIMARY KEY ("task_id", "label_id")
);

CREATE INDEX "task_labels_label_idx" ON "task_labels"("label_id");

-- Task runs: the join between a task and a real agent session. Additive — it
-- touches no existing table beyond referencing `tasks`.
--
-- The row never leaves Antgrid. No provider has anywhere to put it, and it is
-- the record that makes a task a launchable unit of work rather than an issue
-- copied out of a tracker.
--
-- The foreign key carries an explicit ON UPDATE CASCADE for the same reason as
-- the tasks_core migration: Prisma's implicit onUpdate is Cascade, so omitting
-- it here (-> Postgres NO ACTION) makes the next `migrate dev` emit a spurious
-- DropForeignKey/AddForeignKey pair.
CREATE TABLE "task_runs" (
    "id" UUID NOT NULL DEFAULT gen_random_uuid(),
    -- ON DELETE CASCADE is the right cleanup here, unlike on tasks.account_id:
    -- a task's soft delete leaves the row in place, so this only fires for a
    -- genuine hard delete, and a run of a task that no longer exists is
    -- unreadable by construction.
    "task_id" UUID NOT NULL REFERENCES "tasks"("id") ON DELETE CASCADE ON UPDATE CASCADE,
    -- Part of the session uniqueness below: `device_id` is client-chosen and
    -- unique only per user, so two different ACCOUNTS could present the same
    -- (device_id, session_id) pair. Scoping by account removes the collision
    -- surface instead of relying on the model's tenancy check to catch it.
    "account_id" UUID NOT NULL,

    -- `devices.device_id`, not `devices.id`, and FK-less for the same reason as
    -- project_bindings.device_id and tasks.run_target_device_id: that column is
    -- unique only per user, so there is no global key to reference. Tenancy is
    -- proven at the route, which takes this from the caller's verified token.
    "device_id" TEXT NOT NULL,
    -- `computeProjectId` on the reporting machine — sha256 of a realpath, so it
    -- means nothing on any other machine and there is nothing account-scoped to
    -- resolve it against. Stored verbatim.
    "local_project_id" TEXT NOT NULL,
    "session_id" TEXT NOT NULL,
    "checkout_id" TEXT,
    "tool" TEXT,
    -- The bridge's per-session `WorkStatus` verbatim: working | attention |
    -- error | done. Deliberately NOT the task vocabulary — this tracks liveness,
    -- and its `done` means only that no turn is open (bridge/src/work-status.ts),
    -- which a freshly-opened chat reports too.
    "status" TEXT NOT NULL,
    -- Recorded, never parsed back: the branch name is a lossy slug of the
    -- session name plus an arbitrary suffix, and the user may rename it.
    "branch" TEXT,
    "pr_url" TEXT,

    "started_at" TIMESTAMPTZ(6) NOT NULL DEFAULT now(),
    "ended_at" TIMESTAMPTZ(6),
    -- VARCHAR(200) is a TRUST BOUNDARY, not a display choice. Agent output,
    -- diffs and transcripts are forbidden in task text, and a cap the column
    -- enforces is enforceable where a rule stated in a design doc is not.
    "result_summary" VARCHAR(200),

    CONSTRAINT "task_runs_pkey" PRIMARY KEY ("id")
);

-- A run is identified by the session it is attached to, and the bridge reports
-- the same session repeatedly as its status changes — so this is what makes
-- those reports an upsert rather than a row per advert. The machine is part of
-- the key because a session id is minted per bridge with no global registry.
CREATE UNIQUE INDEX "task_runs_account_device_session_key"
  ON "task_runs"("account_id", "device_id", "session_id");

CREATE INDEX "task_runs_task_started_idx" ON "task_runs"("task_id", "started_at");

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
    "dismissed_at" TIMESTAMPTZ(6),

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
    -- Set when GitHub removes the repository from the installation or deletes it.
    -- Both flip `sync_enabled` off, which is otherwise indistinguishable from the
    -- user turning the toggle off. NULL means "still in the installation".
    "removed_at" TIMESTAMPTZ(6),

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

-- Exponential-backoff lease for the drain, the same one `task_sync_ops` uses for
-- the outbox. Without it a failed row is reclaimed on the very next pass and
-- MAX_WEBHOOK_ATTEMPTS burns in the time it takes to run a handful of passes.
ALTER TABLE "webhook_events" ADD COLUMN "next_attempt_at" TIMESTAMPTZ(6) NOT NULL DEFAULT now();

-- The purge's own working-set marker: comparing `payload` to the purge marker
-- directly is not index-served and only gets slower as retention keeps more
-- already-purged rows below its cutoff.
ALTER TABLE "webhook_events" ADD COLUMN "payload_purged_at" TIMESTAMPTZ(6);

-- The drain reads WHERE provider = ? AND processed_at IS NULL. The table had
-- exactly one non-PK index and is on course to become the largest in the
-- database, so that read starts as a sequential scan without this.
CREATE INDEX "webhook_events_provider_processed_idx"
  ON "webhook_events"("provider", "processed_at");

CREATE INDEX "webhook_events_provider_purge_idx"
  ON "webhook_events" ("provider", "payload_purged_at", "processed_at");

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

-- The outbox: one row per pending provider write.
--
-- Local edits never call the provider inline. They write the task row and an op
-- here in the same transaction, and a drain applies them: a provider outage
-- becomes a backlog rather than a failed request, and retry/backoff has
-- somewhere to live.
--
-- Both foreign keys carry an explicit ON UPDATE CASCADE for the same reason as
-- the tasks_core migration: Prisma's implicit onUpdate is Cascade, so omitting
-- it here (-> Postgres NO ACTION) makes the next `migrate dev` emit a spurious
-- DropForeignKey/AddForeignKey pair.
CREATE TABLE "task_sync_ops" (
    "id" UUID NOT NULL DEFAULT gen_random_uuid(),
    -- ON DELETE CASCADE, like task_runs: a task's soft delete leaves the row in
    -- place (its pending ops are cancelled explicitly instead), so this only
    -- fires for a genuine hard delete, where an op naming a task that no longer
    -- exists could never be applied.
    "task_id" UUID NOT NULL REFERENCES "tasks"("id") ON DELETE CASCADE ON UPDATE CASCADE,
    -- Which installation's credentials the op must be sent with, pinned at
    -- enqueue time. A task's repo can be relinked, and an op built against the
    -- old integration must not be sent with the new one's token.
    "integration_id" UUID NOT NULL REFERENCES "integrations"("id") ON DELETE CASCADE ON UPDATE CASCADE,
    -- Denormalized from the integration so the drain can pick an adapter
    -- without a join, and so a claimed op is self-describing in a log line.
    "provider" TEXT NOT NULL,
    -- A closed vocabulary, enumerated in src/tasks/sync-op.ts:
    -- issue.create | issue.patch.title | issue.patch.body | issue.state |
    -- issue.labels. Three rules are written in terms of it — supersede matches
    -- on it, `seq` orders within it, and "never replay an array-valued PATCH"
    -- selects on it — and none of the three is implementable against a
    -- free-form string.
    "kind" TEXT NOT NULL,
    "payload" JSONB NOT NULL,
    -- Random 128 bits, minted per op. It is the marker embedded in a created
    -- issue's body and therefore the only guard against a public double-post,
    -- so it is neither a hash of the payload (two legitimately identical edits
    -- would collide) nor a per-account counter (which would leak how much a
    -- customer writes into a public issue body).
    "op_key" TEXT NOT NULL,
    -- Per task and meaningless across tasks: the order the provider must see
    -- this task's writes in. Claiming globally by `next_attempt_at` reorders
    -- them under backoff, which is what task_sync_ops_task_seq_idx exists to
    -- let the claim avoid.
    "seq" INTEGER NOT NULL,
    -- Failures only. A local throttle is not a failure and must never land
    -- here, or a queue that is merely waiting drives itself into exponential
    -- backoff.
    "attempts" INTEGER NOT NULL DEFAULT 0,
    "next_attempt_at" TIMESTAMPTZ(6) NOT NULL DEFAULT now(),
    -- pending | processed | given_up | cancelled. `given_up` is terminal and
    -- deliberately not a delete: a write we abandoned is something a person has
    -- to be able to find.
    "status" TEXT NOT NULL DEFAULT 'pending',
    "last_error" TEXT,
    -- Stamped immediately BEFORE the provider call, never after: the dangerous
    -- retry is the one whose request committed and whose response was lost, and
    -- this timestamp is the `since` bound the create-resolution listing uses to
    -- find the issue we may already have posted.
    "attempted_at" TIMESTAMPTZ(6),
    "created_at" TIMESTAMPTZ(6) NOT NULL DEFAULT now(),

    CONSTRAINT "task_sync_ops_pkey" PRIMARY KEY ("id")
);

-- The marker's uniqueness, as a constraint rather than a convention: "stable
-- across retries of one op, unique across ops" is what makes a created issue
-- findable after a crash, and a convention cannot be relied on by a step whose
-- whole job is recovering from an unknown outcome.
CREATE UNIQUE INDEX "task_sync_ops_task_op_key" ON "task_sync_ops"("task_id", "op_key");

-- The drain's outer scan: everything still pending, oldest due first.
CREATE INDEX "task_sync_ops_status_next_idx" ON "task_sync_ops"("status", "next_attempt_at");

-- The ordered claim's read path — the head op of each task.
CREATE INDEX "task_sync_ops_task_seq_idx" ON "task_sync_ops"("task_id", "seq");
