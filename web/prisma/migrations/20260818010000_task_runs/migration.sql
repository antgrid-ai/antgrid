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
CREATE UNIQUE INDEX "task_runs_device_session_key" ON "task_runs"("device_id", "session_id");

CREATE INDEX "task_runs_task_started_idx" ON "task_runs"("task_id", "started_at");
