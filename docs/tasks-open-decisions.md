# Tasks: decisions needed from you

**Ephemeral worklist, not a design document.** Delete it once every item below has
an answer folded into `tasks-and-integrations-plan.md` / `tasks-prd.md`. It exists
so the design docs are never edited to say "TBD" — three docs disagreeing is the
problem this feature already had once.

Each item: the decision, a recommendation, and what it costs to get wrong.

## 1. GitHub App registration — hard blocker on phases 4 and 5

Nothing I can produce. Needs an owner of `antgrid/antgrid` to create the App and
hand back:

| Input | Notes |
|---|---|
| App ID | public |
| Client ID | public |
| Private key (PEM) | **cross-tenant master key** — see the plan's warning; it signs for every installation |
| Webhook secret | inbound signature verification |
| Webhook URL | needs a publicly reachable endpoint; staging or a tunnel |
| Permissions | Issues: read+write, Metadata: read. Nothing else in v1. |
| Events | `issues`, `issue_comment`, `installation`, `installation_repositories` |

One correction to that Events row, found while building 4b. `repository` belongs
on the list too: a private-to-public flip retroactively exposes every issue
published under the opposite assurance, and `IntegrationRepo.visibility` is what
the consent UI reads to say so. The drain already handles it. `label` is
deliberately **not** on the list — an issue payload carries the issue's own
labels, so a separate label event only buys renames and deletes of the label
itself, and that is phase 5's problem.

One more registration setting, and this one is a security property rather than a
convenience: **enable "Request user authorization (OAuth) during installation"**.
Without the identity `code` it hands back, the install callback cannot prove that
the `installation_id` in its query string belongs to the person completing the
flow — and that id is the only key inbound deliveries route on, so binding
someone else's installation to your account redirects their issue events to you.
The reasoning is written out under "The install flow" in the plan.


Until this exists I can build phases 4–5 against recorded fixtures but cannot
verify a live install, a real delivery, or the signature path against GitHub's
actual bytes. **Recommendation:** register it as an org-owned App (not personal),
private, and keep the PEM out of the repo and out of `.env.example`.

## 2. Entitlement — free, or a Pro lever?

Must be decided before task routes ship, not after users have tasks.

There is already an *implicit* gate and it is lopsided: minting a device token
throws `"no subscription for user"`, so the **bridge** path requires an active
subscription. With the app on the cookie gate, the **app and browser reach task
routes with no subscription check at all**. So "inherit the existing gate" is not
a coherent option — it gates one caller and not the other.

**Recommendation:** free, with an explicit `CAPABILITIES` entry in
`bridge/src/entitlement.ts` set to always-on. That reserves the lever without
gating dogfooding, and it makes the asymmetry above a deliberate no-op rather than
an accident. Do not leave it unstated.

## 3. `importFilterKind` default

Column exists (`all | label | milestone | assigned_to_member`); only the shipped
default is open.

**Recommendation:** not `all`. Pointed at a repo with a few hundred open issues,
the account-wide "All open" view is unusable and the Running view — the actual
differentiator — becomes a needle in a haystack we imported on purpose. Ship
`label` (or `assigned_to_member`) as the default and put `all` behind an explicit
per-repo opt-in that shows the issue count next to the choice. Cost of getting it
wrong: the first dogfood import buries the feature's own demo.

**What phase 4a actually shipped: `@default('all')`** — the opposite of that
recommendation, and I want it on the record rather than buried in a migration.
It is inert rather than wrong: `syncEnabled` has no default in either the column
or the model layer, so nothing imports until a caller states it per repo, and the
filter default only decides what a caller that says nothing gets. The decision
that matters is what the install flow passes in **phase 4c**, and I will bring it
back there rather than let a column default settle it.

## 4. `commentImportCap` value

Column exists with a non-null default; the number is open. Uncapped import of a
busy repo is roughly ten hours of API budget for one repo, and `TaskComment` is
the only table here that can grow fast.

**Recommendation:** a small N (25–50), newest-first, with a deep link to GitHub for
the remainder, and the UI saying plainly that it is a partial mirror — it has to,
because `issue_comment.deleted` is unhandled in v1, so the local view can never be
reconciled to the remote one.

**What phase 4a actually shipped: `@default(100)`**, bounded `0..10_000`. The
reasoning is real and it is on a different axis than the recommendation above:
GitHub returns 100 comments per page, so a cap of 100 costs *exactly the same one
request per issue* as a cap of 25 — a smaller N buys no API budget at all, it
only imports less. So the two arguments do not meet:

- **API budget says 100** (or anything ≤100 — all identical), and 100 covers the
  large majority of real threads whole rather than truncating them.
- **Storage and trust posture say 25.** 5,000 issues × 100 comments is 500k rows
  of third-party text in our Postgres, plaintext and readable by every member of
  the account. That is the axis the original recommendation was on, and cutting
  the cap is the only lever that moves it.

Your call. Changing it is a one-line migration plus, for repos already imported,
nothing — the cap only bounds what a first import pulls.

**What phase 4c-1 enforces: the cap is per task, and it is the OLDEST comments
that win.** Two departures from the paragraph above, both worth your eye:

- *Per task, not per repository.* The argument above reasons in requests per
  issue, and a provider page is per issue too, so per-task is the unit it is
  actually about. But the column sits on `IntegrationRepo`, where it reads as a
  repository budget, and the two differ by four orders of magnitude on a busy
  repo. Read the other way it would mean the 101st issue imports no comments at
  all, which nothing in the UI could explain.
- *Oldest-first, not newest-first.* 4c-1 imports comments one delivery at a time
  as they arrive, so the cap is a ceiling the thread grows into: the first
  hundred are kept and everything after is dropped. The newest-first the
  recommendation asks for needs a paged backfill to exist, which is the
  reconcile poll's job, not the webhook's. An edit to a comment already imported
  always applies, cap or no cap — refusing it would leave a stale body rather
  than save anything.

## 5. How much of "bidirectional" ships in v1

Still open in the plan, deliberately — a cold review argued the current split is
inverted and the argument was strong enough to record rather than resolve.

**No decision needed tonight:** phases 1–4 are identical either way. It has to be
answered before phase 5 and not before phase 4.

## 6. The five phase-5 questions

The plan gates phase 5 on written answers to all five (echo-suppression key,
where a losing local value lives, what serializes the drain against the webhook
processor, what detects a no-effect push, what happens to a deleted task's
external identity). Four are answered in the plan as it now stands. #3 was not,
so below is a proposed answer for you to accept or reject — it needs your yes,
not your design.

