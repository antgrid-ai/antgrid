# Phase 5 gate: the five questions, answered

`docs/tasks-and-integrations-plan.md` refuses to start phase 5 until these have
written answers, on the grounds that every one is a correctness property that
cannot be retrofitted once users have linked tasks. This file is the proposed
set. Each answer says what it costs and what is still yours to confirm; nothing
here is built.

Three of the five turned out to be **already decided by what shipped in 4b–4d**
rather than open — the inbound half had to answer them to be correct, and the
outbox inherits the answer rather than choosing its own. Those are marked
*settled by the tree*. The two that are genuinely open are **1** and **4**.

---

## 1. What is the echo-suppression key, and how does it tell our own write from a third party's write we just clobbered?

**Proposed: `Task.pushedHash` = a hash of the PROVIDER-SPACE normalized field set
taken from the push RESPONSE, not from the request.** An inbound delivery is an
echo iff the same hash over its own payload is equal. Anything else is merged,
however old its timestamp.

The plan already rejects `updated_at` and gives the trace: it drops a human's
edit that our blind PATCH clobbered a second earlier, and no conflict is
recorded. Hashing content instead is the right axis. The part the plan leaves
open is *which* content, and the answer is not the obvious one:

- **Hash the response, not the request.** GitHub normalizes what it stores — line
  endings in a body, label order, `state_reason` on an issue that stayed open.
  Hash what we *sent* and the echo of our own write arrives with a different
  hash, is classified as a third party's edit, and is merged against a base that
  already equals it. Harmless, but it means the suppression never actually fires
  on the fields most likely to be normalized, which is the same as not having it.
- The response is **already** what we store as the new `remoteSnapshot`, so this
  is a hash of a value the drain holds anyway. One column, no second projection
  to keep in step.
- Provider space, for the reason `status` merges there: `toRemote` is many-to-one,
  so an Antgrid-space hash differs for two tasks GitHub cannot tell apart.

**What it does NOT do, and this is the important half.** The hash classifies what
arrives; it cannot un-clobber. In the plan's `t0→t2` trace the human's edit is
already gone from GitHub before any webhook is classified. The thing that
prevents that is the **re-fetch immediately before the push, aborting to a merge
if `remote != base`** — the plan's compare-and-swap approximation. The hash and
the re-fetch are complements: without the re-fetch we destroy the edit, without
the hash we treat our own write as a conflict against ourselves. Ship both or
neither.

**Cost and residue.** A hash equal by coincidence — a human retyping exactly the
value we pushed — is suppressed. That is correct: the states are identical, so
there is nothing to merge. `pushedHash` is not cleared after a match, so a
GitHub **redelivery** of our own echo is suppressed too, which is what we want.
It IS cleared on the next inbound merge that applies a remote change, because
after that the last thing both sides agreed on is no longer our push.

**Confirm:** that hashing the response rather than the request is acceptable
given it means the hash is only known after a successful round trip — an op whose
response was lost has no hash, and its echo is merged as a third-party write
against an equal base, which is a no-op. That is the intended degradation.

---

## 2. Where does the losing local value physically live on a conflict, and what clears it?

*Settled by the tree.* `Task.localConflict`, a JSON blob written by
`foldLocalConflict` in `web/src/integrations/github-inbound.ts`, with
`syncState = 'conflict'` beside it. It accumulates per field and is **sticky by
construction**: only an explicit UI action clears it, so a later clean delivery
cannot downgrade the row to `synced`. That stickiness is what stops phase 5 from
releasing a push over an edit nobody adjudicated — it is an outbox property that
the inbound phase had to build first.

The one piece that does not exist yet is **the verb that clears it**. There is no
route today; a task's conflict can be raised and cannot be resolved. Phase 5
needs `POST /tasks/:number/conflict/resolve` (or a `PATCH` field), taking the
per-field choice, writing the chosen value, clearing that field from the blob,
and dropping `syncState` back to `synced` only when the blob is empty. It must
take `tasksync:<taskId>` like every other read-merge-write.

**The route landed early**, ahead of phase 5 rather than in it:
`POST /tasks/:number/conflict/resolve`, one field per call, taking
`tasksync:<taskId>` like every other read-merge-write and never touching
`remoteSnapshot`. It had to — the inbound half was already raising a state that
nothing could clear, so every conflict shipped was permanent. Phase 5 inherits
it rather than building it.

**Confirm:** nothing. This one is answered, and the missing route is no longer
missing.

---

## 3. What serializes the drain against the webhook processor for one task?

*Settled by the tree.* `pg_advisory_xact_lock(hashtext('tasksync:' || taskId))`,
transaction-scoped, required of every caller by `web/src/tasks/merge.ts` and
already taken by `mergeImportedTask`. The drain takes the same lock across its
read-merge-write and **releases it before the HTTP call** — never hold a
transaction open across a GitHub round trip.

