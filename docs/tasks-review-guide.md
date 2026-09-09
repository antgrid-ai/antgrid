# Reviewing `feat/tasks`

Task management for Antgrid, dogfooded on `antgrid/antgrid`, with GitHub Issues
as the only v1 integration. The branch is long — read it in the order below
rather than commit by commit, because the commits are chronological and the
argument is not.

Nothing on this branch can reach GitHub yet: no App credentials exist, so no
integration can be linked, so `resolvePushTarget` refuses every enqueue. The
outbound half is complete and inert. That is deliberate — it is why wiring the
enqueue before the drain carried no pile-up risk.

## Read the argument in this order

### 1. The shape of the thing — `docs/tasks-and-integrations-plan.md`

What is being built, and why it is a shadow-snapshot sync rather than a mirror.
Start here; everything else is a consequence.

### 2. The two vocabularies — `web/src/tasks/merge.ts`

The single most important file. A task's `status` is Antgrid vocabulary
(`open`, `in_progress`, `blocked`, `done`, `cancelled`); an issue's is provider
vocabulary (`{state, stateReason}`). `toRemote` is **many-to-one** — `open`,
`in_progress` and `blocked` all project onto GitHub `open` — so every comparison
that decides whether to push happens in provider space. Compare in Antgrid space
and `in_progress` pushes `open`, the echo arrives as `open`, the merge sees a
difference, and it pushes again for ever.

`remoteSnapshot` is the last state both sides agreed on. It is the base of a
three-way merge, not a cache of the remote.

### 3. Inbound — `web/src/integrations/`

The webhook route feeds `webhook_events`; `github-inbound.ts` drains it. The
route verifies and records — **nothing is applied on the request path**. Three
properties are load-bearing and invisible from the call sites:

- the dedup key is a hash of the **raw signed bytes**, not `X-GitHub-Delivery`
  (a header, so a captured `(body, signature)` pair replays for ever under fresh
  ids);
- a delivery is resolved **only** by `[provider, installationId]` with
  `revokedAt IS NULL` — never by `externalAccountId` or `repoKey`;
- every refusal on the way in is a **drop that marks the row processed**, never
  a throw that burns the attempt ceiling.

`models/integration-identity.ts` is the only thing entitled to turn a GitHub
login into a user row, and it requires an **active membership of the
integration's own account**. Without that filter, one tenant's issue lands on
another tenant's member.

`github-poll.ts` was written last but belongs here, because a webhook can only
ever deliver the future: a repository switched on today generates no delivery for
the issues already in it, and a delivery lost to an outage is never re-sent. Both
are the same walk from a different starting point — `null` for "never read this
repository", the stored `lastCursor` for "read it again from here" — which is why
there is one implementation. Three things in it are worth arguing with. It lists
`direction=asc`, so a walk cut off by a bound is still a **prefix** and the cursor
it left is resumable; descending order could not advance a cursor until the whole
walk finished, so a repository past the page ceiling would never record progress.
It resumes at `lastCursor` minus `POLL_OVERLAP_SECONDS`, because `since` has
one-second resolution against GitHub's clock, and re-listing an unmoved issue
writes nothing while missing one is silent and permanent. And `lastFullSyncAt` is
written **only** on a short page — every other ending is a prefix, and claiming
completeness there is a lie a later feature would read. It imports through
`github-inbound.ts`'s own `importIssue` rather than a copy, so the idempotency
lookup, the import filter and the assignee resolution cannot drift into two
answers.

### 4. Outbound — the files added last

Read them in this order; each only makes sense after the one before.