**The plan's own suggested fix does not work.** It offers "`DISTINCT ON (task_id)
… ORDER BY task_id, seq` in the subselect", and that is wrong three separate
ways:

1. **It does not run.** Postgres refuses `DISTINCT` together with `FOR UPDATE`:
   `0A000 FOR UPDATE is not allowed with DISTINCT clause`. Measured against our
   own dev Postgres, not inferred.
2. **It does not exclude a task another drainer is already pushing.** `DISTINCT
   ON` dedupes *within one claim batch*. Drainer A holds task T's op 1 as
   `claimed` with an HTTP call in flight; drainer B's candidate set only contains
   `pending` rows, so op 1 is invisible to it, op 2 becomes T's head, and both
   PATCH the same issue concurrently — the exact lost label the invariant exists
   to prevent.
3. **Filtering candidates by `next_attempt_at <= now()` re-introduces the
   reordering it is meant to fix.** If op 1 backed off into the future it is
   filtered out of the candidate set, so op 2 becomes the head and applies first.
   That is the original bug with extra SQL.

**Proposed statement.** Readiness is applied to the head *after* the per-task
pick, the in-flight guard is a `NOT EXISTS` on the same table, and `status =
'pending'` is repeated in the outer `WHERE` so a concurrent claim loses under
READ COMMITTED re-check instead of double-claiming:

```sql
UPDATE task_sync_ops o SET status = 'claimed', attempted_at = now()
WHERE o.status = 'pending' AND o.id IN (
  SELECT head.id FROM (
    SELECT DISTINCT ON (t.task_id) t.id, t.next_attempt_at
    FROM task_sync_ops t
    WHERE t.status = 'pending'
      AND NOT EXISTS (
        SELECT 1 FROM task_sync_ops c
        WHERE c.task_id = t.task_id AND c.status = 'claimed')
    ORDER BY t.task_id, t.seq
  ) head
  WHERE head.next_attempt_at <= now()
  ORDER BY head.next_attempt_at
  LIMIT $1
)
RETURNING *;
```

Exercised against our dev Postgres over the four cases that matter — a task whose
head is backed off claims nothing (its ready successor does **not** jump it), a
task with two ready ops yields only the head, a task with an op already in flight
is skipped entirely, and heads are claimed most-overdue-first so a low `task_id`
cannot starve an older one. Two drainers racing one op: exactly one wins.

**What it costs, stated plainly.** Blocking a whole task on its in-flight op
makes the stale-claim reaper load-bearing for *liveness*, not just tidiness — a
crashed drainer now stalls every op for that task, not one. Its timeout must
exceed the HTTP timeout, and it needs an alarm. Also `@@index([status,
nextAttemptAt])` no longer serves this query: it wants `[status, taskId, seq]`,
with the old index kept for the reaper.

**Not addressed here:** what serializes this drain against the *webhook
processor* for one task — the other half of #3. The plan's answer is
`pg_advisory_xact_lock(hashtext('tasksync:' || taskId))` held across each side's
read-merge-write, and that still stands; the above only fixes drainer-vs-drainer.

---

## Anything I stopped on overnight

Recorded here as I go, so you get a list rather than a blocked branch. Nothing
below blocked the build — each is a call I made explicitly rather than silently,
and each is cheap to reverse now and expensive to reverse after users have tasks.

### Task routes ship with no subscription gate (item 2, provisionally taken)

Item 2 above has to be answered before task routes ship, and phase 2 ships them.
I took the recommendation — **free** — rather than stopping the branch on it,
because it is the only choice that is reversible in one direction: adding a gate
later refuses callers who never had it, whereas removing one refuses nobody.

What that means concretely: the task routes carry the account-membership check
(`findActiveMembership`) and nothing about subscription state. The `CAPABILITIES`
entry in `bridge/src/entitlement.ts` is **not** added — an always-on entry that
nothing reads is a lever in name only, and I would rather it be absent than
present-and-lying. If you decide tasks are a Pro lever, the gate goes in one place
and the entry goes in with it.

### One status code changed for existing clients

Hardening the Bearer gate moved `POST /account/devices/me/heartbeat` and
`POST /account/projects/bindings` from **404 to 401** in one case: when the
*caller's own* device is revoked. That is the correct code — the credential is
dead, not the target — and no bridge behaviour depends on the distinction
(`sendHeartbeat` reads only `res.ok`; trusted-peers throws on any non-ok and keeps
its cache). Flagging it because it is a wire-visible change to a shipped route,
not because I think it is wrong.

### The binding report has two silent no-ops, both benign

`ProjectBindingReporter` sends nothing when the machine has no device credentials
— there is no account to report to, so this is not a gap. Less obviously, the
boot-time control-plane open is best-effort and its OAuth mint failure is
swallowed, so a machine whose boot mint failed reports no bindings until a later
remote open retries the mint. Both fail toward *nothing happens*, never toward a
wrong binding, which is why I left them rather than adding a retry timer that
would need its own backoff and its own failure mode.

### Three calls taken inside the tasks schema (phase 2a)

Each is cheap to change now and expensive once an account has tasks.

**`priority` is an unlabelled `Int?`.** No surface in any of the three docs picks
a vocabulary for it, so the column is an ordinal rank rather than an enum: the UI
can name the buckets later without a migration. If you want `P0..P3` or
`low/med/high` as a stored vocabulary rather than a presentation choice, say so
before the first task carries one.

**A repo-scoped label may only sit on a task in its own project**, and re-filing
a task to another project drops the repo-scoped labels it was carrying.
`area/relay` on a task in a different repository is meaningless locally, and once
that task is linked it would push a label name into a repository that never had
it. The alternative — let them ride along and filter at push time — puts the
check somewhere much easier to forget.

**A soft-deleted task keeps its external identity, and the protection around
that is only half-built.** `softDeleteTask` marks a linked task
`syncState='unlinked'` as the plan specifies, but `tasks_account_external_key` is
untouched, so an inbound upsert still resolves straight to the deleted row.
What actually stops remote edits landing on a task the user believes is gone is
the inbound path filtering `deletedAt IS NULL AND syncState <> 'unlinked'` — and
that path does not exist yet (phase 4). Nothing in the tree enforces it today;
the code comment now says so rather than implying the marker is sufficient.

### Four calls taken inside task runs (phase 3a)

**A session belongs to one task for its whole life.** `TaskRun` is keyed
`(deviceId, sessionId)` with `taskId` deliberately outside the key, so a second
task reporting the same session is a `409`, never a silent re-point. Re-pointing
would move a finished run's branch and PR onto a task that never ran it. The
refusal names the task the session is already on so a reporter can correct
itself — and names nothing when that task belongs to another account.

**`endedAt` is stamped from an explicit `ended` flag, never from
`status === "done"`.** `WorkStatus.done` means *no turn is open*: an agent that
finished, an agent that went idle, and a freshly-opened chat all report it. The
same reason `done` writes nothing to `Task.status`.

**Two run statuses move the task, and both are compare-and-set.** `working`
moves `open`→`in_progress`; `attention` moves `open`|`in_progress`→`blocked`.
The observed status is in the `WHERE`, so a task the user closed from the app
mid-report is not dragged back. Nothing else is automatic. If you want a third
transition, it has to answer the same question: what does it do when a human
already moved the field?

**`GET /tasks/:number/runs` was added beyond the brief.** A write-only table with
no reader is half a feature and the app's task detail needs it. Say the word and
it comes out.

### The display id is one constant, not a column

`ANT-14` is formatted and parsed in one place (`web/src/tasks/display-id.ts`) and
the route answers both `14` and `ANT-14`, because the link this app will write
into a GitHub issue body is the prefixed form and it would otherwise 404 on its
own author. The prefix is **not** per-account today. If accounts should pick
their own (`ACME-14`), it becomes a column and that file is the single place that
changes — but it is much cheaper to decide before any account has tasks.

### `taskRef.taskId` carries the display id, because nothing else is available

`TaskRefSchema` is `{taskId: string().min(1), number: int().positive()}` and the
minimum length means the field cannot be left empty. The app has no task uuid to
put there: `taskJson` never emits one, and `number` already occupies the other
half. So a launch sends `taskId: 'ANT-42'`.

It is not a lie — `ANT-42` genuinely addresses the task, `parseTaskId` accepts it
and `GET /tasks/ANT-42` resolves — and nothing reads it: `bridge/src/task-run.ts`
reports against `taskRef.number` alone, and the bridge only stores and echoes
`taskId`. But the two halves are now redundant, and if `taskId` should ever mean
a uuid, this is the call site that has to change. The alternative is dropping
`min(1)` from the schema and sending nothing, which is a wire change in three
places (Zod, the hand-mirrored Dart, and the session store).

### The launch sheet is the only path to an agent

`TaskLauncher.start` has exactly one caller and it is the sheet's submit button.
That is what makes the untrusted-body rule structural rather than a convention:
an imported issue body cannot reach an agent without a human seeing the prompt
first. The `r` accelerator in `docs/tasks-ux.md` is not built yet, and building
it as a second call site is how the bypass comes back.

### No machine picker, and it needs a wire change before there can be one

`docs/tasks-ux.md` specified the machine defaulting to `runTargetDeviceId`. Those
columns exist only in Postgres — `taskJson` does not emit `runTargetDeviceId` or
`runTargetProjectId`, so the app has never seen them. A task's `projectId` is an
account uuid and `AbProject` ids are a different namespace with no route between
them, so a task cannot resolve its own local project either. The sheet launches
into the project the user has open and names it on screen. Adding a real picker
is a `taskJson` change first; I did not make it, because it widens the task API
for a feature nobody has asked for yet.


### Nothing runs the drain (phase 4b)

`web/src/index.ts` is `Bun.serve` and nothing else. There is no scheduler in this
service — the only precedent for periodic work is `scripts/reconcile-seats.ts`,
driven by external cron. So `drainGithubWebhooks` and
`purgeProcessedWebhookEvents` exist, are tested, and **nothing calls them**:
every verified delivery is recorded and then sits there. That is safe (the whole
point of insert-then-202 is that the row is durable), but it is inert until
something invokes it. Two ways out and I did not pick one: a `setInterval` in
`index.ts`, which is simple and re-drains on every deploy of every instance, or a
`scripts/drain-github-webhooks.ts` on cron, which matches the one pattern this
service already has. Phase 4c needs whichever you prefer, because the import is
the drain.

**Taken provisionally in phase 4d: the cron script.** `scripts/drain-github-webhooks.ts`
plus `bun run drain:github-webhooks`, matching `reconcile-seats`. The deciding
argument was not simplicity, since both options are simple; it was that a
`setInterval` in `index.ts` puts a long database-bound job on the event loop that
has to verify and record deliveries inside GitHub's delivery timeout, so the
service would get slowest exactly when it is furthest behind — and that a timer
callback which throws logs and leaves the interval armed, whereas a scheduled
process has an exit code, which is the only alerting channel this service has.
Switching is one file: `drainGithubBacklog` is the whole runner and takes its
dependencies as an argument, so an in-process timer is a call to it, not a
rewrite. If you want that instead, say so before 5 — the outbox will want the
same answer.


Two consequences 4c-2 added to that list, both of them stale UI rather than an
unauthorised import. A repository the user deselects on GitHub keeps
`sync_enabled` true and `removed_at` null until somebody re-runs Connect, because
`markMissingReposRemoved` has exactly one caller and it is the install flow — so
the settings page claims an import that is not running, while inbound deliveries
for it are refused by `resolveIntegrationRepo` anyway. And the removed-repo row
tells the reader to add the repository back on GitHub to get the switch back,
which is true, but today it comes true through that same re-run rather than
through the `installation_repositories` delivery the sentence implies.

### Deferred rows grow unbounded until 4c ships

`purgeProcessedWebhookEvents` only deletes rows with `processed_at` set — an
unprocessed row is backlog, and deleting backlog is data loss. `issues`,
`issue_comment` and `label` are subscribed to and deliberately never claimed, so
from the moment the first App installation exists until 4c ships, those payloads
accumulate with no ceiling. On this repo that is small. It is worth knowing
before the App is installed anywhere busy.

The same is true of a second, smaller set that 4c does *not* clear: rows that
exhausted `MAX_WEBHOOK_ATTEMPTS`. They keep `processed_at` null, so nothing
claims them and retention does not delete them, and that is deliberate — they are
the evidence of what failed, and `listGivenUpDeliveries` exists to read them.
Nothing empties that pile once it has been read, though, so at some point it
wants either an operator verb or a longer retention rule of its own. It is not
urgent: the drain script exits 1 the moment a delivery gives up, so the pile
cannot grow quietly.

### A removed repo is disabled, and re-adding it does not re-enable it

`installation_repositories.removed` sets `syncEnabled = false` on the row rather
than deleting it, because the row is what a task's `integrationRepo` link points
at and because deleting it would throw away the user's consents. But consents are
**create-only** (`upsertIntegrationRepo` never rewrites them), so re-adding the
repository to the installation finds the existing row and leaves `syncEnabled`
off. The user turns it back on in settings. I think that is right — a repo
leaving and returning is not consent to resume — but it is a choice, and the
settings page in 4c has to make the off state visible or it reads as a bug.

### An `installation.created` that races the install flow is dropped for good

The webhook can arrive before the install flow has written the `Integration` row.
`resolveInstallation` finds nothing, the delivery is marked processed with
`unknown_installation`, and the repository list it carried is gone. This is
recoverable — the install flow reads the installation's repositories itself, and
the reconcile catches drift — but it means **4c's install flow must not depend on
the webhook** for its initial repo list. Flagging it because the opposite design
(the webhook seeds the repos, the flow just records the token) is the tempting
one.

### The billing webhook path still has the NUL hazard I fixed on the GitHub one

Postgres cannot store a NUL escape in `jsonb`, and the insert raises rather than
truncating. `integrations/webhook-events.ts` now strips the character before
serializing, so a poison payload is stored lossily instead of 500-ing the route
into a provider retry loop. `billing/reducer.ts` writes its payload the same way
and has no such guard. I left it alone: it is a payment path that has been live,
the fix is not free of regression risk, and Paddle and Razorpay send structured
financial data where a NUL is close to unreachable. Worth doing on purpose one
day, not as a drive-by inside a tasks branch.

### The conflict badge is sticky, and nothing can clear it yet (phase 4c-1)

The brief said `syncState` should be `conflict` when *this merge* produced
conflicts and `synced` otherwise. What shipped is stickier: `Task.localConflict`
accumulates across merges, and `syncState` is `conflict` while that blob is
non-empty. The reasoning is sound — a conflict the user has not looked at should
not be erased by the next unrelated field change arriving from GitHub — but it
has a trap while 4c-1 stands alone: **the only thing that clears the blob is a
resolution UI, and there is none.** So today a conflict badge is permanent for
the life of the task.

Three ways out, in the order I would take them: ship the resolve control in the
same phase as the first real import (my preference — the blob's shape is already
designed for it); or make it non-sticky, which is a one-line change and loses the
"you have not seen this yet" property; or leave it and accept that dogfooding may
produce a task or two wearing a badge that cannot be dismissed. Say the word and
I will make it non-sticky.

One detail that reads as a bug and is not: `labelRemoveWins` is recorded in
`localConflict` but is deliberately **not** counted toward `syncState`. It is a
resolution, not a conflict — the remote removal won, and the record exists so the
UI can say why a label vanished.

### `externalId` is GitHub's numeric id, reversing my own brief (phase 4c-1)

The 4c-1 brief I wrote said to key identity on `node_id`. Reviewing the diff I
changed it to the numeric `issue.id` and I am flagging it because it contradicts
an instruction, not because I think it is close.

`node_id` is a *rendering* of identity and GitHub has already reformatted it once
(a migration that ran from 2021 into 2023). A reformat is silent here: every
stored `externalId` stops matching, the lookup finds nothing, and the next
delivery creates a **second task for an issue we already hold** — precisely what
the `[accountId, externalProvider, externalId]` unique exists to prevent, and a
backfill to undo rather than a fix. The numeric id is the immutable primary key.

The change is free today — no App credentials, no installations, no linked tasks
anywhere — and would be a data migration after the first real import, which is
why I took it now rather than filing it. `node_id` earns a column back only if
the reconcile poll moves to GraphQL, where it is the only addressable id, and
then as a second column rather than a replacement.

### The import filter is asked once, on the way in (phase 4c-1)

`matchesImportFilter` gates whether an issue *becomes* a task. It is not
re-evaluated afterwards, so an issue imported under a `label` filter and later
relabelled out of scope keeps receiving updates for ever.

The alternative — unlink or stop tracking on the way out — trades a visible
problem for an invisible one: a task that silently stops matching its issue looks
like sync is broken and there is nothing on screen that could explain it, whereas
an extra task the filter arguably should not have imported is right there and can
be deleted. I would rather be wrong in the direction someone can see. Revisit
when the settings page can say what a filter change does to tasks already
imported.

### The app shows `externalKey`, and shows nothing when it is absent

The provenance surfaces render `owner/repo#12`, never `externalId`. The provider
handle is an opaque string that reads as line noise to a user, and 4c-1 made it a
numeric id, which reads as a different kind of line noise.