Two constraints on the phase-5 side that the inbound half did not have to face:

- The lock cannot span the push. So the drain's shape is: lock → read → decide →
  unlock → HTTP → lock → re-read → write result. The second critical section must
  re-check that the row still matches what it decided on, because a webhook can
  land in the gap. That re-check is the actual serialization; the first lock only
  buys a consistent read.
- Lock ORDER is fixed and global, because `hashtext` is one int4 namespace:
  `ghhook:` → `taskimport:` → `tasksync:`. The outbox's own claim lock
  (`taskrun:`/a new `taskop:`) has to be placed in that order before it is
  written, not after.

**Confirm:** nothing.

---

## 4. What detects a push that succeeded but had no effect, and what stops the retry loop?

**Proposed: `applyOp` compares the response against what it asked for, field by
field, and returns `noEffect: ScalarField[]`. A per-field counter on the task
stops the loop after 3, and the field is marked "not accepted by GitHub" in the
UI and left alone locally.**

The plan states the rule and leaves two things unstated, which are the decisions:

- **Where the counter lives.** Not on `TaskSyncOp` — ops are superseded and
  deleted, so a counter there resets every time the user edits the field again,
  which is precisely the loop. It belongs on the task: a `Task.pushBlocked` JSON
  map of `field -> { count, lastAt, reason }`, cleared for a field when a push of
  it finally takes effect, and shown in the UI beside the field.
- **The threshold is 3, not 1.** One no-effect response is also what a genuine
  race produces (a human set the same value a moment earlier). Three is enough
  that a real non-convergence is unmistakable and small enough that we burn 3
  writes, not 30, of a 500/hour budget.

**Its blind spot is load-bearing and must be written next to the code.** The
detector only sees a field the provider *changed or dropped*. A push whose target
is already correct in provider space returns exactly what was asked for and reads
as a clean success — the `in_progress → open` loop. Nothing in this detector
catches it; only merging `status` in provider space does. The two guards are
complements: provider-space comparison stops loops caused by our vocabulary being
finer than theirs, the counter stops loops caused by theirs silently declining
ours.

**Confirm:** the threshold of 3, and that a blocked field stays blocked until a
push takes effect rather than expiring on a timer. A timer would restart the loop
on its own schedule, which is the failure mode being prevented, but it also means
a field blocked by a transient provider bug needs a user action to unblock. The
UI marker is that action.

---

## 5. When a local task is deleted, what happens to its external identity, its pending ops, and the next inbound webhook for its issue?

*Settled by the tree, except for the ops.* `softDeleteTask` (`models/task.ts`)
stamps `deletedAt` and sets `syncState = 'unlinked'` in the same transaction, and
the external columns are **retained** — provenance stays readable, and the
inbound path drops a delivery for an unlinked task rather than resurrecting it.
Deleting an Antgrid task never deletes a GitHub issue, in v1 or ever: the issue
is not ours, and deleting one is admin-only and irreversible.

The piece phase 5 adds:

- **Cancel every pending `TaskSyncOp` for that task in the delete's own
  transaction.** A queued `title := X` applied after the user deleted the task
  writes to a repository they have stopped tracking.
- **Except an already-attempted create.** An op with `attemptedAt` set and no
  `externalId` on the task has an unknown outcome: the issue may exist with
  nothing linking to it. Cancelling it blind leaves an orphan issue nobody can
  find. That op must run its resolution step — the `creator=app/<slug>&since=`
  listing — record the id on the tombstoned task, and only then stop. This is the
  one place where a deleted task still talks to GitHub, and it is a read.

**Confirm:** that the orphan-create resolution is worth the complexity, or
whether an orphan issue with a note in the logs is acceptable for v1. I lean to
resolving it, because the alternative is an issue in a user's public repository
that our own retry created and our own delete forgot.

---

## What is still not answered anywhere

Not part of the five, but phase 5 hits them on day one:

- **`done ↔ cancelled` cannot be delivered by a PATCH** (`state_reason` is
  ignored unless `state` changes). Either send reopen-then-close — two
  content-creating writes and a visible reopen in the issue timeline, which has to
  be in the trust copy — or mark the transition local-only in the UI. Pick one
  before the drain ships; a field that silently never converges is the worst of
  the three.
- **`label` events are not subscribed**, so a repo-wide rename trickles in one
  issue at a time as remove+add, and a repo-wide delete is invisible until our
  next push **recreates** the label in a random colour. Subscribe to `label`, or
  accept both and say so in the copy.
- **The drain's rate bucket must be sized to 500/hour, not 80/minute**, and
  throttling must be an outcome distinct from failure — a local throttle that
  increments `attempts` drives exponential backoff for a queue that is merely
  waiting. `util/rate-limit.ts` is the right shape and the wrong thing to reuse:
  it returns a boolean, not a wait time.
