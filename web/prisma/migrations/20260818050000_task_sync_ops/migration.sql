-- The outbox: one row per pending provider write, plus the two columns on
-- `tasks` that stop a push from looping. Additive — one new table and one new
-- column.
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

-- Per-field counter of pushes that returned 200 and changed nothing:
-- { field: { count, lastAt, reason } }. It lives on the task and not on the op
-- because ops are superseded and replaced, so a counter there would reset every
-- time the user edited the field again — which is precisely the loop being
-- counted. Cleared for a field when a push of it finally takes effect.
ALTER TABLE "tasks" ADD COLUMN "push_blocked" JSONB;