The consequence is that an app talking to an account service older than the
`externalKey` field shows the provider name and the link but no id. That is
deliberate — no id beats the wrong one — but it means every reader has to
tolerate null rather than fall back, and a test asserts the opaque handle reaches
the screen as nothing.

### A refused sync write answers 200 with the unchanged row (phase 4c-2)

`POST /ui/integrations/repos/:id/sync` returns `200` and the re-rendered
`IntegrationRepoRow` when it declines to store what was posted — a revoked
integration, a repository GitHub no longer lists, a filter pair the CHECK
constraint would reject, or a `setRepoSyncSettings` result that is not `ok`. htmx does not swap a `4xx` by default, so a refusal sent
as one leaves the browser showing the toggle in the state the server just
declined to store; answering with the stored row makes the switch snap back and
makes the refusal the thing the user sees.

The cost is that a non-browser caller cannot tell a refusal from a save. Nothing
in the body says "declined" — it is the same component either way — so a script
has to re-read the row to know what happened. Two other outcomes do still carry
codes (`403` with no billing account, `404` for a repository on another account),
so the flat `200` is specifically "your write was refused", not "everything is
200". Revisit when a JSON API for these settings exists; do not fix it by
switching the browser path to `4xx` without giving htmx an `hx-swap` override,
which is trading a visible bug for an invisible one.

### Two different `.catch()` defaults for two unreadable columns (phase 4c-2)

`repoView` in `routes/ui.tsx` narrows two text columns and lands on opposite
defaults on purpose. `visibility` uses `RepoVisibilitySchema.catch("private")`:
the private copy is the sentence that names what gets copied and who on the
account can read it, so guessing wrong toward private over-warns, and guessing
wrong toward public omits the warning on a repository that needed it.
`importFilterKind` uses `ImportFilterKindSchema.catch("all")` for a different
reason — it mirrors `matchesImportFilter`, which returns `true` for a kind it
cannot parse. The page must describe the import that is actually running, so
defaulting to a narrower filter here would have the screen claim a scope the
importer is not applying.

Neither value should ever be unreadable — both columns are written through the
schemas — so these are the behaviour of a corrupted row, not of a normal one.
What would change them: making either column a Postgres enum, at which point the
`catch` is unreachable and the asymmetry stops needing an explanation.

### `GithubAppConfig` is a plain record holding two secrets (phase 4c-2)