| File | What it settles |
|---|---|
| `web/src/tasks/sync-op.ts` | The outbox. Supersede rather than queue; an attempted op is never rewritten; the claim reads each task's **lowest pending `seq`**, not the globally-oldest `nextAttemptAt`. |
| `web/src/integrations/github-issues.ts` | The write seam. `GithubIssuePatch` has **no `assignees` field by construction**. |
| `web/src/integrations/github-push-policy.ts` | Rate policy. Throttling is an outcome distinct from failure, and never touches `attempts`. |
| `web/src/tasks/apply-op.ts` | The executor. Two critical sections, a pre-push re-fetch, two version tokens. |
| `web/src/tasks/sync-drain-loop.ts` | The scheduled runner (`bun run drain:task-sync`). Scheduling and credentials only — it reopens no decision above it. |
| `web/src/tasks/publish.ts` | The publish path. Which repositories may receive an issue, and the one transaction that binds a task to one and queues the create. |

`GET /account/projects` (`web/src/routes/projects.ts`) belongs with them and is
the smallest of them: without it `taskProjectNamesProvider` is empty, the
create form's project picker is absent, and its publish toggle can only arm for a
task already filed against a project. A pre-existing gap that publish made
visible.

### 5. The consent surface — `web/src/ui/integrations.tsx`

Everything outbound is gated on two per-repository booleans that default to
false, and this page is the only thing that can set them. Read the copy as part
of the mechanism, not as decoration: `pushEnabled` is the switch that lets
Antgrid edit issues in someone's repository, and `publishNewByDefault` decides
where a create form's switch starts. The route pairs them — push off stores the
default off — so re-enabling push later cannot arm publishing on a consent given
when nothing was being written.

Every toggle on the row saves itself and only the filter fields wait for Save,
which is why the form's `hx-trigger` names a row-scoped selector rather than
htmx's `find`: `find` binds the first match alone, and a consent switch that
looks thrown but was never posted is the one failure this page cannot afford.

### 6. The app — `app/lib/widgets/tasks/`

`task_detail_view.dart` and `task_provenance_view.dart`. The provenance line and
the conflict block are the only places a user learns that sync exists at all.

## The eight claims worth attacking

Each could reasonably have gone the other way. Where you disagree, the code says
so in a comment at the point of decision — argue with that comment.

1. **`status` merges and pushes in provider space.** Antgrid-space comparison is
   a self-sustaining push loop, because `toRemote` is many-to-one.
   → `web/src/tasks/merge.ts`

2. **Echo suppression keys on _what_ was written, never _when_.**
   `Task.pushedHash` is a hash of the push **response**, because GitHub
   normalizes what it stores. The obvious `updated_at` scheme silently drops a
   human's edit that our blind PATCH clobbered a second earlier, records no
   conflict, and cannot be recovered by a later poll — remote and base agree by
   then. → `web/src/integrations/github-echo.ts`

3. **A pre-push re-fetch, aborting when `remote != base`.** GitHub offers no
   `If-Match` on issues, so a PATCH is blind. This and the hash are complements,
   not alternatives: without the re-fetch we destroy the edit, without the hash
   we raise a conflict against our own write. → `web/src/tasks/apply-op.ts`

4. **Two version tokens across the HTTP gap.** A moved `remoteSnapshot` writes
   nothing; a moved `opKey` still writes the observation. The asymmetry is the
   subtle part — see the `commit` doc comment in `apply-op.ts`.

5. **A 403 is classified by which rate headers are present.** GitHub answers a
   permission denial and a secondary-rate block with the same status and no
   discriminator. Wrong in one direction retries for ever; wrong in the other
   drops a user's edit. **This is the branch's largest residual risk.** The
   drain bounds it by capping consecutive throttles per op independently of
   `attempts`. → `web/src/integrations/github-push-policy.ts`

6. **A no-effect counter on the task, not the op, with no expiry.** A push can
   return 200 and change nothing — GitHub silently drops an assignee lacking
   push access. Three strikes and the field stops being pushed. On the op the
   counter would reset every time the user retyped the value; with an expiry the
   timer would restart the loop it exists to stop. Its only exit is
   `POST /tasks/:number/push-block/clear`, which lifts the marker and re-queues
   the value in one transaction — lifting alone would change nothing a user can
   see, because the op that carried the field was cancelled when the block was
   read and the outbox is driven by edits.
   → `web/src/tasks/push-blocked.ts`, `web/src/routes/tasks.ts`

