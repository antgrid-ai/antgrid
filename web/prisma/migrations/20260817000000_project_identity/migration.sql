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