`{ appId, slug, clientId, clientSecret, privateKeyPem }` — an ordinary object,
so any structured logger that serializes it would dump a client secret and a
cross-tenant master key in one line. The alternative was an opaque handle: a
class, or a closure that never exposes the PEM as a property. I kept the record
and gave it redacting `toJSON` and inspect hooks instead, which costs no call
site anything and covers the two accidental paths — a context object being
stringified, and a bare `console.log` of the config.

Two things that leaves standing. The hooks have to be **enumerable** or
JavaScriptCore ignores `toJSON` outright, silently, which is a trap for anyone
who tidies the descriptors later; a test asserts both paths stay clean. And an
explicit `config.privateKeyPem` still reads the real value, because signing needs
it — a spread of the config leaks in full.

The rest of the mitigation is placement plus tests, not typing. The
config is built in the route, handed straight to `createGithubAppClient`, and
never stored; `privateKeyPem` is read in `mintAppJwt` and nowhere else;
`installDirectory` narrows the client to three methods so the config never
crosses into `github-install.ts`; the only log on the install path is
`console.warn("[integrations.install] provider error", { detail })` where
`detail` is a bounded `GithubApiError` message; and a test renders every failing
call's error — message, stack and own properties — and asserts no secret appears.
Nothing structurally stops a future `console.log(config)`.

What would change it: a second module needing the config, or a log line that
takes an object of unknown shape. Either makes a real opaque handle — one that
cannot be spread — worth its weight.

### `GITHUB_APP_CLIENT_*` is a second credential pair, and every App var is optional (phase 4c-2)

`GITHUB_CLIENT_ID`/`GITHUB_CLIENT_SECRET` are the OAuth app people sign in to
Antgrid with. `GITHUB_APP_CLIENT_ID`/`GITHUB_APP_CLIENT_SECRET` are the GitHub
**App's own** OAuth credentials, used for exactly one thing: exchanging the
install callback's `code` for a user-to-server token. Two pairs that look
interchangeable and are not — crossing them yields `bad_verification_code` from a
code that was perfectly good, which surfaces to the user as an expired install
link rather than as misconfiguration, and there is no way for the code to tell
the difference.

Every App variable is optional, including the private key, so the service boots
with no App at all: `githubAppConfig` returns `null` unless all five are present,
`/integrations/connect` redirects to `?github=not_configured`, and the page shows
a card saying the server has no App rather than a button with nowhere to send the
reader. That is one check at the top of a route rather than five, and — the part
that matters — a half-configured environment refuses at the door instead of dying
mid-install with an installation already created on GitHub's side.

What would change it: deciding the App is mandatory in production, which wants a
startup assertion keyed on the deployment rather than making the schema fields
required (the test suite and every dev machine run without them).

### Pagination throws at the ceiling rather than truncating (phase 4c-2)

`collect` walks at most `GITHUB_MAX_PAGES` (20) × `GITHUB_PER_PAGE` (100) and
throws `GithubApiError("unexpected", …, "exceeded the page ceiling")` if the
walk does not end on a short page. Both paginated reads — `/user/installations`
and `/installation/repositories` — are driven by a response the other side
controls, so "follow pages until a short one" is an unbounded loop over an answer
we do not own.

Throwing rather than returning what was collected is the whole point. A truncated
installation list only ever refuses a legitimate install, which someone notices
and reports; a truncated list returned silently is the shape that fails **open**
the next time this helper is reused for an allowlist, and nothing about the
return type would warn them. The cost is a hard 2,000-repository ceiling per
installation: an org above it cannot complete the flow at all, and the notice it
gets is the generic `provider_error`.

What would change it: a real installation near 2,000 repositories. Raise the
ceiling then — it is one constant — rather than converting the throw into a
truncation.

### Any active member can connect an integration (phase 4c-2)

The callback binds the installation to `resolveBillingAccountId(userId)`, which
is the caller's active membership account, and the sync post writes through the
same resolution. There is no separate "who may connect an integration"
permission and no `isBillingAccountOwner` gate — which the billing, checkout and
team routes in the same file do have.

Said plainly: **on a team account, any active member of any role can bind a
GitHub installation to the account and switch import on for any repository in
it**, and everything imported is readable by every member. The consent moment the
page is built around is therefore one member's consent on everyone's behalf. I
took it because the alternative invents a third role vocabulary for one feature —
owner-only would also block the common case where the person who administers the
org's GitHub App is not the person who pays the bill, and that refusal has no
good copy.

What would change it: a decision that integrations are an owner action, at which
point the gate is one call in two routes and the page needs a read-only rendering
for non-owners. Cheap now; it is not cheap after members have connected their own
installations.

### Notices travel as a closed enum in the query string (phase 4c-2)

`/integrations?github=<code>` carries an `IntegrationsNoticeSchema` member, not a
message. Both ends narrow through the schema and the wording lives in the page's
`NOTICE` record, so no route can put a sentence of its own — or an attacker's —
in front of a signed-in user by handing them a link. It matches `?invite=` on
`/team`, which is the precedent rather than a new pattern.

Redirecting at all is the other half: every branch of the callback redirects
instead of rendering, so the `code` GitHub put in the URL does not sit in
browser history or leak through a referrer.

The cost is one enum member per distinguishable outcome and no room for detail —
`provider_error` cannot say which call failed, and the detail goes to
`console.warn` where the user cannot see it. That is deliberate for a provider
error; it would be wrong for a user-correctable one, so the moment an outcome
needs a variable in its sentence, it needs a rendered page rather than a longer
enum.

### The install state is a cookie, not a `pending_sign_in` row (phase 4c-2)

The plan says to copy `pending_sign_in` — HMAC-stored, single-use via a
`consumed_at` stamp, short TTL. What shipped is `nonce.userId` in an httpOnly
`SameSite=Lax` cookie scoped to `/integrations`, with no database row at all, and
I am flagging it because it contradicts the plan rather than because I think it
is close.

The two values are not alike. `pending_sign_in` is HMAC'd because it lives in our
database, where a backup or a support query can read it, and because possessing
it grants a sign-in. This one lives only in the user's own browser, grants
nothing on its own, and is compared against a session that is checked
independently. Storing it would add a table, a write on every Connect click, and
a sweeper, to protect a value whose disclosure to its own holder is the normal
case.

Two consequences to accept with it: the TTL is the cookie's `Max-Age` and so is
enforced by the browser rather than by us, and the cookie name is fixed, so two
install flows started in one browser leave only the second one completable.

What would change it: needing to know server-side that a flow was started —
telemetry on abandoned installs, or a rate limit keyed on flow starts. Neither
exists, and the callback does no network work until the state matches, so an
authenticated user looping Connect → callback burns our GitHub budget only by
completing real flows.

### What the drain runner decided for itself (phase 4d)

Five calls inside `github-drain-loop.ts`, none of them forced by the plan.

**Retention runs on every invocation, not on a schedule of its own.** It is one
DELETE along the `[provider, processed_at]` index that removes nothing on a
normal day, and it cannot contend with the drain, which only ever claims rows
whose `processed_at` is null. A second scheduler entry would buy nothing and be
one more thing to forget when the job moves hosts.

**Two bounds, not one: 20 passes and 60 seconds.** The pass count alone does not
bound duration — a pass whose deliveries each hit a slow provider-side write can
take arbitrarily long, and a scheduled job that never exits is one nobody notices
is stuck. Both are checked *before* a pass, so `maxPasses` is passes run rather
than passes plus one, and the clock is never overshot by a whole pass on the way
out. Twenty passes is 20 × `DEFAULT_BATCH_SIZE` deliveries per invocation, well
above anything this repo produces between ticks; neither number is measured
against a real installation, because there is not one yet.

**`backlogRemains` is derived from the stop reason, not re-counted.** A count
after the loop would be a second query answering about a queue that has moved,
and it errs the wrong way: it can say "clear" about a backlog that refilled a
millisecond later. Deriving it errs towards claiming a backlog that has just
cleared, which costs one wasted tick.

**`gaveUp`, not `failed`, is the exit-1 signal.** Ordinary failures stay claimable
and the next tick retries them, so alerting on them pages for every transient
blip, and a job that pages routinely gets muted — at which point the real
failures stop being read too. A total outage still alerts within a few ticks,
once the attempts are spent.

**A bound cutting the run short is a warning, not an exit code.** The next tick
continues from where it stopped; if it never catches up, the deliveries
eventually exhaust their attempts and the `gaveUp` alarm fires anyway.

### `assigned_to_member` quietly changed meaning (phase 6)

It shipped in 4a as the **permissive** reading — any assignee at all — because
"member" was unanswerable without an identity table, and the strict reading in
its absence imports nothing, which is indistinguishable from a broken
integration. Phase 6 makes it answerable, so it is now strict: at least one
assignee resolves to an account member.

