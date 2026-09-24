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