7. **Publishing refuses a device credential outright.** `requireBearerJwt`
   blanks `sessionId`, so a Bearer request cannot be told from an agent driving
   the bridge. The required `publish` field is the primary defence and holds
   whatever the carrier, but it records an intent rather than proving who formed
   it. Unlink and the targets read are deliberately outside the gate: neither
   writes to the provider. → `publishFromDevice` in `web/src/routes/tasks.ts`

8. **A write budget as a rolling window, not a token bucket.** A bucket cannot
   express 500/hour: capacity `C` refilling at `R` admits `C + R·T`, so the only
   bucket that starts full at 500 admits a thousand writes in its first hour.
   → `web/src/integrations/github-push-policy.ts`

## Invariants a later change could break silently

- **Lock order is fixed:** `ghpoll:` → `ghhook:` → `taskimport:` → `task:` →
  `tasksync:`. `hashtext` is one global int4 namespace, so a new prefix would
  have to be placed against every existing one. The outbox deliberately adds
  none; publish added the `task:` → `tasksync:` edge, which is why `task:` now
  appears — a publishing create allocates its number and then queues the issue in
  the same transaction. Nothing takes `task:` while holding `tasksync:`. The
  poll's `ghpoll:` is outermost but in practice disjoint: its claim transaction
  commits before any import transaction opens, so nothing ever holds it beside
  another.
- **`ON CONFLICT DO UPDATE` holds a row lock to commit.** Identity upserts are
  sorted for that reason; unsorted upserts of the same rows deadlock.
- **`jsonb` does not preserve key insertion order.** Any ordered rendering of
  `localConflict.conflicts` or `pushBlocked` must sort explicitly.
- **An empty claim pass is not an empty queue.** `claimNextOps` applies its
  `limit` before the try-lock filter, so a pass whose candidate tasks are all
  held elsewhere claims nothing while a backlog exists. The inbound webhook
  drain stops on a zero-row pass; the outbox drain must not.
- **Restoring a losing local value must not re-seed `remoteSnapshot`.**
  `local != base` is what sends a future push and what stops the next inbound
  delivery (`remote == base`) from re-clobbering.
- **`setTaskLabelsInTx` deliberately does not enqueue.** Its only caller is the
  inbound importer; enqueueing there pushes the provider's own state back at it.
- **The dual-license boundary is one-way.** `packages/antgrid-wire` and
  `packages/antgrid_relay_client` are Apache-2.0. Hoisting a shared helper out
  of `web/` into either relicenses it permissively — it compiles, CI stays
  green, and nothing warns you.

## What is deliberately not here

- **Notifications** (phase 7) — deferred by design, not forgotten.
- **`deleteLabel` fan-out.** Deleting a label cascades it off every task that
  carried it — one vocabulary edit becoming an `issue.labels` op per affected
  task. Unresolved, and recorded as such.
- **Assignee push.** Structurally absent from `GithubIssuePatch`, not merely
  unimplemented.

## Where the open questions live

`docs/tasks-open-decisions.md` — every call taken without you, in the order it
was taken, each with the reasoning that produced it. The ones still genuinely
open rather than merely provisional: the GitHub App credentials and its
"Request user authorization (OAuth) during installation" setting; the
`commentImportCap`; the `importFilterKind` default; whether integrations should
be owner-only; and the `deleteLabel` fan-out.

## Running it

```bash
cd web && bun run test    # needs Postgres (PG_DATABASE_URL) + a generated Prisma client
cd app && flutter test
cd app && flutter analyze # once, never concurrently — it deadlocks silently
```

Two web test files hang forever under `bun test` from a worktree checkout and
pass in the main checkout: `tests/billing/account-members-schema.test.ts` and
`tests/models/account-invite.test.ts`. Unrelated to this branch.