Any repository already set to that filter therefore imports fewer issues than it
did yesterday, with nothing telling the user. It is a narrowing applied only on
the way in — nothing already imported stops tracking, because the filter gates
creation and not merges — and on this repo the affected set is zero. It is worth
one line in the settings copy before anyone else is on it, and it is the reason
the filter's default is still an open question below.

### An imported assignee can be nobody, and that is deliberate (phase 6)

Two cases collapse to "external" rather than to a member, and both look like
bugs from the outside:

A GitHub user who has signed into Antgrid but is **not an active member of this
account** does not resolve. That is the tenancy boundary — the alternative
assigns one account's issue to a stranger who happens to share a GitHub login
with somebody, somewhere.

An `externalUserId` claimed by **two** users in one account does not resolve
either. Better-Auth's `account` table has no unique on `[providerId, accountId]`
in this schema, so two rows can name the same GitHub user, and there is no fact
available to pick between them. Assigning a colleague's work to the wrong person
is worse than showing a login. The obvious future edit — take the oldest link, or
the first row — is wrong, and the test named "an identity two members both claim
stays unresolved" is what stops it.

Neither case is surfaced in the UI today. A user who expects their own name and
sees `@their-login` has no way to learn why. That wants a line on the integration
settings page ("sign in with GitHub to be recognised as yourself"), which is not
built.

### `otherAssignees` is computed per task on every list response (phase 6)

The "+n others on GitHub" marker parses `remoteSnapshot` with the provider's Zod
schema for every task in every list, and strips the chosen assignee out of the
array. That is a fixed cost per row, not a scan of the body, and it buys not
having a second table or a denormalized count that can drift from the snapshot it
is derived from. It also means the marker is only ever as fresh as the last
delivery, which is the correct staleness: it describes GitHub, not us.

The provider parser is applied unconditionally, so the day a second provider
lands, this is one of the places that has to dispatch on `externalProvider`
rather than assume GitHub.

### The row carries two different `+n` markers (phase 6, app)

`TaskRow` already collapsed a third label to `+1`. The co-assignee marker is the
same glyph shape with a different meaning, so a task with three labels and one
co-assignee renders `+1 … +1` on one line. They are kept apart only by position
— labels sit left of the assignee, co-assignees immediately right of it — and by
family: the label count is sans (chrome, a count of chips) and the co-assignee
count is mono, matching the `@login` treatment it stands in for.

The alternatives were both worse for a scanning surface: an avatar stack costs
the row's width and implies these identities are addressable, and a labelled
`+2 assignees` costs the line the list exists to be read down. If a third `+n`
is ever added to this row, the shape stops being readable and all three want
distinguishing marks instead.

### Taken provisionally in the conflict-resolve verb

Four calls made in the route and the sheet rather than asked, because none of
them is reversible-cheap once a user has settled a conflict under the old rule.

**One field per call.** `POST /tasks/:number/conflict/resolve` takes a single
`{field, take}` and answers with the whole task. A batch verb would need an
all-or-nothing rule for a partially-unreadable blob, and the sheet has no
"apply" affordance to hang one on — every card acts on its own.

**`take: "local"` on an assignee accepts only the member arm.** The route
re-resolves it under the caller's `accountId` like every other assignee write,
so an external identity cannot be restored. In practice unreachable: a local
assignee only becomes external through an import, and an import writes the
merge base at the same time, so an external local value is never *different*
from the base and never enters the blob. If it ever does, the refusal is
`LOCAL_VALUE_UNREADABLE`, which is an honest code for "this app cannot write
that value" and a confusing name for it.

**`NOT_CONFLICTED` and `LOCAL_VALUE_UNREADABLE` are 409, `LABELS_LOCAL_UNSUPPORTED`
is 400.** The first two describe the row — the entry is already gone, or the
value stored in it no longer parses — and both change when the row changes. The
third describes the request and is wrong every time it is sent. `NOT_CONFLICTED`
is also where a retry of a resolve that already landed arrives, which is the
right answer rather than a lie: the second call is not a no-op, it is a call
about an entry that no longer exists.

**`syncState` only moves for a row currently in `conflict`.** Emptying the blob
on a row that is `pending` must not mark it synced — the push has not happened.
Labels are excluded from `conflictsRemain` for the same reason they never raise
the state: acknowledging them cannot be what returns a task to synced.

### The label drop can outlive the conflict state (conflict-resolve, app)

`labelRemoveWins` is data loss without a choice, so it never sets
`syncState = 'conflict'`. The sheet renders the whole blob, so a task whose
state is `synced` can still show an "Unsettled changes" section holding only the
dropped-label card. That is intended — the loss is worth telling someone about —
but it means the section header is not a rendering of the sync badge, and the
two can disagree on the same screen. The row shows no mark for it at all, so a
dropped label is only ever discovered by opening the task.

### An unknown conflict field is rendered, not dropped (conflict-resolve, app)

`TaskConflictField` accepts any non-empty `field` string and the sheet prints
the wire spelling as its label with the value in mono. Dropping it would put the
task back in the dead end this work closes — a conflict entry nothing can clear
— and the resolve route accepts whatever field name it sent us, so the buttons
still work. The cost is that a future server-side field ships to old apps as a
row labelled `someNewField`.

### Taken provisionally in the outbox write seam (phase 5)

**Two failure vocabularies now disagree on purpose.** `statusFailure` in
`github-app.ts` calls a 401 `refused` — the install flow must stop, because the
user's code or token is wrong. `pushOutcome` in `github-push-policy.ts` calls it
`retryable` — on the drain path it means the installation token aged out
mid-run, which a re-mint fixes. 422 diverges the other way. Both are documented
at both ends, and the drain must consult `pushOutcome` for the retire/re-mint
decision rather than the error's own `failure` field. If that seam ever reads
the wrong one, an op retires on a token expiry or retries a validation error for
ever. Collapsing them into one vocabulary is the alternative, and it means the
install flow retrying a 401 it should stop on.

**A rate 403 is told from a permission 403 by which headers are present**, GitHub
having given both the same status with no machine-readable discriminator. The
rule: `Retry-After` → throttled; `x-ratelimit-remaining: 0` → the primary limit;
rate headers present with budget left → a permission refusal; no rate headers at
all → a secondary limit and the 60-second floor. **The residual risk is
unbounded**: a throttle deliberately does not increment `attempts`, so a
permission 403 that arrives with no rate headers would retry for ever without
the attempt ceiling ever retiring it. The drain phase must therefore cap
*consecutive throttles* per op independently of `attempts` — that is a
requirement this classification creates, not an optional refinement.

**The write budget is a rolling window, not a token bucket.** A bucket cannot
express 500/hour: capacity `C` refilling at `R` admits `C + R·T` in window `T`,
so the only bucket starting full at 500 admits a thousand writes in its first
hour. The window keeps one timestamp per write (≤500 entries) and yields the
exact resume time as the oldest ages out. It is process-local and non-durable,
so every deploy resets every installation to a full burst — tolerable only under
a single worker, which the plan says not to rely on, so persisting it is
outstanding work rather than a nicety.

**`listAppIssuesSince` returns pull requests too**, because `GET /repos/{o}/{r}/issues`
does. Ours will not have authored any in v1, but the day one exists, a payload
that fails `GithubIssueSchema` makes the whole listing throw. That fails closed —
no duplicate is posted — but a create whose response was lost then never resolves
and needs a person. Filtering `pull_request` out of the list, the way the import
filter already does, is the fix and is not built.

### Taken provisionally in the outbox (phase 5)

**A claim leases instead of adding an `in_flight` status.** The advisory lock is
transaction-scoped and the plan forbids holding a transaction across the
provider round trip, so between the claim committing and the call returning the
op is protected by nothing. The claim pushes `nextAttemptAt` five minutes out;
because a task only ever offers its lowest pending `seq`, a leased op makes its
whole task yield nothing until the lease lapses. One fewer state than an
`in_flight` column, and a crashed worker recovers on expiry rather than needing a
sweeper — but a worker that crash-loops retries every lease with `attempts`
never incrementing, which nothing bounds. The drain has to bound it.

**Supersede rewrites the pending op in place, keeps its `seq`, and mints a fresh
`opKey`.** Keeping `seq` preserves the order distinct kinds were enqueued in.
The fresh key is the part worth knowing: it doubles as the version token the
drain's second critical section compares against the op it decided on, so a
supersede landing in the HTTP gap is detectable rather than silent.

**An op with `attemptedAt` set is never superseded.** Its outcome is unknown, and
rewriting it would erase the only evidence a request may have reached the
provider. The new value queues behind it with a later `seq` and still wins under
per-task ordering, at the cost of one extra provider write.

**`attemptedAt` means "the request may have reached the provider", not "was
claimed".** It is written in its own committed transaction immediately before the
call — a timestamp written after the response is exactly the one that is missing
when the response is what got lost. `cancelPendingOps` keys the "keep an
already-attempted create" rule on it.

**A stored payload no schema accepts is given up at claim time**, with
`lastError` set, rather than retried — it cannot start parsing on a later pass.
Same call the inbound side already makes for an invalid delivery.

**An empty claim is not proof of an empty queue.** `limit` is applied before the
try-lock filter, so a pass whose candidate tasks are all held by another instance
claims nothing while a backlog exists. The webhook drain stops when a pass scans
zero rows; the outbox drain must not copy that, or two instances can each
conclude the queue is empty. Nothing is lost — the work waits for the next tick —
but the stop condition has to be written differently.

**Constants**: `MAX_SYNC_OP_ATTEMPTS = 5` (mirrors `MAX_WEBHOOK_ATTEMPTS`),
backoff `30s x 2^attempts` capped at 30 minutes, lease 5 minutes. All exported
and named, none tuned against a real repository yet.

### Taken provisionally when enqueue was wired in (phase 5)

**Resolving a conflict with "Keep mine" is now a provider write.** Nothing else
would ever send it: the outbox is driven by edits, there is no reconcile sweep,
and the resolve deliberately leaves the row ahead of `remoteSnapshot`. A
resolution that queued nothing would be a field the user adjudicated once that
then diverges permanently, and the next inbound delivery (`remote == base`) would
re-raise the same conflict. The cost is that the resolve sheet's copy does not
say a push follows — mitigated only by the write passing the same `pushEnabled`
gate the repo owner already opted into. The copy is worth a line.

**Enqueue is diffed against the row, not driven by which fields the patch
named.** A PATCH restating a value it is not changing is the normal shape of a
form submit, and a write per restatement spends a 500/hour content-creating
budget on nothing. `status` is diffed in **provider space**, which is what makes
`in_progress → blocked` queue nothing — both project onto `open`, and the
automatic status writers only ever move between statuses that share a projection.
An op appearing for one of those is the no-op push loop returning.

**`setTaskLabelsInTx` deliberately does not enqueue** while its public wrapper
does. The in-transaction form has exactly one caller, the inbound importer, and
the set it writes is the one it just merged the provider's own labels into —
enqueueing there pushes the provider's state back at it, which is the loop the
one-way import exists to avoid.

**A revoked integration refuses at enqueue** rather than accumulating ops that
burn `attempts` against credentials that no longer exist. The integration row is
retained on revoke so a task can still say where it came from, so its presence is
not evidence a push is possible — the same `revokedAt IS NULL` rule the inbound
path already resolves installations through.

**`deleteLabel` still enqueues nothing**, and this one is unresolved rather than
decided. Deleting a label cascades it off every task that carried it, including
linked, push-enabled ones — one vocabulary edit becoming an `issue.labels` op per
affected task. Sizing that fan-out against the write budget is a drain-side
question, and the existing comment on `deleteLabel` anticipates a reconcile sweep
rather than an op per task. Until it is answered, deleting a label diverges every
linked task that held it.

**`moveTask` takes no lock and enqueues nothing** — `sortKey` has no provider
projection, and ordering is an Antgrid concept GitHub has no field for.

## The drain's executor — provisional calls

**Two version tokens across the HTTP gap, not one.** `TaskSyncOp.opKey` answers
"did the intent move", `Task.remoteSnapshot` answers "did the base move", and
they are checked separately because the right answer differs. A moved base writes
nothing — folding our older response over a newer inbound merge rolls the shadow
copy backwards. A moved `opKey` still writes the observation, because our push
did land: dropping it leaves the base behind our own write, so the echo of that
write arrives against a stale base and merges as a third party's edit,
manufacturing a conflict out of our own push.

**The pre-push comparison covers title, body, status and labels but not
assignee.** v1 never writes an assignee, so this push cannot clobber one, and
resolving a provider user to a member is a database lookup the HTTP phase
deliberately does not have. `assignee` *is* in the echo hash, so a delivery that
moved only the assignee is merged rather than dropped as our own.

**A base we cannot read is treated as a base that moved.** There is no safe way
to decide a blind PATCH against nothing, so `remoteSnapshot === null` aborts to a
merge — which is also what establishes the base the next attempt compares
against.

**A local refusal closes the op rather than leaving it pending.** `claimNextOps`
only ever offers a task's lowest pending `seq`, so an op left pending for a
condition that will never clear is a permanent head-of-line block on that task.
An unadjudicated conflict is the one exception: it is resolvable, so the op is
deferred ten minutes instead of cancelled.

**`markOpAttempted` is first-write-wins.** The stamp is also the `since` anchor
for resolving a create whose response was lost, and re-stamping it on each retry
walks the anchor past the very issue the listing is looking for — which is how a
duplicate gets posted.

**A create-marker miss does not prove absence**, so the listing window is widened
by 60 seconds of clock skew and a clean miss posts anyway. Refusing for ever
would leave the task unpushable with no way back; at most one duplicate can
follow, because that response *is* observed, the task takes an `externalId`, and
the local guard bars any third. `listAppIssuesSince` fails closed on its page
ceiling, so a short list is never mistaken for a miss.

**A create cannot carry state, so `applyOp` queues it.** `POST /issues` has no
`state` field — a task published closed comes back open. The follow-up
`issue.state` op is enqueued in the same critical section that records the
create, rather than left to the publish path, because that is the only point
where the intent and the response are both in hand. It also means a create never
records a status no-effect: nothing asked for the state, so nothing declined it.

**`Task.pushBlocked` has no expiry, and that is the decision.** A timer restarts
the loop on its own schedule, which is the failure being prevented. A push that
finally takes effect clears the entry; otherwise a person clears it through
`clearTaskPushBlock`, through `POST /tasks/:number/push-block/clear`.

## The drain loop — provisional calls

**Two consecutive empty passes, not one, and a pause between them.** The inbound
webhook drain stops the moment a pass claims nothing; the outbox drain cannot,
because `claimNextOps` applies its `limit` before the try-lock filter, so a pass
whose candidate tasks are all held elsewhere claims zero rows while a backlog
exists. Copying that stop condition lets a second instance silently truncate the
first's work every time the two overlap. The pause is load-bearing rather than
decoration: without it the second pass is the same observation as the first,
taken microseconds later while the contending claim transaction may still be
open. The stop reason is named `idle` rather than `queue_empty` because
"nothing was claimable" is the strongest claim the query supports.

**Three consecutive throttles per op, per invocation.** A genuine throttle sets a
retry time past the end of the invocation's wall clock, so a *second* throttle of
one op inside one invocation already says the wait it was given was not a wait. On
hitting the cap the op is pushed out by the failure backoff's own ceiling through
`throttleOp`, never `failOp` — the op may be perfectly valid, and a wait is not
an attempt.

**A local budget refusal ends the invocation rather than counting against the
op.** It is this process pacing itself, not the provider refusing this write.
Nothing later in the pass can pass a budget the first op just failed, and the
rolling window outlives the wall clock, so continuing would only claim ops in
order to defer them.

**The exit code fires on `gaveUp`, `refused` or `throttleCapped`, and on nothing
else.** All three are terminal for a user's edit. Ordinary failures are excluded
deliberately: they stay claimable and the next tick retries them, so alerting on
one pages for every transient blip — and a job that pages routinely gets muted,
at which point the terminal conditions stop being read either. A total outage
still alerts within a few ticks once the attempts are spent. **A missing GitHub
App config exits 0**, because a deployment without one has no outbox at all.

**The writer resolves its credentials lazily.** Minting before `applyOp` runs
would turn a revoked installation's clean cancellation into five failed attempts
and a `given_up` row — `applyOp` cancels those before any request exists. The
loop still owns the cache and memoizes the *rejection*, so one blip fails that
integration for the rest of the invocation rather than being retried per op.

**Ten ops a pass times eight passes is eighty a minute**, chosen to land on
GitHub's 80 content-creating writes/minute burst ceiling at a one-minute
schedule. Neither number is measured against a real installation, because there
is not one yet.


## The push-block exit — provisional calls

**Clearing a block also re-queues the value, undiffed.** Lifting the marker
alone changes nothing anyone can see: the op that carried the field was
cancelled when the block was read, and the outbox is driven by edits, so a task
nobody touches again would sit unblocked and still unsynced. Diffing against the
row before queueing would be worse than useless — what is re-sent is by
definition a value the row already holds and the provider does not, so the diff
finds nothing and the button becomes decorative. The re-queue goes through
`enqueueForTask`, so `resolvePushTarget`'s four refusals (unlinked, `pushEnabled`
off, repo on another account, integration revoked) all still apply: the button
cannot reach a repository the account may not write to.

**One field per call.** Each block is a separate judgement about a separate
value, and reading one field's explanation is not entitlement to restart the
others. Same shape as the conflict resolve beside it, and for the same reason.

**A field under the threshold cannot be cleared, and is not reported.** It is
still being pushed; naming it would tell a user a value stopped syncing while it
is on its way, and clearing it would reset a count that is doing its job.

**`NOT_BLOCKED` is a 409, not a 404 or a 200.** The request is well-formed and
the caller is entitled to every id it named; what refuses it is the state of the
blob — which a push that finally landed, or another device, may have changed a
moment before the tap. A 200 would let a stale client believe it had just
restarted something.

**Clearing restarts the count from zero rather than resuming it.** The entry is
removed outright, so a field the provider keeps declining needs a further three
no-effect pushes to re-block. That is the point: a person who has read the reason
and acted on it (granted the missing access, say) should get a full account of
whether it worked, not one attempt on a nearly-spent counter. The cost is that a
user who taps without changing anything spends three writes to learn nothing new.

**The block is rendered in field-enum order, by the server.** `jsonb` does not
preserve key insertion order, so the column cannot supply an order at all and two
reads of the same row could differ. The app reads the order off the payload
rather than sorting again, which also keeps a field name this build predates in
its right place instead of at one end.


## The publish path — provisional calls

Recorded before the code, because these are the shape the server and the app
were built against at the same time rather than conclusions drawn from either.

**`publish` is a required boolean on `POST /tasks`, and `publishNewByDefault` is
never read on that path.** The plan already fixes this; what is worth recording
is that it survived contact with the create route, where a `.default(false)`
would have been the obvious Zod spelling and would have been wrong. A default
means an older app build, a proxy that drops a field, or any non-form client
publishes by omission — the one unrecoverable failure the section exists to
prevent. The setting positions a visible control and nothing else.

**A publish target must have `pushEnabled`, not merely `syncEnabled`.** Offering
a repository that cannot be written to would show a toggle whose outcome is a
silent cancellation: `applyOp` drops an `issue.create` when `pushEnabled` is off,
so the user would consent to a publish, see `pending`, and never learn it went
nowhere. The offer point and the send point have to agree about consent or the
consent is decoration.

**The destination resolves through `IntegrationRepo.projectId`, never through a
`repoKey` join.** `Project.repoKey` comes from `git remote get-url origin` on a
developer's machine and a device can assert any origin for any folder; matching
it against `IntegrationRepo.repoKey` would let a client aim a publish at any
repository in its own account by renaming a remote. `IntegrationRepo.repoKey` is
provider-sourced and stays trustworthy for *addressing* a repo once chosen —
which is why `applyOp` may still call `githubRepoFromKey` on it — but it is not
how the choice is made.

**Publishing clears every trace of a previous link, in the same transaction.**
Re-publishing an unlinked task creates a *second* issue, so `externalId`,
`externalKey`, `externalUrl`, `externalProvider`, `remoteSnapshot`, `pushedHash`,
`localConflict` and `pushBlocked` all go to NULL before the create is queued.
Two of those are load-bearing rather than tidy: `enqueueSyncOp` refuses an
`issue.create` while `externalId` is non-null, and a surviving `remoteSnapshot`
would make the new issue's first import merge against the old issue's state.
The tombstone the unlink left is read by the confirm sheet *before* the publish,
which is the only moment it is worth anything.

**Unlink does not cancel pending ops.** `applyOp` already drops an op whose task
is unlinked, at send time, as part of the consent re-check the publish path
needs anyway. A second cancellation path would be a second place for the two to
disagree about what "withdrawn" means.

**`source` is never touched by a publish.** It records where the task was born,
not where it now lives — a task published from Antgrid stays `local` for ever,
and the provenance line says so.

**Ambiguity is a refusal, not a pick.** One qualifying target is preselected;
several is `PUBLISH_REPO_AMBIGUOUS` until the caller names one. Choosing the
first, the newest, or the alphabetically-first would publish to a repository
nobody pointed at, and the whole section turns on the user having seen the
destination.

**Settled during review, after the contract above.**

**`already_linked` fires on `pending`, not only on a non-null `externalId`.**
A create already in the outbox has no issue identity yet — the drain writes it
back only after the response — and an op whose first attempt was handed to the
provider is never superseded. Keying the guard on `externalId` alone would let a
second press queue a second `issue.create` behind an unknown outcome and post a
duplicate public issue. The app makes the same call independently, in
`Task.isPublishable`, so the button is gone before the refusal is needed.

**Consequently unlink accepts a `pending` task.** It is the only kill switch
between the button and the post, and it costs nothing: `applyOp` then drops the
op on the same consent re-check it already runs.

**A named `repoId` against a project with no targets at all answers
`PUBLISH_NOT_AVAILABLE`, not `PUBLISH_REPO_NOT_FOUND`.** Both are true and the
contract did not order them. The user-facing difference is real — one says "this
task has nowhere to go", the other "not that repo" — and the first is the more
useful sentence when there is nowhere at all.

**Publishing refuses a device credential (`PUBLISH_REQUIRES_SESSION`, 403).**
The plan asked for cookie-only or a distinct scope on publish-capable routes as
belt and braces, and the task router's own doc comment already promised the
lever: only the Bearer gate sets `deviceId`. The required `publish` field is the
primary defence and holds whatever the carrier, but it records an intent rather
than proving who formed it, and `requireBearerJwt` blanks `sessionId`, so nothing
else separates a person from an agent driving the bridge. It costs the app
nothing — it is already on the cookie. Unlink and the targets read stay open:
neither writes to the provider.

**The create form's default may position the toggle only over an empty body.**
`publishNewByDefault` positions a visible control, but filing a half-written
private note against a project must not flip a switch nobody touched, so the
default applies only to a project chosen before there was anything to publish.
Several targets means no default at all and a switch that cannot be turned on
until a repository is named.

**`TaskSyncStateSchema` moved to `tasks/sync-state.ts`.** `models/task.ts`
imports `sync-op.ts`, `push-blocked.ts` and `publish.ts`, so none of them could
import the vocabulary back and each restated the one or two values it needed with
a "keep in lockstep" comment. Three spellings of one enum, and a rename would
still type-check against every string literal. `models/task.ts` re-exports it, so
nothing that already imported it changed.

## The project list — provisional calls

**`GET /account/projects` lives in `routes/projects.ts`, not under `/tasks`.**
It reads the same rows the bridge writes bindings against, and the task surfaces
are simply its first reader. Putting a projects read under `/tasks` would have
made the tasks router the owner of a table it does not own.

**It takes a session cookie or a device Bearer.** The bindings POST beside it is
bridge-only, because only the machine holding a checkout can say where it sits.
Reading which projects exist is not that: the app needs it to label a task and to
offer the create form's picker, and the bridge is already entitled to every row
it would return — it wrote them. A cookie-only gate would have bought nothing and
left the machine that binds a project unable to read back what it bound.

**Scoped by `findActiveMembership`, never by an owner fallback.** A user acting
on a team must not be shown their personal account's projects: filing a task
against one would put it where the team cannot see it. No membership is a 403
`NO_ACCOUNT` rather than an empty list — an empty list would read as "your
account has no projects yet", which is a different and wrong sentence.

**Bindings stay off the wire.** They are per-machine and say where a checkout
sits, which is not a thing a task cares about. `repoKey` ships as the label of
last resort: `displayName` is whatever a machine reported when it bound its
checkout, so a row can arrive with nothing usable in it, and a blank entry in the
picker is unpickable.

**Two projects with the same `displayName` are still indistinguishable in the
picker.** The map that feeds it is name-only, and appending the repo to
disambiguate would also lengthen the label on every task row, which is the dense
surface. Left as it is, and recorded here rather than silently.

**`taskProjectNamesProvider` still answers the empty map while the list is in
flight or refused.** Three list surfaces label a task with it while they build,
so it cannot be async and it cannot throw; those callers already fall back to the
short uuid in mono. Riverpod retries a failed provider with backoff, which is
also why the test for the refused case reads the provider's state rather than
awaiting its future — that future never settles.

## The outbound consents get a control — provisional calls

Phase 5 shipped both halves of outbound behind `IntegrationRepo.pushEnabled` and
`publishNewByDefault`, both defaulting to false, and nothing in the product could
turn either on: the settings page rendered neither and its save route read
neither. The model layer (`setRepoSyncSettings`) already accepted both, so the
whole outbound half was built and unreachable.

**The two toggles live in the form that already saves the import settings**, not
in a form of their own. That route is documented as the only browser writer of
the per-repository consents, and a second form would mean a second writer, a
second htmx swap, and two ways for the row on screen to disagree with the row in
the table.

**Push off disarms the publish default in the same write.** Left set, switching
push back on later would arm publishing-by-default on a consent given for a
repository nobody was writing to. The disabled attribute on the input is the
courtesy version of the same rule; the pairing in the route is the one that
holds, and there is a test that posts the default without the push box to prove
it.

**The consequence copy names the fields that actually travel** — title, body,
state, labels — because that is the closed set the outbox can carry, and a vaguer
sentence would leave a reader guessing whether comments or assignees go too. Two
sentences are conditional: a public repository says that filing is public
immediately and deleting the task does not take it back, and a repository no
project is matched to says there is nowhere to file from yet.

**A repository with no `projectId` still gets the toggle.** Push covers edits to
tasks already linked by an import, which works with no project link at all; only
publish needs one. Hiding the switch would hide a working feature to prevent a
confusion the sentence beside it already answers.

**Two phase-6 copy gaps closed with it**, both recorded above as "worth one line"
and not built: `assigned_to_member` now says a person counts only once they have
signed in to Antgrid with GitHub, and each connection says an unmatched assignee
renders as their login. The first is rendered always and merely hidden, so the
select's own handler can surface it the moment the reader picks that filter
rather than one round trip later.

**`EmptyCard` no longer promises a one-way integration.** It said "nothing you
write here is posted back", which stopped being true when phase 5 landed and was
being read by exactly the person deciding whether to connect.

**Turning push on flushes nothing.** The outbox is driven by edits — every
`enqueueForTask` call sits on a write path in `models/task.ts` — so a repository
switched on today pushes the next change to a task, not the divergence it already
carried. That is the conservative reading of the consent: the user agreed to
Antgrid writing from now on, not to it reconciling a backlog they never saw. The
opposite behaviour would also be the more dangerous one to get wrong, because the
first thing it does is a fan-out of blind PATCHes.

## The reconcile poll — provisional calls

Phase 5's last bullet. `importIssue` was private to the webhook drain, so a
repository switched on imported nothing until somebody touched an issue, and a
delivery lost to an outage or to `MAX_WEBHOOK_ATTEMPTS` was gone for good.

**One walk, not two.** The first import and the repair differ only in where they
start — `lastCursor: null` against a stored cursor — so they share an
implementation. Two would drift, and the one that drifts is the one nobody runs
in development.

**Ascending order, and the whole cursor scheme rests on it.** `direction=asc` on
`GET /issues?sort=updated` makes any partial walk a prefix: a run stopped by the
page ceiling, the wall clock or a rate refusal still leaves a cursor everything
before which is done. Descending order cannot advance a cursor until the entire
walk completes, so a repository with more issues than the ceiling would re-read
its first pages for ever and never record progress.

**A 60-second overlap on resume.** `since` has one-second resolution and is
evaluated against GitHub's clock, so a bare cursor drops any issue whose edit
shares its second or falls inside the skew. The trade is asymmetric: re-listing an
unmoved issue costs one page slot and writes nothing, because the merge sees
`remote == base`; missing one is silent, permanent, and only ever noticed by the
person whose issue never appeared.

**The cursor never moves backwards, and stops at the first unreadable
timestamp.** The overlap makes a page legitimately end earlier than the stored
cursor, so a bare "write the last item's time" would walk the repository
backwards on every tick. And `updated_at` is nullable in the schema we accept —
advancing past an item we could not parse would skip it for ever, while not
advancing costs a re-list the overlap already pays for.

**`lastFullSyncAt` only on a short page.** It is the one ending that proves the
repository is fully read. A page ceiling, a time budget and a rate refusal are all
prefixes, and writing completeness there is a claim a later feature would read and
act on.

**Import goes through the drain's own `importIssue`, exported rather than
copied.** The `[accountId, externalProvider, externalId]` lookup, the
`taskimport:` lock, the import filter, the tombstone filter and the assignee
resolution are the whole idempotency mechanism. A second implementation is two
answers to "have we seen this issue" that can drift apart without anything
failing.

**The `ghpoll:` claim lock covers the claim, not the walk.** A transaction cannot
be held across a provider round trip — that is how a pool is exhausted by a
hanging remote — and `pg_try_advisory_xact_lock` cannot outlive its transaction.
So it collapses two runners that arrive at the same repository at the same
instant, which is what a scheduler overlap actually produces, and nothing more.
The durable guard against one issue becoming two tasks stays where it already
was. `ghpoll:` is outermost in the lock order and in practice disjoint from it.

**A read spends the points budget, never the write budget.** The poll creates no
content, and charging it against the 500-writes-an-hour ceiling would starve the
outbox of what a user's edit needs.

**`etag` is left alone.** Conditional requests are an optimisation, and one got
wrong stops a repository importing without failing anything.

**Still open here:** nothing schedules `poll:github` — like both drains it is
external cron, recorded above. There is no minimum re-poll interval, so a
caught-up repository is re-listed every tick; that costs one page returning
roughly nothing, and a real interval wants a measurement nobody has yet. And
`githubPollNeedsAttention` pages on a `refused` repository every tick until
somebody fixes access, which is deliberate — a repository that has quietly
stopped importing produces no other signal — but it is the kind of alarm that
gets muted.

## What the review pass found — fixed, and deliberately not

A full read of the branch's source after the last commit. Three defects fixed,
three left standing because each is a product call rather than a bug.

**Fixed: one issue's throw no longer ends the invocation.** Both
`db.$transaction(importIssue(...))` inside a walk and `pollRepo` inside
`pollDueRepos` were unguarded, so a serialization failure or a connection blip
on a single issue abandoned every repository behind it in the due order — the
same starvation `unroutable` is counted rather than thrown to avoid. Each is now
its own ending. The walk returns without advancing over the item that raised,
and the next run re-lists from the last committed cursor.

*The cost, taken knowingly:* a throw that used to reach the script now becomes an
`error` report, and `githubPollNeedsAttention` excludes `error` — so it no
longer sets exit 1. A database that is down entirely still exits non-zero,
because `dueRepos` runs before any catch. What is now silent is a throw that
repeats on the same issue every tick: it blocks that repository's walk at a fixed
cursor for ever, and only the logged report says so. Whether that deserves the
exit code, or a stop reason of its own separating an import throw from a
transient 5xx read, is open.

**Fixed: the `invalid` exit-code comment was arguing from a false premise.** It
claimed the condition "replays identically on every tick". It does not — the walk
calls `advanceCursor` after an `invalid` outcome exactly as after a success, so
the cursor moves past the refused issue and it is never listed again. The alert
is ONE-SHOT and the issue silently never becomes a task, which makes the exit
code more load-bearing than the comment claimed, not less. The advance itself is
left alone: not advancing would stall the walk on that issue permanently.

**Fixed: the outbound consent toggles did not save themselves.** The row form
auto-submits on `change from:find [data-autosave]`, and htmx's `find` resolves to
the FIRST match alone — so the two toggles added below the import one bound no
listener, and were saved only by the Save button, which sits *above* them. A
reader who switched "send changes back" off and left had revoked nothing. The
trigger is now scoped to the row id with htmx's parenthesised selector escape,
which binds all three. Typed and picked filter fields still wait for Save.

**Not fixed — `isLinked` is narrower in the app than on the server.** The server
counts `pending` as linked; the Dart extension does not. While an `issue.create`
sits in the outbox the detail view therefore offers neither Publish nor Unlink,
even though the service would accept the unlink and cancel the queued create. So
a user who realises they published to the wrong repository waits out the drain.
`app/test/models/task_test.dart` pins the current behaviour, which makes widening
it a decision rather than a correction.

**Not fixed — an edit made during the publish window is dropped.**
`publishTaskInTx` nulls `externalId`, so `resolvePushTarget` returns null and
`enqueueForTask` queues nothing until the drain writes the identity back;
`buildCreate` then posts the publish-time title and body. Fix a typo in the title
before the next tick and the issue keeps it for ever, with `remoteSnapshot` set
from the create response and no conflict raised. The fix is for the outbox to
accept ops on a pending task ordered behind the create, which is a real change to
the claim ordering and not one to make unreviewed.

**Not fixed — a repository that can never complete holds its slot.** `dueRepos`
orders `lastFullSyncAt asc nulls first`, and that column is written only on a
short page, so a repository stuck on `refused` or `unroutable` sorts first for
ever and is re-attempted every tick. Full starvation needs as many permanently
failing repositories as the per-tick ceiling (25); below that, healthy ones still
rotate through the remaining slots. The honest fix is a `lastPolledAt` column
breaking the tie among never-completed repositories — additive, but a migration
added to a branch already under review.
