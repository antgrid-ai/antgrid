# Tasks & issue-tracker integrations — design plan

Status: proposal. Target: v1 dogfooded on `antgrid/antgrid`, GitHub Issues only,
schema and provider seam built for Linear/Jira next.

## Decisions locked

| Question | Decision |
|---|---|
| GitHub credential | **GitHub App**, not the sign-in OAuth token |
| Body text in our DB | **Yes** — full body stored, so mobile/offline works |
| Sync direction | **Bidirectional.** *Which* writes ship in v1 is open — see "Recorded decision" at the end |
| Task ownership | **Account-scoped**, project binding optional |
| Assignment | Required in v1 — both human assignee and run target. **One** human assignee, never pushed to the provider (see Assignment) |
| Comments | **Inbound-only in v1.** Imported comments mirror and de-dup; an Antgrid-authored comment stays in Antgrid (see Publishing) |
| External identity | **On the `Task` row, no link table** — `@@unique([accountId, externalProvider, externalId])` is the sync key |
| Webhook routing key | **`Integration.installationId`**, globally unique per provider, `revokedAt IS NULL` — never `externalAccountId`, which is unique only within an account |
| Task-route credential | **Cookie from the app and browser, Bearer from the bridge.** The carrier is the only actor-type signal the server has (see Auth) |
| Future providers | Provider seam from day one; the external columns are provider-agnostic, and no `github_*` column exists anywhere |
| Handler mapping | **None.** No code path between tasks and `bridge/src/handler/` |
| Notifications | **Deferred** until everything else ships — badge/count only, no push, no email |
| UI surfaces | **Both** the Flutter app and the web UI; views, labels, status, detail and edit in each (`docs/tasks-ux.md`) |

## Why this is not just a GitHub client

The product claim is *pick a task → it becomes an isolated agent session*. That
path already exists: `session:create` takes `isolation:"worktree"` + `baseBranch`,
and `session:start` takes a one-shot `initialPrompt` that becomes per-agent spawn
argv in terminal mode or the first user turn in chat mode (`initial-prompt.ts`).
Everything below exists to feed that call. If a phase does not move a task closer
to a running session, it is not v1.

## Constraints discovered in the tree

1. **`projectId` is machine-local.** `computeProjectId` is
   `sha256(realpath(folder)).slice(0,16)` (`bridge/src/project-id.ts`). Same repo
   on two machines → two ids; moving the folder changes it. Web has no project
   table at all.
2. **No remote *URL* is read anywhere.** `bridge/src/handler/snapshot.ts` does
   read remote *names* — `@{upstream}` and `git ls-remote` — but no code in
   `bridge/src`, `app/lib`, `web/src` or `relay/src` resolves an origin URL, and
   `agent:projects` advertises `projectId`/`label`/`path` with no repo identity.
   Repo identity is the only genuinely missing primitive.
3. **No background worker in web.** Bidirectional sync needs a drain loop and a
   reconcile poll; neither has a home today.
4. **Web cannot originate a push.** Push payloads are sealed bridge→phone
   (`bridge/src/push/seal.ts`); relay `/internal/*` is revoke/connections/expire.
5. **OAuth tokens are stored plaintext.** No `encryptOAuthTokens` in
   `auth/better-auth.ts`. Reinforces the GitHub App decision — installation
   tokens are 1-hour and re-mintable, so nothing long-lived lands in `account`.
6. **`backlog` is taken.** `bridge/src/handler/backlog.ts` is the Handler's
   within-session instruction stack with self-certifying transitions. It is
   **persisted** — `engine.ts` writes it through `session-store.ts` and rehydrates
   on restart; only `floorWarnings`/`auth`/`limitParks` are non-persisted — so
   "durable vs ephemeral" is not the distinction. The real one is ownership and
   scope: a backlog belongs to one agent in one session, a task is user-owned and
   spans machines. Keep the words apart in code and UI ("Tasks" vs "Handler
   backlog"); they marry later (a task seeds the Handler's initial instruction
   set), not in v1.

## Data model

All tables account-scoped, following the existing conventions: camelCase fields
with snake_case `@map`, `@db.Timestamptz(6)`, uuid PKs via
`dbgenerated("gen_random_uuid()")`.

### Project identity

```
Project            id, accountId, repoKey, displayName, createdAt, updatedAt
                   @@unique([accountId, repoKey])
ProjectBinding     id, projectId, deviceId, localProjectId, localPath, lastSeenAt
                   @@unique([deviceId, localProjectId])
```

`repoKey` is the normalized origin remote — host + owner + name, lowercased,
`.git` stripped, scp-form (`git@github.com:o/r.git`) and https folded to one
form: `github.com/antgrid/antgrid`. A repo with no origin gets a synthetic
`local:<deviceId>/<localProjectId>` key so tasks still bind; it simply never
gains an integration link.

`ProjectBinding` is written by the bridge over its existing Bearer-JWT path
(same gate as `/account/devices/me/heartbeat`). This is what makes a task
survive a folder move and follow you between machines.

**That `@@unique` is global, but a device uuid is not.** `deviceId` is chosen by
the client at registration and the database only holds it unique *per user*
(`devices_user_id_device_id_key`), so two accounts can legitimately present the
same `(deviceId, localProjectId)` pair. A plain upsert on the pair therefore lets
the second caller silently re-point the first account's binding at its own
project — a cross-tenant write through an index, with no foreign key involved to
catch it. The bind must read the existing row first, refuse when its project
belongs to another account, and hold
`pg_advisory_xact_lock(hashtext('projectbind:' || deviceId || ':' || localProjectId))`
across the check, or the refusal is simply raced by the caller it exists to
refuse. This is the only place that tenancy can be asserted for the pair, since
the index is what makes it addressable at all.

**The bearer middleware surfaces a device identity, and it is a lookup key
rather than an assertion.** `web/src/auth/oauth-provider.ts` mints `deviceUuid`
into every `client_credentials` JWT, and `requireBearerJwt`
(`web/src/auth/jwt-bearer.ts`) re-resolves it as
`device.findFirst({ userId: uid, deviceId: claims.deviceUuid, revokedAt: null })`
before setting `deviceId` — so a claim naming a foreign or revoked device fails
the gate rather than reaching a route. That is what makes it safe, and it is the
whole of what is safe: **the claim is never evidence on its own.** A route that
read `payload.deviceUuid` without that scoped re-resolve would be trusting the
token to name its own owner.

A `deviceUuid` in a *body* is still untrusted and still has to be proven the way
the heartbeat route proves it:

```ts
const result = await db.device.updateMany({
  where: { userId, deviceId: body.deviceUuid, revokedAt: null }, …
});
if (result.count === 0) return c.json({ error: "NOT_FOUND" }, 404);
```

The two cases differ in what the body's id *means*. `POST /account/projects/bindings`
lets the caller name a **target** machine, so the body's id is the write key. The
run-report route (`POST /tasks/:number/runs`) is a machine reporting its **own**
work, so the write key is always `c.get("deviceId")` and the body's `deviceUuid`
is compared with it and otherwise unused — a bridge sending someone else's id
gets a `403 DEVICE_MISMATCH` instead of quietly filing its work elsewhere.

**The invariant, stated once and applying to every id, not just devices:** *no
task route accepts a foreign key it did not re-resolve under the caller's
`accountId` (or `userId` for device-owned rows).* Prisma foreign keys enforce
**existence, not tenancy** — a `projectId` from another account is a perfectly
valid FK. Every one of these is client-supplied and crosses an account boundary:

| Field | What a missing scope check gives an attacker |
|---|---|
| `Task.projectId`, `Task.runTargetProjectId` | Bind a task to another account's project |
| `TaskLabel.labelId` | Leak account B's label names into A's UI **and push them into A's GitHub repo** |
| `Task.integrationRepoId`, `TaskSyncOp.integrationId` | Drive writes through another account's installation |
| `Task.assigneeUserId` | Assign a non-member |
| `runTargetDeviceId`, `TaskRun.deviceId` | Target another user's machine |

Two specific traps. `@@unique([accountId, number])` plus "do not expose uuids"
makes the API surface `/tasks/ANT-14` — a small sequential key, so any
where-clause missing `accountId` is immediately enumerable rather than
theoretically exploitable; always `findFirst({ where: { accountId, number } })`.
And **"assigned to me" must still anchor on `accountId` first.** Folding the
assignee onto `Task` (below) turns that from a join into a one-line filter —
`where: { accountId, assigneeUserId: userId }` — which also makes the *wrong*
query easier to write, because `assigneeUserId` alone now looks sufficient. It is
not: without `accountId` it returns a former employer's tasks the moment the
user's membership closes.

### Tasks

```
Task   id, accountId, projectId?, number, title, body, status, priority?,
       sortKey, source, runTargetDeviceId?, runTargetProjectId?,
       -- assignee: exactly one of the two identities, never both
       assigneeUserId?, assigneeExternalId?, assigneeLogin?, assigneeAvatarUrl?,
       -- external identity + sync state, flattened onto the row (no link table)
       integrationRepoId?, externalProvider?, externalId?, externalKey?,
       externalUrl?, remoteSnapshot Json?, localConflict Json?, pushedHash?,
       remoteUpdatedAt?, syncedAt?, syncState?, syncError?,
       createdBy, createdAt, updatedAt, closedAt?, deletedAt?
       @@index([accountId, status])
       @@index([accountId, projectId, status])
       @@index([accountId, assigneeUserId, status])
       @@unique([accountId, number])
       @@unique([accountId, externalProvider, externalId])
       -- RAW SQL:
       -- CHECK (assignee_user_id IS NULL OR assignee_external_id IS NULL)
```

**There is no `TaskLink` table.** External identity lives on the task row, one
provider per task, and `@@unique([accountId, externalProvider, externalId])` is
the whole inbound idempotency mechanism: every inbound path is an upsert on that
key. This is Superset's model (see the appendix) and it deletes a table, a
partial unique index, a join on every read, and the "one live link per (taskId,
provider)" invariant that had nowhere enforceable to live.

Three consequences, all accepted deliberately:

- **A task can be linked to at most one issue, ever.** No mirroring one task into
  two trackers, no linking a task to both an issue and a PR. Nothing in v1 wants
  that, and re-introducing a link table later is a mechanical migration.
- **`@@unique` over three nullable columns constrains nothing for local tasks** —
  `NULL != NULL`, so unlimited rows with all three null are permitted. That is the
  desired behaviour *here* and it is the exact behaviour called out as a bug under
  Labels; the difference is that unlinked tasks genuinely have no identity to
  collide, whereas two account-wide labels named `bug` genuinely do.
- **`integrationRepoId` is ours, not Superset's.** They can omit it because one
  Linear connection is one workspace; a GitHub installation spans many repos, so
  the push path needs to know which one without re-deriving it from `projectId`
  (a project's repo binding can change; the issue's cannot).

**Unlink keeps the columns as a tombstone.** Setting `syncState = 'unlinked'` and
leaving `externalId`/`externalUrl` populated is what lets the UI say *previously
linked to #123* and lets the publish confirm warn that a re-publish creates a
second issue. Every inbound path therefore filters `syncState <> 'unlinked'` as
well as `deletedAt IS NULL` — finding the row and ignoring it is the point — and,
one hop up, `Integration.revokedAt IS NULL` (see Integrations, where that filter is
the tenant boundary). Re-publishing overwrites the tombstone with the new issue's
identity.

- **Assignment is a single column pair, not a set.** `assigneeUserId` when the
  assignee is an account member; `assigneeExternalId` + `assigneeLogin` +
  `assigneeAvatarUrl` as a read-only snapshot when the provider's assignee maps to
  no member. Setting the internal one **clears all three snapshot fields** in the
  same write — that invariant is the only thing keeping the two from disagreeing,
  and it belongs in the mutation, not in a comment.
  **GitHub allows up to ten assignees and we store one**; what that costs, and why
  it does not cost data loss, is in Assignment below.
- `number` is a per-account monotonic display id (`ANT-14`), assigned under the
  same `pg_advisory_xact_lock` pattern `checkCapAndUpsert` already uses — but
  **namespace the key**: `hashtext('task:' || accountId)`, following the billing
  code (`hashtext('billing:' || accountId)`) rather than `models/device.ts`'s
  bare `hashtext(userId)`. `hashtext` returns an int4 into one *global* advisory
  namespace, so an un-namespaced key makes task-number allocation contend with
  device registration on collision. Do not expose uuids in UI.
  **Bulk import does not walk this path** — see Scale.
- `status` is an **Antgrid** vocabulary, not a passthrough:
  `open | in_progress | blocked | done | cancelled`. Provider mapping lives in
  the provider adapter (see below). GitHub cannot represent `in_progress` or
  `blocked`, which is precisely why we do not mirror its vocabulary.
- `source` is `local | github | linear | …` — which system the task was born in.
  It never changes, and it is *not* the same as "has a link".
- `sortKey` is a fractional-index string (lexicographic midpoint), so a drag
  reorder is one row write and never a renumber.

### Labels

```
Label      id, accountId, projectId?, name @db.Citext, color, description?,
           createdAt
           @@unique([accountId, projectId, name])
           -- plus RAW SQL, for the account-wide rows the @@unique cannot reach:
           -- UNIQUE (account_id, name) WHERE project_id IS NULL
TaskLabel  taskId, labelId
           @@id([taskId, labelId])
```

Two constraint details that are easy to get wrong and expensive to discover:

- **`name` is `@db.Citext`**, matching the schema's existing convention for
  case-insensitive identity. Plain Postgres text is case-*sensitive*, so `Bug`
  and `bug` become two local rows mapping to one GitHub label and the
  element-wise diff below oscillates between them forever.
- **`@@unique([accountId, projectId, name])` does not constrain account-wide
  labels at all.** `projectId` is nullable and `NULL != NULL` in Postgres, so
  that index permits unlimited duplicate `('acct', NULL, 'needs-triage')` rows.
  Either `NULLS NOT DISTINCT` (PG15+) or the partial unique above.

GitHub-compatible on purpose: `name` + 6-digit hex `color` + optional
`description` is exactly GitHub's label shape, so import and push are a straight
copy with no lossy mapping. `projectId` is nullable because a label can be
account-wide (`needs-triage`) or repo-specific (`area/relay`); GitHub labels
always import project-scoped, since that is how GitHub scopes them.

**The colors are not usable as backgrounds.** GitHub label hexes are chosen
against GitHub's near-white surface; both of our surfaces are dark. Rendering
`#0e8a16` or `#ffffff` as a chip fill gives unreadable or garish results.
Rendering rules are in `docs/tasks-ux.md`; the storage layer keeps the hex
verbatim so the round-trip to GitHub is exact.

### Integrations (provider-agnostic)

```
Integration          id, accountId, provider, externalAccountId, installationId,
                     displayName, status, installedBy, createdAt, revokedAt?
                     @@unique([accountId, provider, externalAccountId])
                     @@unique([provider, installationId])
IntegrationRepo      id, integrationId, repoKey, externalRepoId, projectId?,
                     visibility, syncEnabled, pushEnabled, publishNewByDefault,
                     importFilterKind, importFilterValue?, commentImportCap,
                     lastFullSyncAt?, lastCursor?, etag?
                     @@unique([integrationId, repoKey])
                     @@unique([integrationId, externalRepoId])
```

**`installationId` is a separate column from `externalAccountId`, and its unique
is global.** They are different identities: `externalAccountId` is the GitHub
account the App was installed on, and `installationId` is that particular
installation of it — the two diverge on uninstall-then-reinstall and on org
transfer. Only the installation id can route an inbound webhook, because an
inbound webhook carries **no `accountId` to scope the lookup by**; that is the
whole point of routing by installation. `@@unique([accountId, provider,
externalAccountId])` is unique only *within* an account, so resolving a webhook
through it is unscoped by construction — two Antgrid accounts may legitimately
hold the same `externalAccountId`, and the lookup picks whichever row it finds.

That is a cross-tenant write, and the ordinary lifecycle produces it. Account A
connects org X and later uninstalls — `revokedAt` set, rows retained by design.
Account B installs the App on org X. B's issue and comment payloads resolve
through A's stale row and are written into A's account: a third party's private
issue bodies in the wrong tenant. So:

- `installationId` carries `@@unique([provider, installationId])` — installation
  ids are globally unique per App, and this is the **only** key a webhook may be
  resolved by. Keep `externalAccountId` for display and for the install flow. The
  column is nullable, because a provider without an install concept (Linear, Jira)
  has nothing to put in it, and Postgres treats NULLs as distinct in a unique index
  — so the constraint costs those providers nothing. Each of them then needs its
  *own* globally-unique inbound key named before its webhook handler ships; the
  rule is "route by something unique outside the tenant", not "route by
  `installationId`".
- **Every inbound resolution filters `revokedAt IS NULL`.** A revoked row must
  never match a live payload; dropping that filter is what turns the reinstall
  case above from a harmless miss into a mis-route.
- `installation.deleted` sets `revokedAt` and dead-letters that integration's
  pending ops (see Deletion). Test that a payload for a revoked installation is
  dropped rather than routed — the failure is silent and cross-tenant, so it
  needs a test rather than a careful reading.

**Shipped in phase 4a**: both tables, the raw-SQL import-filter CHECK, the
`tasks.integration_repo_id` foreign key, and `web/src/models/integration.ts`
holding the only reader of the inbound key — `resolveInstallation`, which filters
`revokedAt IS NULL` and keys on `[provider, installationId]` and nothing else.
`revokeIntegration` sets `revokedAt` and `status` and dead-letters nothing: there
is no `TaskSyncOp` table to dead-letter into yet.

Two things the table definition above left unstated and 4a had to choose:

- **`status` vocabulary is `active | suspended | revoked`.** A GitHub App
  installation can be *suspended* without being removed, and a suspension lifts
  where `revokedAt` never does, so the two are not one field.
- **A suspended installation still routes inbound.** Deliberate, and the opposite
  reading is tempting: GitHub suppresses deliveries for a suspended installation
  *except* the `installation` events themselves, so refusing to route on `status`
  would drop the `unsuspend` event that lifts the suspension and strand the
  integration. `revokedAt` is the kill switch; `status` is the provider's
  projection.

The sync columns live on `Task` (see above). `remoteSnapshot` there is the
**shadow copy of the last successfully synced remote state** — the whole reason
bidirectional sync is tractable. It holds the normalized field set, not the raw
provider payload — with one deliberate exception: **`status` is stored as the raw
provider projection** (`state` + `state_reason`), because the Antgrid→GitHub
status mapping is many-to-one and comparing normalized values against it is a
push loop. See the merge section.

Several of those columns exist because a stated invariant had nowhere to live:

- **`localConflict`** holds the losing local value. The conflict policy below
  promises "remote wins, but we keep your edit" — with only `syncState='conflict'`
  there is nowhere to keep it, and the promise inverts into exactly the silent
  data loss it forbids. Also define the lifecycle: a second conflict on an
  already-conflicted task **merges into** this blob rather than overwriting it,
  the drain **does not push** a task in `conflict`, and resolving in the UI clears
  it and re-seeds `remoteSnapshot`.
- **`pushedHash`** replaces `remoteVersion` for echo suppression — see below for
  why a timestamp cannot do that job.
- **`etag`** is what makes the reconcile poll cheap. The Inbound section claims
  `If-None-Match` "on the stored `etag`"; without the column that claim is
  fiction.
- **`visibility`** backs the "public if the repo is" line in the publish consent
  UI. That sentence is the single most load-bearing element of the consent
  moment and there was no column behind it — the UI would have to guess or make a
  live API call per form render. It is also *mutable*: subscribe to `repository`
  and treat a private→public transition as a user-visible event, because it
  retroactively exposes every issue published under the opposite assurance.
- **`pushEnabled`** is separate from `syncEnabled` on purpose. Phase 4 ships a
  one-way read-only import, and users will reasonably treat imported issues as a
  private notes layer over GitHub. Phase 5 turning outbound writes on for exactly
  those rows changes the meaning of a link the user already accepted. Ship the
  outbound half **off by default per repo**, opt-in.
- **`importFilterKind` + `importFilterValue`** bound what a first sync pulls in.
  `syncEnabled` is a boolean and the reconcile lists everything, so pointed at a
  moderately busy repo the account-wide list becomes a mirror and the Running view
  — the differentiator — becomes a needle in a haystack we imported on purpose.
  Vocabulary: `all | label | milestone | assigned_to_member`, with
  `importFilterValue` carrying the label or milestone name and NULL for the other
  two. **Ship the columns now even though the default is still open** (see Open
  items): with them, changing our mind is a config write; without them it is a
  migration *plus* a re-import, and re-import is the operation the unlink tombstone
  rule makes hardest.
- **`commentImportCap`** is an int with a non-null default, for the same reason. An
  uncapped comment import is ~10 hours of API budget for one large repo (see
  Scale), and a cap that lives in a constant cannot be raised for the one repo that
  needs it.

> **Partial indexes and CHECK constraints must be raw SQL in the migration.**
> Prisma models neither and is blind to both on introspection, so declaring the
> account-wide label unique as a plain `@@unique` makes every `migrate dev` try to
> create a conflicting index. That applies to the two raw constraints this plan
> still needs — the `project_id IS NULL` label unique and the assignee-pair
> `CHECK` — and to nothing else, now that the link table's partial unique is gone.
> Same convention already documented on `account_members_one_active_per_user_idx`
> and `devices_user_active_idx` in `schema.prisma`.

### Sync plumbing

```
TaskSyncOp   id, taskId, integrationId, provider, kind, payload Json,
             opKey, seq, attempts, nextAttemptAt, status, lastError?,
             attemptedAt?, createdAt
             @@unique([taskId, opKey])
             @@index([status, nextAttemptAt])
             @@index([taskId, seq])
TaskRun      id, taskId, deviceId, localProjectId, sessionId, checkoutId?,
             tool?, status, branch?, prUrl?, startedAt, endedAt?,
             resultSummary? @db.VarChar(200)
             @@unique([deviceId, sessionId])
             @@index([taskId, startedAt])
TaskComment  id, taskId, authorUserId?, authorExternalLogin?, body,
             externalId?, createdAt, updatedAt, deletedAt?
```

**`kind` needs an enumerated vocabulary, because three rules elsewhere in this
plan are written in terms of one.** "Supersede rather than queue" replaces a
pending write *for that field*; "ops for one task apply in order" needs to know
what `seq` counts; "never replay an array-valued PATCH" needs to know which kinds
are array-valued. None of the three is implementable against a free-form string.
v1:

| `kind` | Payload | Array-valued |
|---|---|---|
| `issue.create` | the whole task projection | — |
| `issue.patch.title` | scalar | no |
| `issue.patch.body` | scalar | no |
| `issue.state` | `state` + `state_reason` | no |
| `issue.labels` | the full label set, recomputed at send time | **yes** |

Each gets a Zod payload schema beside the provider seam, so `applyOp` dispatches
over a closed set rather than comparing strings. Note what is absent and why:
no `issue.assignees` (never pushes in v1 — see Assignment) and no `comment.create`
(inbound-only — see Publishing). Adding either is a schema change *and* a
trust-copy change, which is the point of enumerating them here rather than leaving
`kind` open.

**Supersede keys on `kind`, not on a field name inside `payload`.** That is why
the per-field kinds are split out instead of folded into one `issue.patch` with a
discriminator in the JSON: a partial unique index over a JSON path is not a
foundation to put a correctness rule on.

**`seq` is per task, allocated in the same transaction as the `Task` write.** It
is monotonic within a task and means nothing across tasks; `@@index([taskId, seq])`
is the read path for the ordered claim. The claim itself must therefore group by
task — see the note under the claim SQL, which as written orders globally and does
not yet implement the per-task rule.

**`opKey` carries `@@unique([taskId, opKey])`.** It is the marker embedded in
created issue bodies and the only guard against a public double-post, so "stable
across retries of one op, unique across ops" belongs in a constraint rather than a
convention. Derive it in the enqueueing transaction as a random 128-bit value —
not a hash of the payload, which would collide across two legitimately identical
edits, and not a per-account sequence, which would leak volume into a public issue
body.

`TaskRun` is the join between a task and a real agent session. It is what
distinguishes this from an issue tracker and it never syncs anywhere.

`branch` and `prUrl` exist because a reviewer opening a task wants *what did the
agent do* and a session name plus a start time does not answer it. Both are
**recorded**, not parsed back (see "the branch name is not an identifier").
`resultSummary` carries a hard `VarChar(200)`: the Trust-posture rule below
forbids agent output in task text, and a rule enforced by a column is enforceable
where a rule stated in a design doc is not.

**`webhook_events` reuse needs three corrections.** The table exists
(`web/prisma/schema.prisma`) and `X-GitHub-Delivery` does drop into
`providerEventId`, but:

1. **The unique is on `provider_event_id` alone, not `[provider,
   providerEventId]`** — one global id namespace shared with Paddle and Razorpay.
   Either add the composite or accept the shared namespace deliberately.
2. **`processedAt` is never read anywhere in `web/`.** It has two writers, both
   setting it to `now()` at insert. There is no "unprocessed" state today and no
   consumer of one, so "process from the row" is a **new pattern**, not a reuse.
3. **The existing pattern is the opposite shape.** Billing inserts the dedup row
   *inside the same transaction as the effect* and catches the unique violation as
   the idempotency guard, awaiting the whole reduce before responding. That is
   exactly-once-per-effect. Insert-then-`202` trades it for
   at-most-once-with-a-hole: a crash between insert and process leaves a row
   GitHub will never retry (we already 202'd) **and** that a manual redelivery
   cannot rescue, because the dedup row makes the redelivery look like a
   duplicate.

If we keep insert-then-`202` — and we should, because GitHub's payloads are large
and the merge is slow — then it is a deliberate new pattern and needs the parts
the billing table never had: `attempts` and `lastError` on `WebhookEvent`, a
genuinely retryable `processedAt IS NULL` sweep, an index on
`[provider, processedAt]` (the table has exactly one non-PK index today, so the
drain's `WHERE provider='github' AND processed_at IS NULL` seq-scans it), and a
retention policy — nothing in `web/` ever deletes from this table, and it is
about to absorb a full payload copy of every issue and comment event for every
synced repo.

**The idempotency key must come from inside the signature envelope.**
`X-GitHub-Delivery` is a header, and GitHub's HMAC signs the **body only** — so
one captured valid `(body, signature)` pair replays indefinitely with a fresh
delivery id each time: every replay verifies, gets a fresh unique key, and is
reprocessed. State the rule provider-agnostically, because the cheap instance and
the expensive one look different:

- **A signed nonce or timestamp in the body, if the provider gives one** — Linear
  puts `webhookTimestamp` inside the signed payload, and Superset keys on it
  directly (see the appendix). Free, and it stays stable across a redelivery of
  the same event, which a body hash also does.
- **Otherwise, a hash of the raw signed bytes.** GitHub's payload carries no
  delivery id or timestamp, so the body hash is the equivalent. Hash the raw
  request bytes *before* parsing — re-serializing the parsed object gives a
  different key for the same delivery on any library or key-order change.

The one thing a body hash costs is that two genuinely distinct events with
byte-identical bodies would collapse into one. For `issues` payloads this is
effectively unreachable — every payload carries the full issue including
`updated_at`, plus `sender` — but that is a property of the payload shape, so
verify it per event type rather than assuming it holds for whatever we subscribe
to next.

**Re-arm failed rows on redelivery instead of treating them as duplicates.** The
insert-then-`202` hole above is that a dedup row makes a manual redelivery look
like a duplicate. Superset's `webhook_events` upsert closes it: on conflict, a
row in `failed` goes back to `pending` with `retryCount + 1` and its error
cleared, while a row in `processed` is left alone. One `ON CONFLICT DO UPDATE`
with a `CASE`, and a redelivery becomes the recovery path it is supposed to be.

**Phase 4a shipped the columns and none of the behaviour.** `attempts`,
`lastError`, the `[provider, processedAt]` drain index and the composite
`[provider, providerEventId]` unique are in the schema; the one billing
`findUnique` moved to the compound key and the two `create` sites are unchanged,
since a composite unique still raises P2002. What does **not** exist yet, and is
4b's: the `processedAt IS NULL` sweep, the `ON CONFLICT DO UPDATE` re-arm above,
and a retention policy. `processedAt` is still read nowhere in `web/`.

**Shipped in phase 4b** (`web/src/integrations/`, `web/src/routes/webhooks.ts`).
All three corrections above now have behaviour rather than columns:

- The dedup key is `bodyDeliveryKey(raw)` — sha256 of the exact bytes the
  signature covers, computed before parsing. `X-GitHub-Delivery` is kept, but
  **inside** `payload.deliveryId` where it is evidence and not the key.
- `recordDelivery` is one `INSERT ... ON CONFLICT DO UPDATE` with the `CASE`
  described above. It reports `inserted` via `xmax = 0` and `alreadyProcessed`
  from the row, which is what lets the route answer `duplicate` honestly.
- `purgeProcessedWebhookEvents` deletes processed rows past a 30-day cutoff, and
  is **provider-scoped by a required argument** so it cannot reach billing's
  rows — those are an idempotency guard against a late gateway redelivery, not a
  log, and deleting one silently re-opens a payment effect.

The concrete numbers, all in one place so a later phase can argue with them:
2 MiB body cap, a 120-token bucket refilling 20/s for the route, 5 attempts
before a row is left alone, 30-day retention for processed rows, and
`hashtext('ghhook:' || id)` for the per-row drain lock. The plan's warning about
`pg_try_advisory_lock` was honoured: the drain takes a **transaction-scoped**
`pg_advisory_xact_lock` per row, so a failover blip cannot leave a lock held by
a dead session and stop the drain for ever. N instances are safe with no leader
election.

Event types are gated by two sets in `github-events.ts`.
`GITHUB_HANDLED_EVENTS` (`installation`, `installation_repositories`,
`repository`) are claimed and applied; `GITHUB_DEFERRED_EVENTS` (`issues`,
`issue_comment`, `label`) are subscribed to and **recorded unprocessed on
purpose**, so the backlog is already accumulating when 4c turns them on by moving
the name between the two sets and adding a handler. Phase 4d schedules both — see
below.

**Shipped in phase 4c-1** — one-way import, driven entirely by the drain above.
`issues` and `issue_comment` moved into `GITHUB_HANDLED_EVENTS`, and
`github-import.ts` maps a payload into the `SnapshotFields`/`LocalFields` shapes
`src/tasks/merge.ts` already merges over. That mapping is pure — no database, no
clock, no provider client — so the whole provider-space half is tested from
fixtures with no Postgres in the loop, and the merge engine itself was not
touched.

`MergeResult.push` and `labelsPush` are computed and **dropped**. Import is
one-way and phase 5's outbox owns the outbound half; nothing is lost, because
both are recomputable from the row and the snapshot each merge leaves behind.

Three locks, always taken in this order so it cannot invert:
`ghhook:<deliveryId>` claims the delivery, `taskimport:<accountId>:<externalId>`
serializes the does-this-issue-have-a-task-yet read across drainers, and
`tasksync:<taskId>` covers the read-merge-write that `merge.ts` demands of every
caller. The middle one is not redundant: the delivery lock keys on the delivery,
so two instances holding two deliveries for the *same new issue* would both read
"absent" and both create, and the loser dies on `tasks_account_external_key`
inside a transaction Postgres will not let a JS catch rescue.

Every refusal on the way in is a **drop that marks the row processed** —
unknown installation, unknown repo, `syncEnabled` off, a pull request, an issue
deleted on GitHub, out of import-filter scope, a task the user deleted or
unlinked. None of them burn the attempt ceiling, because none of them will read
differently on a retry.

Three properties worth stating because they are invisible at the call sites:

- **`externalId` is the numeric `issue.id`, never `node_id`.** Both address the
  same object; only one is promised never to change. GitHub reformatted node ids
  once already, and a reformat here is silent — every stored id stops matching,
  the lookup finds nothing, and the next delivery creates a second task for an
  issue we already hold. `externalKey` (`owner/repo#number`) carries the readable
  half and is the one the UI shows.
- **The import filter is asked once, on the way in.** A task already imported and
  then relabelled out of scope keeps receiving updates: a task that silently
  stops tracking its issue is a worse outcome than one that arguably should not
  have been imported, and only the second is visible to anyone.
- **`source: "github"` and the external columns are a security property.** The
  app's launch sheet reads them to decide a body is untrusted and has to be seen
  by a human before it becomes an agent's opening instruction. Left at `local`,
  that mitigation turns off silently and nothing fails.

Three small refactors in `models/` were forced rather than chosen:
`createTaskInTx`, `setTaskLabelsInTx`, and `getOrCreateLabel` widened to `Tx`.
All three were `DB`-typed and self-transacting, so none could be called from
inside the drain's transaction — and `pg_advisory_xact_lock` is
transaction-scoped, so a nested `$transaction` would have taken the numbering
lock in a scope that ended before the caller's own writes committed. Phase 5's
outbox will hit exactly the same wall.

## The install flow (phase 4c-2)

The webhook half is inbound and anonymous; this half is the only place a GitHub
installation gets *attached to an account*, and it is where the cross-tenant
mistakes live.

### The shape

1. A signed-in user on the account settings page clicks **Connect GitHub** and is
   sent to `https://github.com/apps/<slug>/installations/new?state=<opaque>`.
2. GitHub runs its own install UI — repository selection happens **there**, not
   here, which is the point: the user grants us a repo set we never see them
   choose.
3. GitHub redirects to our callback with `installation_id`, `setup_action`
   (`install` | `update`), our `state`, and — if the App is configured to request
   user identity — a `code`.
4. We verify, resolve, and write `Integration` plus one `IntegrationRepo` per
   repository, every one of them with `syncEnabled = false`.

### `installation_id` in the callback is an untrusted parameter

This is the sharp edge and it is easy to miss, because the callback arrives on an
authenticated session and *looks* trustworthy. It is not: the query string is
attacker-supplied. Anyone signed in to Antgrid can hand our callback the
`installation_id` of an installation belonging to somebody else's GitHub org and
bind it to their own account. `@@unique([provider, installationId])` then makes
that binding the **only** route inbound deliveries can take, so the attacker
receives every issue event from a repository they have no access to.

Two facts do not fix it, and both are tempting:

- **The App JWT proves the installation exists, not who installed it.**
  `GET /app/installations/{id}` signed with the App's private key succeeds for
  *every* installation of the App, including the victim's. It answers the wrong
  question.
- **The session proves who the Antgrid user is, not who the GitHub user is.**
  The two identities are unrelated until something ties them together.

The fix is to make GitHub answer the question, as the GitHub user: exchange the
callback's `code` for a **user-to-server** token, call `GET /user/installations`,
and accept the `installation_id` only if it appears in that list. That endpoint
returns exactly the installations the authenticated GitHub user can administer,
which is the property we actually need. Requiring the identity `code` means the
App must be registered with **"Request user authorization (OAuth) during
installation"** enabled — a registration setting, so it belongs in the open-items
table next to the App ID and the PEM, not in a code review six weeks later.

`state` is a separate concern and does not substitute: it binds the callback to
the browser that started the flow (CSRF), and `pending_sign_in` is the pattern to
copy — HMAC-stored, single-use via a `consumed_at` stamp, short TTL. It says
"this browser started a flow", never "this installation is yours".

### The private key is a cross-tenant master key

The PEM signs App JWTs for **every** installation of the App, across every
account. It is categorically unlike the per-account secrets in this service. It
must come from the environment, never the repo and never `.env.example`, mint
JWTs with the ten-minute maximum `exp` GitHub allows, and never be logged. An
installation access token derived from it is scoped to one installation and is
the thing that should be passed around; the PEM itself should not leave the
module that signs with it.

### After the identity check

- `upsertIntegration` with `installationId`, `externalAccountId` (the GitHub org
  or user id), `displayName`, and `installedBy` = the Antgrid user id from the
  session. The revive-a-revoked-row arm is what makes reinstalling work.
- List the installation's repositories with an installation access token and
  `upsertIntegrationRepo` each one. **Do not depend on the `installation.created`
  webhook for this list.** That delivery can arrive before this row exists, in
  which case `resolveInstallation` finds nothing and the drain drops it as
  `unknown_installation` — recorded in the open decisions, and the reason the
  flow reads the repository list itself.
- Every repo lands `syncEnabled = false`. Discovery is not consent, and the
  consent columns are create-only precisely so a later re-discovery cannot
  overwrite what the user chose.

### The settings page

Lists connected integrations and their repositories with per-repo toggles, each
one writing through `setRepoSyncSettings` — the sole writer of the consent
columns. Two things it must say out loud rather than imply:

- **A repository's visibility**, from `IntegrationRepo.visibility`, next to the
  toggle. That sentence is the most load-bearing element of the consent moment;
  it is a column rather than a live API call for exactly this reason.
- **Why a repo is off when the user did not turn it off.** A repository removed
  from the installation is soft-disabled, and re-adding it does not re-enable it.
  Without a visible explanation that reads as a bug.

Uninstall needs no work here: `installation.deleted` already revokes the
integration through the drain, and revocation is what stops inbound routing.

**Shipped in phase 4c-2** — the install flow and the account-level settings page
(`web/src/integrations/github-app.ts`, `github-install.ts`, `web/src/ui/integrations.tsx`,
and the `/integrations*` routes in `web/src/routes/ui.tsx`). The shape above
survived contact; what follows is the part that is not visible from a call site.

**`installation_id` is treated as hostile all the way down, and the identity
check is the only thing that makes it safe.** `completeGithubInstall` exchanges
the callback's `code` for a user-to-server token, calls `GET /user/installations`,
and accepts the id only if it appears in that list — everything else in the
function is bookkeeping around that one comparison. The two facts that look like
they close the hole and do not are both still reachable in the module and both
carry comments saying so: `getInstallation` is signed with the App JWT and
succeeds for every installation of the App, and the session proves who the
*Antgrid* user is and nothing about who the GitHub user is. The flow depends on
the App being registered with **"Request user authorization (OAuth) during
installation"** — without it no `code` arrives, `installationId || code` fails,
and the callback answers `code_rejected`. That is a registration setting, not a
code setting: turn it off in the App and this flow degrades to refusing every
install rather than to accepting an unverified one, which is the direction it
should fail but is not a state any test can reach.

**Two smaller properties of that check, easy to lose in a refactor.** GitHub
reports a failed code exchange **inside a 200** (`{"error": "bad_verification_code"}`,
no `access_token`), so `res.ok` is not a token check; `exchangeUserCode` reads
the body and `installDirectory` narrows that one case to `null` while leaving a
transport failure as an exception, because "your link was used twice" and "GitHub
is down" need opposite advice. And `installationPathSegment` refuses anything but
decimal before the id reaches a URL — the id is interpolated into a path on
requests signed with the App JWT, so `../../user` would aim the master key at an
endpoint of the caller's choosing.

**The install is deliberately not one transaction.** `upsertIntegrationRepo`
reports a repo-key conflict from a unique violation, and Postgres aborts the
surrounding transaction on that error no matter what the caller catches — so a
batch inside a transaction cannot record the repositories that were fine, only
lose them all to one bad name. Partial progress is safe here because every step
is an upsert and the whole flow is re-runnable from the settings page: the
integration binds first, the repositories fill in after, and a provider failure
between the two returns `provider_error` with inbound routing already live and
only the catalog missing.

**Discovery is not consent, and the columns enforce that rather than the copy.**
Every repository the flow records lands `syncEnabled: false`, and
`upsertIntegrationRepo` applies every consent column on **create only** — its
update arm rewrites `repoKey`, `visibility`, `removedAt` and the project link and
touches nothing else. That is what makes re-running the flow, or a later
`installation_repositories` delivery, unable to reset a choice the user made. The
page carries the same rule in words: the empty state says nothing is copied until
a repository is switched on here, one repository at a time.

**`removedAt` separates two off states that were previously one row.** A
repository dropped from the installation, or deleted on GitHub, gets
`syncEnabled: false` — the exact row the user's own toggle produces, so the
settings page could show the off state and could not explain it, and an
unexplained off state reads as our bug. `removedAt` is stamped alongside by both
writers (`stopSyncing` on the inbound path, `markMissingReposRemoved` on the
install path) and the row renders a dated warning naming GitHub as the cause.
Re-adding the repository clears `removedAt` — rediscovery is proof it is
reachable, and that is the only fact it clears — and deliberately does **not**
turn sync back on: a repository leaving and returning is not an answer to whether
the user still wants it imported. The switch is frozen while `removedAt` is set,
in the markup *and* again in the route, because a frozen control is a suggestion
and the second check is the rule.

**`markMissingReposRemoved` refuses an empty `present` set.** The install flow
reads the repository list from the provider directly, which is what lets a user
deselecting a repository on GitHub take effect without waiting for a delivery
that may never have been recorded — but that also makes a single bad provider
response authoritative. An empty list is far more likely to be an error nobody
noticed than an installation with no repositories, and acting on it would disable
every import the account has in one call. The guard is `present.length === 0`
returning `0` before the `updateMany`, and it is the reason the caller pushes
every `externalRepoId` it saw — including the ones it then skips for an unfoldable
`repoKey` — into `present` rather than only the ones it recorded.

**The state is a cookie and nothing else, which reverses the paragraph above.**
The plan said to copy `pending_sign_in`: HMAC-stored, single-use via `consumed_at`,
short TTL. What shipped is `nonce.userId` in an httpOnly cookie with no database
row. The nonce is stored as itself rather than as an HMAC because that row is
HMAC'd for reasons this value does not share — it lives in our database where a
backup or a support query can read it, and possessing it grants a sign-in,
whereas this one lives only in the user's own browser and grants nothing on its
own. Nonce **first** in the format: it is base64url and so cannot contain the
separator, whereas nothing gets to promise that about a user id, which makes the
split on the first `.` unambiguous whatever the id looks like. The user id
travels beside it because a browser can change hands between the two halves of
the flow — sign out, sign in as someone else, return to a callback still holding
the first user's state — and comparing it against the live session closes that
without a row. The cookie is `SameSite=Lax` and must never be `Strict`: GitHub
returns the user by a cross-site top-level navigation, which is exactly the
request `Strict` drops. It is deleted on **every** path out of the callback,
failures included, before the config check and before the state comparison — a
state that survives a refused callback is a state an attacker gets a second
attempt at. The 15-minute TTL is the cookie's `Max-Age` and therefore enforced by
the browser alone; nothing server-side ages a nonce out, which is acceptable only
because the value is scoped to the browser that minted it.

**The App private key is a cross-tenant master key and the module is built around
that.** The PEM signs App JWTs for every installation across every account, which
is categorically unlike the per-account secrets elsewhere in this service. It
comes from the environment, is normalized once (`.env` cannot hold a real
newline, so it usually arrives with `\n` as two characters), is read in
`mintAppJwt` and nowhere else, and never leaves `github-app.ts` — `installDirectory`
narrows the client to three questions and folds installation-token minting inside
`listInstallationRepos` so the token has no existence outside the module either.
The JWT is `{iss, iat, exp}` over RS256, `iat` backdated 60s because GitHub
recommends it against clock skew and rejects an `iat` in its future, and `exp` at
the **600-second maximum GitHub allows** — a limit, not a tuning knob. Signing is
hand-rolled on `node:crypto` rather than pulled from a JWT library, because this
service has no JWT signer by design and 40 lines is not worth the supply-chain
surface under a key of this blast radius. The matching rule is that nothing here
may put a secret into a message, a log, or a thrown value: `GithubApiError`
carries a method, an endpoint and a status, response bodies are never echoed, and
Zod issues are read but never rendered — for the token endpoints the body *is*
the credential. A test asserts every failing call clean over the whole error
object, stack and own properties included, because that is what a logger
serializes. The config object closes the other accidental path itself: `toJSON`
and the inspect hook return a copy with both secrets replaced, and both are
defined **enumerable**, because JavaScriptCore — so Bun — consults `toJSON` only
when it is and ignores a non-enumerable one in silence, which is the failure mode
where the redaction reads as installed and the PEM goes out anyway.


**The settings page refuses a widening it was asked for.** `parseImportFilter`
returns `null` for the pairs the `integration_repos_import_filter_check`
constraint would reject — `label` or `milestone` with no name — and that refusal
takes the **whole** write down, the toggle included. Saving the toggle alone
would have been the dangerous half: import would then run under whatever filter
is already stored, which on a repository nobody has narrowed is `all`, so a user
who asked for one label and left the name box empty would receive the entire
repository instead of nothing. That is the one place in this phase where the safe
direction is to refuse rather than to fall back.

**Shipped in phase 4d** — the runner that makes the drain actually run
(`web/src/integrations/github-drain-loop.ts`, `web/scripts/drain-github-webhooks.ts`,
`bun run drain:github-webhooks`). It repeats `drainGithubWebhooks` until a pass
claims nothing, because one batch is the wrong unit for a scheduled job: a
repository disabled over a weekend leaves more rows queued than a single pass
claims, and a runner that stops there falls further behind on every tick. Two
bounds keep "until empty" from meaning "for ever" against a queue GitHub is still
filling — a pass count and a wall clock, both checked before a pass rather than
after — and the report says which one stopped it, so a bound is a warning the
next tick clears rather than a failure. Retention runs after the loop and is
reported rather than thrown, because it happens once the deliveries are already
committed and losing the record of that work to a failed DELETE costs more than
the retention did.

It is invoked from **outside** the process, and that is the load-bearing part.
An in-process `setInterval` would put a long database-bound job on the same event
loop that has to verify and record deliveries inside GitHub's delivery timeout,
so the service would get slowest exactly when it is furthest behind; and a timer
callback that throws logs and leaves the interval armed, whereas a scheduled
process has an exit code, which is the only alerting channel this service has.
The exit code is spent narrowly: 1 when a delivery exhausted its attempts or when
retention itself failed, never on an ordinary failure, because those stay
claimable and a job that pages for transients gets muted. The open decisions
record this as provisional and note that switching to a timer is a call to
`drainGithubBacklog`, not a rewrite.

## Bidirectional sync

### The shadow-snapshot merge

Every reconcile is a three-way merge over the normalized field set
(`title`, `body`, `status`, `labels`, `assignee`):

```
base   = Task.remoteSnapshot          (last state both sides agreed on)
local  = Task row now
remote = provider payload now

per field:
  local == base and remote == base  → nothing to do
  local != base and remote == base  → push local
  local == base and remote != base  → apply remote
  local != base and remote != base  → conflict
```

`status` runs that same table in **provider space** rather than in ours — see the
status section below. The mapping to GitHub is many-to-one, so comparing Antgrid
values against a provider snapshot is a self-sustaining push loop.

Conflict policy for v1: **remote wins for provider-owned fields, and we keep the
losing local value in `Task.localConflict` with `syncState='conflict'` plus a UI
marker.** Silent data loss is the one outcome that is never acceptable; a visible
"changed in GitHub, your edit was kept aside" banner is.

**One merge runs at a time per task.** The drain and the webhook processor are
two different consumers doing read-merge-write on the same `Task` row, and
nothing above serializes them. Without a lock:

```
t0  webhook W (remote title "B") inserted, unprocessed
t1  drain claims op O (push title "A"); reads link, base = "orig"
t2  webhook processor runs: local "A" != base, remote "B" != base
      → conflict → writes Task.title = "B", remoteSnapshot = "B"
t3  drain's PATCH lands. GitHub = "A". Drain overwrites remoteSnapshot = "A".
```

End state: local `B`, GitHub `A`, snapshot `A` — the next reconcile pushes `B`,
the system flip-flops, and it raised a conflict banner for a conflict that was
**our own in-flight write**. Both paths take
`pg_advisory_xact_lock(hashtext('tasksync:' || taskId))` across the merge, and
release it *before* any HTTP call — never hold a transaction open across a
GitHub round trip. **Namespace that key `tasksync:`, not `task:`** — `task:` is
already the number-allocation key, and `hashtext` collapses both into one global
int4 advisory namespace, so reusing the prefix would make a merge on task X block
number allocation for the account that hashes to the same value.

**`labels` is a set and merges element-wise, not whole-value.** Diff each side
against the base into added/removed, then apply
**(local added ∪ remote added) − (local removed ∪ remote removed)**. A
whole-value compare on a set is wrong in the expensive direction: two sides that
each added a different label are *not* in conflict, but a scalar compare calls it
one and the losing side's addition is dropped. This is why `TaskLabel` is rows
rather than a column — the merge needs the elements addressable.

**`assignee` is deliberately not in that list.** It is a scalar on both sides of
our model now, so it merges whole-value like `title` — and it never pushes at
all in v1 (see Assignment), so the expensive direction of a whole-value set
compare is unreachable rather than merely unlikely.

That formula is **remove-always-wins**. Write it that way and do not also
describe it as "remote wins for the same element" — those are different
algorithms and the two readings disagree on exactly the case that matters.

Be precise about which case the marker is for, because the obvious phrasing names
one that cannot arise: an element is only *added* if it is absent from the base
and only *removed* if it is present in it, so `added ∩ removed` is empty by
construction and "local removed an element the remote added" is unreachable. The
reachable loss is an element **dropped while the other side still had it** — base
has `L`, one side dropped it, the other kept it, and the merge drops it. Derive
the marker from what each side still holds, not from intersecting the two diff
sets, or it is dead code that never fires. Removal is data-loss-shaped, so that
element gets a UI marker even though the field never enters `conflict` state.

**Applying locally and pushing are two different comparisons**, and a set needs
both: `merged != local` decides whether the row is written, `merged != remote`
decides whether an `issue.labels` op is created. Collapsing them to one means a
label added locally — already on the row, so nothing to apply — never reaches
GitHub at all.

**Label rename and delete are invisible to us**, because `label` and `milestone`
are not in the subscribed event list. Both corrupt the element-wise diff:

- **Rename** arrives only as a side effect on the next `issues` event, where the
  issue carries `L2` and base says `L1`. The diff reads that as *remove `L1`, add
  `L2`* — so a repo-wide rename trickles through one issue at a time, creating a
  ghost `Label` row per rename.
- **Delete** removes the label from every issue at once and emits **no per-issue
  `issues` event**. Local keeps it on N tasks, and the next push of any of them
  sends the deleted name in the `labels` array — GitHub's PATCH then **recreates**
  the label with a random colour. We would silently undo a repo-wide label
  deletion, one issue at a time, in the wrong colour.

Subscribe to `label`, or accept both and say so. Do not leave it unstated.

The status field is where the snapshot earns its keep. GitHub has only
`open`/`closed` + `state_reason`:

| Antgrid | GitHub |
|---|---|
| `open`, `in_progress`, `blocked` | `open` |
| `done` | `closed`, `state_reason: completed` |
| `cancelled` | `closed`, `state_reason: not_planned` |

**That mapping is many-to-one, so `status` is the one field that merges in
*provider* space, not ours.** `remoteSnapshot.status` stores the raw provider
projection (`state` + `state_reason`), and the status arm of the merge compares
`toRemote(local)` against that snapshot and against `toRemote(remote)` — never
the Antgrid values directly. Every other field on both sides stays normalized.

Merging status in Antgrid vocabulary is a **self-sustaining write loop**, and it
fires on the most ordinary flow in the feature. An imported task sits at local
`open`, base `open`. The `working → in_progress` writer below fires, so local is
`in_progress`. The next reconcile sees `local != base, remote == base` → push
local. `toRemote(in_progress)` is `open`, the issue is already open, so the PATCH
is a content-creating write with **no effect** — and the no-effect detector below
cannot catch it, because that detector compares the response against what was
asked for and the response says `state: open`, which is exactly what was asked
for. The snapshot is then re-derived from that response, so base never reaches
`in_progress` and the next reconcile pushes again. One wasted write per task per
cycle, forever, against the 500/hr content-creating budget that is the binding
constraint — defeating the one guard built to stop exactly this shape.

In provider space the same trace is a no-op: `toRemote(open) == toRemote(in_progress)`,
so no diff, no op, no request. Two more consequences fall out of the same fix:

- **A remote close during a local run stops being a conflict.** Local
  `in_progress` + base `open` + remote `done` compares as `open` vs `open` vs
  `closed` — `local == base, remote != base` → apply remote, a clean one-sided
  close. In Antgrid space it lands on the conflict arm instead, and because the
  drain does not push a task in `conflict`, an agent running while a teammate
  closes the issue on GitHub **wedges the task** until someone resolves a conflict
  that never happened.
- **`done ↔ cancelled` is not pushable at all**, and this is the transition the
  no-effect counter is genuinely for. Both map to `closed`, and `state_reason` is
  documented as *"Ignored unless state is changed"* — so a `done → cancelled` edit
  on an already-closed issue can never be delivered by a PATCH. Either send it as
  a reopen-then-close pair (two content-creating writes, and a visible reopen in
  the issue's timeline — say so in the trust copy if we do) or mark the transition
  local-only in the UI. Do not leave it to be discovered as a field that silently
  never converges.

**`state_reason` is only significant while the issue is closed**, and comparing
it on an open one is the same bug wearing a different hat. GitHub stamps
`reopened` there and `toRemote` never produces one, so a reopened-then-edited
issue compares unequal against its own snapshot on every reconcile — a diff with
no edit behind it, pushing forever exactly like the Antgrid-space loop above.
Provider-space equality must ignore the reason unless `state` is `closed`.

Coming back the other way, `open` is ambiguous — it could mean "still open,
unchanged" or "reopened". Without the base snapshot, every inbound webhook for
an unchanged open issue would clobber a local `in_progress` back to `open`. With
it, `remote == base` means the field did not move and local sub-status is
preserved. `fromRemote` therefore takes its sub-status hint from the **local row**,
not from the snapshot — the snapshot is provider-space and has no sub-status left
in it to preserve. Do not skip this.

### Outbound: the outbox

Local edits never call GitHub inline. They write the `Task` row and a
`TaskSyncOp` in the same transaction, and a drain loop applies them. This
survives a GitHub outage, gives natural retry/backoff, and keeps request latency
off a third-party API.

**Echo suppression must key on *what* we wrote, not *when*.** Our own write comes
back as a webhook seconds later and has to be recognized. The obvious scheme —
store the response's `updated_at` and drop any inbound event at or below it — is
**wrong in a way that silently destroys a user's edit**:

```
t0  merge decides: local != base, remote == base → push local
t1  a human edits the issue title on GitHub          (updated_at = T1)
t2  our PATCH lands, blind — GitHub has no If-Match  (response updated_at = T2)
    we store T2 as the version and the response as the snapshot
t3  the webhook carrying the human's T1 edit arrives → T1 <= T2 → dropped as echo
```

Their edit is now gone from GitHub (clobbered at `t2`), gone from our DB (never
applied), and no conflict was recorded. The reconcile poll cannot recover it
either: remote and base agree. This is not an unlucky interleaving — `t0→t2`
spans a queue hop plus an HTTP round trip, which is the entire point of the
outbox. `updated_at` is also **second-granular**, so any genuine remote edit in
the same second as our push is unconditionally suppressed, and GitHub exposes no
monotonic version to use instead (the GraphQL node id is an identity, not a
version).

So:

- Store `Task.pushedHash` — a content hash of the normalized field set we
  pushed. Drop an inbound event as an echo **only if its normalized field set
  hashes equal**. Anything else is a third party's write and must be merged, even
  if its timestamp is older.
- **Re-fetch remote immediately before the push** and abort to a three-way merge
  if `remote != base`. This is the only thing that turns a blind PATCH into
  something close to a compare-and-swap.

**Write idempotency — "PATCHes are naturally idempotent" is false here.** Two
reasons, and the second contradicts this document's own assignee argument:

1. The dangerous retry is the **unknown outcome**: the PATCH committed, the
   response was lost. Between the unobserved success and the retry a human fixes
   the title; the retry re-clobbers it, and by the rule above the webhook for
   their fix is echo-suppressed. `attempts` never registers a problem — both calls
   returned 200.
2. **`PATCH /issues/{n}` with `labels` replaces the whole array.** A delayed
   replay of a stale `labels` array is a **set rollback**, not a harmless repeat.
   Never replay an array-valued PATCH without recomputing it from current rows.
   `assignees` has identical replace semantics, and that is precisely why v1
   never sends it — see Assignment.

Creates are worse: a crash between "POST issue" and "store returned id"
double-posts, and the duplicate is public and permanent. Embed an invisible
marker in created bodies — `<!-- antgrid:op:<opKey> -->`, stable across retries of
one op and unique across ops — but **do not resolve it through
`GET /search/issues`**:

- GitHub's search index is **eventually consistent** with no published latency
  guarantee, and the retry window is the *fast* window — a crash-restart retries
  within seconds. Search returns zero hits for an issue that exists, and we post a
  duplicate.
- Search has its own much lower limit — **30 requests/minute** — so a retry storm
  hits it first, and a `403` on the *read* reads as "not found" unless explicitly
  handled. Fail **closed**: an errored search is not a licence to post.
- `q=antgrid:op:<key>` is not valid free text; colons are qualifier syntax.
- A human editing the body deletes the marker, and a later retry reposts.

Use the primary store instead — the same shape this plan already chose for
comments. Persist `TaskSyncOp.attemptedAt` **before** the call, and on retry list
`GET /repos/{o}/{r}/issues?creator=app/<slug>&sort=created&direction=desc&since=<attemptedAt>`
and match the marker client-side. Strongly consistent, no index lag, no separate
budget. Keep a hard local guard regardless: never re-enqueue a create whose
`Task` already carries an `externalId`.

**Ops for one task apply in order.** `@@index([status, nextAttemptAt])` implies
claiming by `nextAttemptAt`, which reorders under backoff: two ops for one task
(`title := T2`, then `title := T3`), op1 fails once and backs off past op2, so op2
applies and *then* op1 does — **T2 wins**. With exponential backoff that is the
normal path for any op that fails once, not an edge case. Claim per task in `seq`
order, and supersede rather than queue: enqueueing a field write on a task that
already has a pending write for that field **replaces** it. Both halves need the
enumerated `kind` set from the schema section — "for that field" is a match on
`kind`, and `seq` is per task. The claim SQL below is where the ordering half
actually has to land, and as written it does not.

**A push that "succeeds" can have no effect, and the retry never stops.** The
sharpest instance is assignees — GitHub silently ignores an assignee lacking push
access, returning `200` with that login absent from the response array. Store the
response as base, keep the local value, and the next reconcile sees
`local != base, remote == base` → push → ignored → push again. Forever, one
content-creating write per task per cycle against a 500/hr budget, and `attempts`
never fires because the push *succeeds*. It takes one collaborator leaving an org
to start, and it is invisible until the App begins eating 403s.

Dropping assignee push from v1 removes that instance but **not the shape**. Any
field the provider normalizes or silently declines behaves identically —
`state_reason` is ignored on a PATCH that leaves the issue open, and a body GitHub
normalizes comes back differing from what we sent. So the rule stands and ships
with the drain, not with phase 6: every `applyOp` **compares the response against
what it asked for** and records a no-effect result. After N no-effect pushes of
the same field, stop pushing it, mark the element "not accepted by GitHub" in the
UI, and leave the local row alone. Building it later means building it after the
first non-convergent loop is already running in production.

Note its blind spot, because one loop hides inside it: the detector only sees a
field the provider *changed or dropped*. A push whose target value is already
correct in provider space returns exactly what was asked for and reads as a clean
success. That is the `in_progress → open` loop above, and no amount of response
comparison catches it — only merging status in provider space does. The two guards
are complements, not alternatives: provider-space comparison stops the loops that
arise from our vocabulary being finer than theirs, the no-effect counter stops the
loops that arise from theirs silently declining ours.

**Rate limits.** Installation token: 5,000 req/hr minimum, +50/hr per repo beyond
20 *and* per user beyond 20, ceiling **12,500/hr**. Secondary limits bite harder
on writes: **80 content-creating requests/minute and 500/hour**, plus a **100
concurrent request** cap and a points budget of **900/minute** where reads cost 1
and writes cost 5.

**The binding constraint is 500/hour — about 8 writes/minute sustained**, not the
80/minute figure. A bucket sized to 80/min burns the hourly budget in six minutes
and then eats 403s continuously; for a 50-repo org that breaks long before the
primary limit is touched. Size the bucket to the hourly rate and treat 80/min as a
burst ceiling.

`web/src/util/rate-limit.ts` is the right *shape* to copy and the wrong thing to
reuse directly: it returns a `boolean` rather than a wait time, so the drain
cannot derive `nextAttemptAt` from it and would increment `attempts` — driving
exponential backoff — for a purely local throttle. Throttling must be a distinct
outcome from failure, and must not count as an attempt. It is also process-local
and non-durable, so every deploy resets every installation to a full burst; that
is tolerable only under a single worker, which the drain-election note below
concludes we should not rely on.

Respect `Retry-After` and `x-ratelimit-reset` by pushing `nextAttemptAt`, never by
sleeping in the loop — and note that **secondary-limit responses frequently carry
neither header**. The documented fallback is: wait at least 60 seconds, then
exponential backoff. Without it the drain hot-loops into a longer block.

### Publishing a local task to GitHub

The other half of "bidirectional", and the half with a blast radius: a task born
in Antgrid (`source = local`) becoming a GitHub issue. **It is an option the user
chooses, offered at creation and afterwards — never a consequence of some other
action.**

The rule is one sentence: *a private note must not become a public issue because
a background loop decided it should.* Antgrid tasks are account-scoped and
routinely hold things that are nobody else's business — a customer name, an
unreleased plan, a security finding. Publishing derived from a label, a status
change, a project link, or "the project happens to have an integration" all fail
that test, and the failure is unrecoverable: deleting a GitHub issue is
admin-only and the content is already in every watcher's inbox.

A per-project default that pre-selects the option is fine and useful — the user
still sees it on the form and can turn it off for the one task. A background
publish nobody was shown is not. The line is *visible at the moment of writing*,
not *manual every time*.

**Two entry points, one mechanism.** Publishing is offered *as an option at
creation time* and as an action on an existing task. Both end at the same op;
they differ only in when the user is asked.

**A. At creation — the option on the new-task form.** The form carries a
**Create on GitHub too** toggle plus a repo selector. The form itself is the
confirm step: the user is looking at the title and body they just typed, next to
the name of the repo it will land in and a line saying it is public if the repo
is. Asking again in a second sheet would be a confirmation of a confirmation, and
those get clicked through.

The toggle is present only when the chosen project has an enabled
`IntegrationRepo`, and its **initial state comes from a per-project default**
(`IntegrationRepo.publishNewByDefault`, off on install). A repo whose whole
purpose is public issue tracking can flip that on and stop re-checking a box all
day; a repo used for private planning leaves it off.

The default sets **the position of a visible control, never the outcome**. That
is the entire safety property, and it is what separates this from the
auto-publish this section rules out: the user submitting the form can always see
whether this task is about to become public, and can flip it for this one task
without changing the project. Never derive publication from label, status, link
state, or "the project has an integration" — only from a toggle the submitter saw.

**B. After the fact — `Publish to GitHub` on an existing task.** For anything
created without the option: an unlinked task with a project and an enabled repo
offers the action, which opens a confirm sheet with the same three facts (repo,
exact title and body, public-if-public). This is the path for a task that started
as a private note and is now ready to be shared, and for everything created
before an integration existed.

**Common to both.**

- Requires `projectId` **and** an enabled `IntegrationRepo` on that project. With
  neither entry point is there an account-level fallback repo: a task with no
  `projectId` cannot be published, and the fix is to file it against a project.
- Exactly one enabled repo → preselected. Several → an explicit choice with no
  default, in both the form and the sheet.
- **Resolve the destination from `IntegrationRepo.externalRepoId`, never from
  `repoKey`.** `repoKey` is derived from `git remote get-url origin` on a dev
  machine and is entirely client-controlled; a device can assert any origin for
  any folder. `externalRepoId` came from the installation's own granted-repo list.
  Always render the resolved `owner/name` in the consent UI rather than the
  project's label, so what the user approves is what the API will address.
- Writes `TaskSyncOp{kind:'issue.create'}` and sets the task's
  `integrationRepoId` + `syncState = 'pending'` in the same transaction as the
  task write. The drain loop posts it, writes the returned issue identity onto the
  same row, and seeds `remoteSnapshot` from the response so the first reconcile is
  a no-op rather than a spurious merge.
- **The drain re-checks consent at send time.** A user who deletes the task
  between enqueue and drain has withdrawn it; an op whose task is soft-deleted, or
  whose repo has since had `syncEnabled`/`pushEnabled` turned off, is dropped, not
  posted. Nothing else in the outbox has a public blast radius, so nothing else
  needs this.
- From then on the task is linked and behaves exactly like an imported one.
  `source` stays `local` — it records where the task was born, not where it now
  lives.

**`publish` is a required boolean on the create API, with no server-side
default.** This is the enforcement point, and it is the API route, not the form.
If `POST /tasks` falls back to `publishNewByDefault` when `publish` is absent,
then an older app build, a field dropped on retry, or any non-form client
publishes silently — the exact unrecoverable failure this section exists to
prevent. Reject the request when the field is missing. `publishNewByDefault` then
becomes purely a **UI hint the client reads to position the toggle**, and it
cannot leak into the outcome by omission.

That matters because **the credential is the server's only actor-type signal.**
`requireBearerJwt` blanks `sessionId` for every Bearer caller, so nothing inside a
Bearer request distinguishes a human client from an agent-driven one. The Auth
section below keeps the app on the cookie gate specifically to preserve that
signal — but a required field does not *depend* on it, which is the point:
whoever calls, states the intent, and the rule holds even if the carrier decision
is later revisited.

Belt and braces, since publishing is the one irreversible verb here: keep
publish-capable routes on the **cookie gate** (`requireUser`) only, or enforce a
distinct OAuth scope. `oauth-provider.ts` already declares `scopes: ["agent"]`
and `requireBearerJwt` checks no scope at all today — that check is the lever.
With the carrier decision below, the cookie-only option costs the app nothing,
because the app is already on the cookie.

**Publishing is one-way and one-time.** There is no "unpublish": the issue
exists. The only reverse operation is **unlink** — set `syncState = 'unlinked'`
so the two stop syncing, leaving the GitHub issue untouched. Re-publishing an
unlinked task creates a *second* issue, which is why the repo is always named
rather than assumed, and why unlink keeps the old identity on the row: the
confirm sheet can then name the issue that already exists instead of describing
the hazard in the abstract.

**Linking grants a standing write channel — say so, once, out loud.** Publish and
import are the only moments with a consent prompt; from then on every title edit,
body edit and label attach on a linked task writes to GitHub with no further
asking. That is a defensible model — it is how every tracker integration works —
but it is a *different* promise from the one the paragraphs above make, and leaving
it implicit is how a user ends up surprised. Two things follow: `pushEnabled` is
opt-in per repo (see the schema), and the per-field provider mark in
`docs/tasks-ux.md` is load-bearing rather than decorative. Note that a programmatic
caller never sees that mark, which is a second reason edits from the bridge and
agents deserve their own scope.

That sentence is the definition of the channel, so it lists **exactly** the fields
that push. Two things a reader would expect to be in it are deliberately absent:
assignee, which is inbound-and-local in v1 (see Assignment), and comments.

**Comments are inbound-only in v1.** `TaskComment.externalId` exists so an
imported GitHub comment can be identified and de-duplicated across re-syncs; an
Antgrid-authored comment stays in Antgrid. That is a decision rather than an
omission, and it is conservative for the same reason `issue.create` is sequenced
last: a comment on a public issue is **content-creating, unretractable, and
attributed to the App**, so pushing one needs its own op kind, its own idempotency
marker (the `<!-- antgrid:op:… -->` problem again — a comment create double-posts
exactly like an issue create), and its own line in the trust copy. None of that is
free and none of it is on the path to the demo. A comment written in Antgrid on a
linked task therefore renders with a *stays in Antgrid* mark, so the asymmetry is
visible where the user is typing rather than discovered when a teammate never
replies.

**Not in v1:** bulk publish from a list selection. It is the one shape with no
per-task moment where the user sees what is going out, and it is the shape that
turns one mis-click into fifty public issues. Revisit after the two paths above
have been dogfooded on `antgrid/antgrid`.

### Inbound: webhooks + reconcile

- Verify `X-Hub-Signature-256` HMAC-SHA256 against the App webhook secret with a
  timing-safe compare, **before** parsing the body. Use the length-safe helper in
  `web/src/util/hmac.ts` (or the `email-webhooks.ts` pattern) — *not* a bare
  `timingSafeEqual(Buffer.from(a), Buffer.from(b))`, which **throws** on a length
  mismatch rather than returning false.
- **Cap the body and rate-limit the endpoint.** It is unauthenticated by
  construction, and it does DB writes. Without a size cap the handler buffers
  whatever arrives and computes an HMAC over it at line rate; `rate-limit.ts` is
  applied at fifteen sites today and zero of them are webhook routes.
- Insert into `webhook_events` first, respond `202` immediately, process from the
  row — with the corrections above (body-hash dedup key, `attempts`/`lastError`,
  a real unprocessed sweep). A webhook handler that does work before responding
  is a webhook handler that gets retried.
- **Route by installation, never by `repoKey`.** The resolution chain is
  `installation.id → Integration (by [provider, installationId], revokedAt IS
  NULL) → IntegrationRepo (by externalRepoId) → Task (by `[accountId,
  externalProvider, externalId]`)`. The first hop must key on `installationId`, not
  on `externalAccountId`: that column is unique only *within* an account and a
  webhook carries no account to scope the lookup by, so resolving through it is a
  cross-tenant write in the ordinary uninstall-then-someone-else-installs case
  (see Integrations). `repoKey` is client-asserted (see Publishing), so any path
  that resolves a repo by it lets a user bind their own `Project` to a victim's
  repo string. `externalRepoId` is also the only *stable* key — `repoKey` changes
  on rename or transfer.
- Subscribe to `issues`, `issue_comment`, `label`, `repository`, `installation`,
  `installation_repositories`. Assignee changes arrive as `issues` actions;
  `label` is needed for rename/delete (see the merge section) and `repository` for
  rename, transfer, and the visibility flip that invalidates a publish consent.
- **`GET /issues` returns pull requests too.** Filter on the `pull_request` key,
  in both the reconcile list and the webhook path. Skipping this makes every PR in
  the repo an Antgrid task on first sync — an immediately visible correctness bug
  that also roughly doubles the import.
- **Webhooks get dropped.** A periodic reconcile lists
  `GET /repos/{o}/{r}/issues?since=<lastCursor>&state=all` per enabled repo and
  three-way merges anything whose `updated_at` exceeds the stored snapshot.
  Cheap with `If-None-Match` on `IntegrationRepo.etag`.

### Where the loop runs

Web is the only process that can hold the App credentials, so the loop lives
there — but web may run multiple instances, and two drains on one op is a double
write.

**Do not elect a leader with `pg_try_advisory_lock`.** It is tempting and it is
not the pattern this repo uses: every advisory lock in the tree —
`models/device.ts` and six billing call sites — is `pg_advisory_xact_lock`, which
is **transaction-scoped** and auto-releases at commit. `pg_try_advisory_lock` is
**session-scoped**, appears nowhere in the codebase, and needs a dedicated
connection held for the worker's lifetime. `createDb` builds a **pooled**
`PrismaPg` adapter, so a session lock taken through `$executeRaw` lands on
whatever connection the pool handed out and the eventual unlock may run on a
different one — silently returning `false` and leaving the lock held until that
connection is recycled. After one failover blip **no instance can ever acquire it
again and the drain stops entirely, silently**: `pg_try_advisory_lock` just
returns `false`, nothing throws, and every local edit queues forever with no
alarm.

Make concurrent drainers safe instead of preventing them. Claim ops with

```sql
UPDATE task_sync_ops SET status = 'claimed', attempted_at = now()
WHERE id IN (
  SELECT id FROM task_sync_ops
  WHERE status = 'pending' AND next_attempt_at <= now()
  ORDER BY next_attempt_at
  LIMIT $1
  FOR UPDATE SKIP LOCKED
)
RETURNING *;
```

N drainers are then correct by construction, there is no lock to leak, and a
crashed worker's claims return to `pending` on timeout rather than stranding the
queue. (Note the subselect: `UPDATE … LIMIT` is not valid Postgres, so the
shorthand this plan previously used would not have run.)

**That statement claims per op, not per task, so as written it does not implement
"ops for one task apply in order".** It orders globally by `next_attempt_at`, with
no `DISTINCT ON (task_id)` and no exclusion of tasks that already hold a `claimed`
op, so two drainers can each take a different op for the same task and PATCH the
same issue concurrently. For `issue.labels` that is a label silently lost in the
user's repo, because the array is replaced whole. Recorded here rather than left
to be inherited: the invariant is stated above and this SQL contradicts it.

**The obvious repair does not work**, so do not reach for it: `DISTINCT ON
(task_id)` cannot be combined with `FOR UPDATE` at all (Postgres raises `0A000
FOR UPDATE is not allowed with DISTINCT clause`), it cannot see a task whose op
another drainer already holds — a `claimed` row is not in the `pending` candidate
set — and filtering candidates by `next_attempt_at <= now()` re-introduces the
very reordering it is meant to fix, since a backed-off head drops out and its
successor applies first. Readiness has to be applied to the head AFTER the
per-task pick. A worked statement, exercised against Postgres including a
two-drainer race, is in `tasks-open-decisions.md`; it is a proposal pending sign-
off, and phase 5 is gated on that sign-off.

Alternative if we want it out of the request process: a separate small worker
entrypoint in `web/` sharing the Prisma client. Same code, different `main`.
Defer until it hurts.

### Deletion, unlink and uninstall

Previously undefined, and the *default* behaviour of an undefined deletion path
here is resurrection — so this needs deciding before phase 4, not after.

- **Local delete leaves the identity live.** Inbound routing keys on
  `@@unique([accountId, externalProvider, externalId])` — which now resolves
  straight to the soft-deleted task row and applies remote to it. The task comes
  back, or remote edits land on a row the user believes is gone. Folding the link
  onto the task makes this *more* likely to be missed, not less, because the
  upsert is a single statement with no join to remind you. **Every inbound path
  filters `deletedAt IS NULL AND syncState <> 'unlinked'` on the task and
  `Integration.revokedAt IS NULL` on the integration it resolved through**, and
  deleting a task sets `syncState = 'unlinked'` in the same transaction. The
  `revokedAt` half is the tenant boundary, not a tidiness measure — see
  Integrations.
- **Pending ops for a deleted task are dropped, not drained** (see the publish
  consent re-check — same rule, applied to every op kind).
- **`fetchOne` returning `null` needs a defined meaning.** The provider seam
  declares `Promise<RemoteTask | null>` and never says what `null` is. Decide:
  `null` = the issue is gone (deleted or transferred) → set `syncState='unlinked'`
  and surface it; a *transport* failure throws and retries. Conflating the two
  gives either an infinite retry or a silent unlink.
- **`issues.deleted` and `issues.transferred`** are real events and neither is
  handled. A transfer gives the issue a new number in a new repo, so the old
  `externalId` starts 404ing — which is indistinguishable from a deletion unless
  the transfer event is consumed.
- **Uninstall / `syncEnabled = false` / repo deleted.** `Integration.revokedAt`
  exists; nothing says what happens to ops pointing at it. They fail auth forever.
  Every op needs a `maxAttempts`, a terminal `dead` status, and a visible
  dead-letter — there is no give-up rule anywhere in the outbox today.
  `installation.deleted` therefore does two things in one transaction: set
  `revokedAt`, and dead-letter that integration's pending ops rather than leaving
  them to burn attempts against a token that will never mint again. Setting
  `revokedAt` must also stop *inbound* routing through the row (see Integrations)
  — that is what keeps a later install of the App on the same org by a **different
  Antgrid account** from resolving into this one.
- **Account deletion does not cascade.** See Open items; this is not a schema
  decision.

### Scale: the first sync is the hard one

A 5,000-issue repo is an ordinary target on day one, and three things break:

- **Per-account `number` allocation serializes the entire import.** The
  interactive path takes `pg_advisory_xact_lock('task:' || accountId)`, reads
  `max+1`, inserts — 5,000 serialized round trips on one key, during which **every
  interactive task-create on the account blocks**. Bulk import allocates a
  contiguous block of numbers once and assigns from it in memory.
- **Bodies are stored twice** — `Task.body` and again inside `remoteSnapshot`,
  which must carry `body` because `body` is in the merged field set. That is the
  price of the shadow snapshot and it is worth paying, but size it deliberately.
- **`webhook_events` becomes the largest table in the database**, with a full
  payload copy per event, one non-PK index, and no retention policy. It needs both
  before a busy repo is connected.

Comment import is the unbounded one: 5,000 issues × 10 comments is 50k requests,
roughly ten hours of primary budget for a single repo. Cap it (see Open items) —
that item is now blocking rather than deferrable.

## Assignment

Two orthogonal axes. Conflating them is the mistake to avoid.

**1. The human assignee — one column pair on `Task`.** Who owns the outcome.
Either `assigneeUserId` (an account member) or the snapshot triple
`assigneeExternalId` + `assigneeLogin` + `assigneeAvatarUrl` (a provider user who
is not one), never both — a `CHECK` enforces it and setting the internal id
clears all three snapshot fields in the same write.

This is Superset's shape, adopted for the reason the appendix gives: it deletes a
join table, a `CHECK`, two partial uniques and an element-wise merge, and the
thing it buys with all that machinery is multi-assignee, which nothing in the
product actually reads. What it costs is real and is stated here rather than
discovered later.

**GitHub allows up to ten assignees; we keep one.** Two rules follow, and the
second is the one that makes the first safe:

- **On import, prefer the assignee that maps to an account member**, falling back
  to `assignees[0]`. Never `assignee` (the deprecated singular field) — it is
  whichever one GitHub picked, not whichever one matters to us. Where the issue
  has more than one, surface a *`+n` marker sourced from `remoteSnapshot`* on the
  row and in the sheet: the snapshot carries the full remote array regardless of
  what the column holds, so the UI can say "and 2 others on GitHub" without a
  second table. Lossy display is acceptable; pretending the issue has one
  assignee is not.
- **Assignee never pushes in v1.** `PATCH /issues/{n}` replaces the whole
  `assignees` array, so a one-element push against a two-assignee issue
  **unassigns a co-assignee in the user's own repo** — the precise data loss the
  join table was introduced to prevent, and dropping the table does not drop the
  API semantics. Assignment is therefore inbound-and-local: imported from GitHub,
  editable in Antgrid for routing and filtering, and not written back. If assignee
  push is ever wanted, it needs read-modify-write against the live remote array
  (not against `base`), and that is a phase of its own.

That single decision deletes phase 6 from the critical path along with
`IntegrationIdentity`'s write side. The table is still needed, but only for
reads — resolving an inbound login to a member — because Better-Auth's `account`
row stores the provider's numeric `accountId`, not the GitHub login:

```
IntegrationIdentity  id, integrationId, userId?, provider, externalUserId,
                     externalLogin, avatarUrl?, linkedAt
                     @@unique([integrationId, externalUserId])
```

**That unique was `[provider, externalUserId]` here until phase 6 built it, and
globally unique is wrong.** Two Antgrid accounts can each hold issues assigned to
the same GitHub user; one shared row carrying a `userId` resolves that GitHub
user into a member of whichever account wrote it first. It is the cross-tenant
mis-assignment `integrations_provider_installation_key` exists to prevent for
routing, arriving through identity instead. `integrationId` is account-scoped, so
the row is per-tenant by construction; the cost is one row per account per
provider user, which is nothing.

Populated from the App's member list and from any assignee seen on an inbound
issue. A GitHub assignee with no Antgrid member is stored as the snapshot triple
and surfaced read-only — do not invent a user. Assigning an Antgrid member with
no linked GitHub identity is fine, because nothing is going to GitHub anyway;
that is one more thing the no-push decision makes simple rather than conditional.

**The snapshot triple must survive an inbound merge that does not mention it.**
A webhook for a label change carries the full issue, so a naive upsert of the
whole `taskData` object rewrites the assignee columns too — which is correct when
the remote assignee changed and destructive when the local user reassigned it
between events. It is a scalar now, so it merges by the normal three-way rule
against `base`; the only new hazard is writing a blanket upsert that skips the
merge, which is exactly what Superset does.

**Shipped in phase 6, web half** (`web/src/models/integration-identity.ts`, the
`integration_identities` migration, and the assignee arms of `github-import.ts` /
`github-inbound.ts`). Three things it settled that this section left open:

- **The membership filter is the whole security property.** A provider user
  resolves only through a Better-Auth `account` row whose user holds an ACTIVE
  membership of the integration's own account. Drop that filter and any GitHub
  user who ever signed into Antgrid resolves into an unrelated tenant.
- **An identity two members both claim resolves to nobody.** Nothing stops two
  users in one account from both holding `providerId="github", accountId="5"`,
  and there is no way to tell which is real — so it stays external, which is a
  true statement about somebody we cannot name rather than a guess about somebody
  we can. The obvious future edit is "pick the oldest link"; it is wrong.
- **Resolution is one-way.** The upsert `COALESCE`s an existing `userId` and
  never clears it: a member who unlinked their GitHub OAuth has not stopped being
  the assignee of the issues already imported, and an inbound payload is not
  evidence about who a person is. Identities are also upserted in **sorted**
  order, because `ON CONFLICT DO UPDATE` holds a row lock to commit and payload
  order deadlocks two drainers whose issues name the same people in different
  orders.

**Shipped ahead of phase 5: the verb that clears a conflict**
(`POST /tasks/:number/conflict/resolve`, `resolveTaskConflict` in
`web/src/models/task.ts`, and the `Unsettled changes` section of the app's task
sheet). It is phase-5 work by the plan's ordering and could not wait for it: the
inbound half already raises `syncState = 'conflict'` and folds the losing value
into `Task.localConflict`, deliberately sticky, so until this landed every
conflict ever raised was permanent and unreadable.

Three properties the outbox must not undo:

- **`remoteSnapshot` is never touched by a resolve.** Restoring a losing local
  value leaves `local != base`, which is exactly what a future push sends and
  what stops the next inbound (`remote == base`) from re-clobbering it. Re-seeding
  the base here would make the resolve a no-op that looks like it worked.
- **Status is resolved in provider space** (`{state, stateReason}`), mapped back
  through `fromRemote` against the live row only at the moment a side is taken.
  Comparing in Antgrid space is many-to-one and is the self-sustaining push loop.
- **`syncState` returns to `synced` only for a row currently in `conflict`, and
  only when the conflict map empties.** A `pending` row stays pending — the push
  has not happened — and acknowledged labels do not count toward emptiness.

`assigned_to_member` becomes the strict reading in the same change — at least one
assignee resolves to a member — and `remoteSnapshot.assignees` carries the full
remote array, optional so older snapshots still parse and never merged, which is
what feeds the `+n` marker without a second table.

**2. Run target — `runTargetDeviceId` + `runTargetProjectId`.** Which machine,
and which checkout, should actually run it. Never synced anywhere; it is the
Antgrid-native half and is what lets a task queue for `desktop-1` while you are
on your phone. Validated against the caller's account device inventory at write
time; a device that is later revoked leaves the field dangling and the UI shows
"target unavailable".

**Notification — deferred until everything else ships.** No push, and no email
either, in this feature. Assignment surfaces as a **badge and a count on next
fetch**, which the app gets for free from the list it already loads.

The deferral is deliberate rather than an oversight: web cannot originate a
sealed push (constraint 4), so doing it properly needs its own design — either
web asks relay for a *contentless* wake (new `/internal/` route; the phone then
fetches over HTTPS) or the bridge polls tasks and seals the push itself. The
contentless wake is the better shape because it keeps web out of the E2E path
entirely. Whatever we pick, **do not smuggle task text through the relay.**

## Provider seam

One TS interface, one adapter per provider, registered in a map. Everything
above the seam speaks the normalized vocabulary.

```ts
interface TaskProvider {
  readonly id: "github" | "linear" | "jira";
  auth(integration): Promise<AuthedClient>;      // installation token, cached to expiry
  listSince(repo, cursor): Promise<RemoteTask[]>;
  fetchOne(task): Promise<RemoteTask | null>;
  applyOp(op, client): Promise<PushResult>;      // snapshot + pushedHash + noEffect[]
  parseWebhook(headers, body): WebhookEvent[];   // Zod-validated
  mapStatus: { toRemote(s): RemoteState; fromRemote(r, local): TaskStatus };
  mapIdentity(remoteUser): { externalUserId, externalLogin };
}
```

Rules that keep the seam honest:
- `RemoteTask` is Zod-validated at the boundary. Provider payloads are claims.
- **`fetchOne` returning `null` means the remote issue is gone** (deleted or
  transferred) and unlinks; a transport failure **throws** and retries. Conflating
  the two gives either an infinite retry or a silent unlink.
- **`applyOp` reports what the provider did not accept.** A `200` that silently
  dropped an assignee is not a success — see the no-effect rule above.
- No provider name appears above the seam except in the registry and the UI icon.
- Anything a provider has and we do not model goes in `remoteSnapshot`, not a new
  column. Columns are migrations; a Jira custom field is not worth one.
- Status mapping is per-provider, and `fromRemote` takes the **local** status, not
  the snapshot — the snapshot holds the provider projection and has no sub-status
  left in it to preserve (see the merge section). Linear and Jira have real
  workflow states, so `fromRemote` for them is a lookup rather than the lossy
  open/closed collapse GitHub forces — which is also why the provider-space rule
  lives behind `toRemote`: for a provider whose vocabulary is not lossy, it
  degenerates to the identity and costs nothing.

## Wire & bridge changes

Adding any message type requires **all** of: schema in `bridge/src/protocol.ts` →
add to `AbMessageSchema` union → add to `KNOWN_TYPES` → export the type → handle
in the `handleAbMessage` switch (`bridge/src/agent-core.ts` — **not** `index.ts`,
which is only the CLI entrypoint). Miss one and it silently fails.

New/changed:

1. **Repo identity on the projects advert.** Extend the `agent:projects` project
   object with an optional `repoKey`. Optional keeps old apps working. Bridge
   reads `git remote get-url origin` at project warm-up, normalizes, caches.
2. **`ProjectBinding` upsert** — bridge POSTs `{deviceUuid, localProjectId,
   localPath, repoKey}` to a Bearer-gated web route. `deviceUuid` is the
   spelling both task-side routes take; `deviceId` is rejected as a malformed
   body. Reported once per project open from `HostServer.startCore`, not on the
   60s heartbeat cadence — a binding is a fact, not a heartbeat. No new auth
   work.
3. **`session:create` gains optional `taskRef`** (`{taskId, number}`), echoed on
   `session:updated` so the app can label a session with its task. The bridge
   also reports run status back to web so a `TaskRun` row exists even when the
   phone is offline — pushing the per-session `WorkStatus` it already computes,
   never a derived task state (see the `WorkStatus` note below). Shipped as
   `bridge/src/task-run.ts`: a fire-and-forget reporter driven off `session:updated`
   with a per-session memo, ending a run when a session leaves the live set. It
   sends no `resultSummary` and no `prUrl` — `TaskRunBody` has no field for
   either, so a later edit reading only the route contract cannot add one.
4. **Checkout routing:** a task verb that only reads the web DB is *not*
   filesystem-variable and must stay out of `CHECKOUT_VARIABLE_MESSAGE_TYPES`.
   Anything that touches the working tree (creating the task branch) is, and must
   be added there *and* to the hand-mirrored `kCheckoutVariableMessageTypes` in
   `app/lib/project/project_message_classification.dart`.

Nothing here goes in `packages/antgrid-wire` or `packages/antgrid_relay_client`
unless it must be shared with the relay — those are Apache-2.0 and the boundary
is one-way (`LICENSING.md`).

The `agent:projects` advert is parsed by hand in Dart
(`app/lib/services/control_plane_client.dart`), so adding `repoKey` is a
two-sided edit whose drift is silent — the same hazard class as
`CHECKOUT_VARIABLE_MESSAGE_TYPES`. Add both halves in one commit.

> `relay/relay-requirements.md` is marked **archived** at the top — it describes
> the v1/v2 `register`/`challenge` + pairing-ceremony protocol that no longer
> exists. Do not design against it; `relay/CLAUDE.md` is current.

## Implementation notes verified against the tree

Everything below was checked against the code, not inferred. These are the
details that decide whether a phase takes a day or a week.

### Task → session is smaller than it looks

`app/lib/providers/new_session_action.dart` already performs the exact sequence
"Start task" needs:

```dart
final created = await svc.create(
  name: …, tool: …, command: …, args: …, mode: …,
  isolation: isolated ? 'worktree' : 'shared',
  baseBranch: isolated ? explicitBranch : null,
);
if (created == null) return;
final started = await svc.start(created.id, initialPrompt: …, raiseRefusal: true);
```

A task launcher is a second caller of this path with the fields prefilled — but
**do not copy its error contract from its comments, which are wrong.**

`sessions_service.dart` fails the pending completer with
`SessionOperationException` on `ok:false`, for `create` and for `start` when
`raiseRefusal: true`. So a **coded refusal throws**; `null` occurs only on
`ok:true` carrying no session. The comment at `new_session_action.dart:224` says
the opposite ("an agent rejection comes back as a null result") and the `created
== null` guard beneath it is written to that stale belief. Typed failures are
then *deliberately* allowed to escape so the composer can show their display
message — which is fine on the New Session page and **not** fine anywhere else.

Consequences for this feature:

- A Start-session sheet launched from a task has no composer to catch a
  `SessionOperationException`. It must handle the typed refusal itself and show
  the reason in the sheet. Assume-null and it becomes an unhandled async error on
  the most ordinary failure there is (session cap reached, unknown tool).
- `TimeoutException` on a dropped reply is a separate, retryable case and still
  needs its own guard.
- Fix the stale comment and the guards in `new_session_action.dart` **before**
  phase 3 rather than propagating them into a second caller.

The one contract that is accurate as documented: the caller re-checks the
selected project after each await (`selectedRegistrationIdProvider`, not the
project id itself), because the user can switch projects mid-flight.

### The branch name comes free — but is not an identifier

`WorktreeManager.nextBranch` builds `antgrid/<slug>-<8 chars of sessionId>`,
where `slug` is `sessionSlug(sessionName)`: lowercased, everything outside
`[a-z0-9._-]` collapsed to `-`, leading/trailing `.`/`-` trimmed, capped at 48
chars. Every candidate is validated with `git check-ref-format` and
collision-suffixed.

So naming the session `#123 Fix flaky test` yields
`antgrid/123-fix-flaky-test-a1b2c3d4` with no new code — the `#` is stripped and
the leading dash trimmed. Good traceability for a human reading `git branch`.

**Do not parse the branch to recover the task.** The slug is lossy, the suffix
is arbitrary, and the user may rename the branch. `TaskRun` is the record of
truth; the branch name is a courtesy to humans.

### Naming a session opts it out of auto-naming

`session-manager.ts:518` sets `manuallyRenamed: name !== undefined` on create,
and `applyAutoName` no-ops for a manually-renamed entry. Passing a task-derived
name therefore permanently suppresses the agent's OSC/structured auto-title for
that session.

That is the right trade — the task title is more meaningful than a scraped TUI
title — but it should be a decision, not a discovery. If we ever want both, the
session list needs a second display field; do not try to un-set
`manuallyRenamed`.

### `WorkStatus` cannot close a task

`bridge/src/work-status.ts` is the obvious candidate for driving `TaskRun`
status, and it is right for *liveness* — `working | attention | error | done`
per session, already computed and already on the advert. But its `done` does not
mean "the work is finished":

```ts
case "task_complete":
case "idle":         return "done";
default:  return activeTurns.has(sessionId) ? "working" : "done";
```

`done` means *no turn is open* — an agent that finished, an agent that went
idle, and a freshly-opened chat all read `done`. (The default branch is also
`activeTurns.has(sessionId) || activeTurns.has(UNATTRIBUTED_TURN)`, so an
unattributed turn anywhere reads `working` — which only strengthens the point.)
Auto-closing a task on it would close a task every time the user stops typing.

Rules that fall out:
- `TaskRun.status` tracks `WorkStatus` — that is exactly what it is for.
- **`done` never writes `Task.status`.** This is the whole finding; do not
  generalize it further than it goes.
- The other two directions **are** safe, and refusing them has a cost. `working →
  in_progress` and `attention → blocked` are unambiguous and reversible, and they
  are the only automatic writers `Task.status` will ever have. Without them, three
  of the five statuses (`open`, `in_progress`, `blocked`) all map to GitHub `open`
  and are **hand-maintained** — and a hand-maintained status field is the most
  reliably abandoned field in every tracker ever shipped. Within a month of
  dogfooding every task reads `open` regardless of reality, and the five-state
  vocabulary this plan argues for becomes dead weight that only makes sync harder.
  Apply both, and let a manual edit pin the field against further automatic
  writes.
- **Both automatic writes are compare-and-set on the observed status, not blind
  updates.** Read the current status, then write with it in the `WHERE` clause:

  ```sql
  UPDATE tasks SET status = 'in_progress'
  WHERE id = $1 AND status = $observed AND deleted_at IS NULL
  ```

  Zero rows updated is a no-op, not an error. Without this, the gap between a
  `working` advert arriving and the write landing is enough for a user to close
  the task from the app or a webhook to close it from GitHub, and the automatic
  write drags a finished task back to `in_progress` — an automatic writer undoing
  a human one, which is the failure that makes people stop trusting the field
  entirely. Superset's `task.start` does exactly this (see the appendix); it is
  four extra characters in the `WHERE`.
- **Guard the source state as well as the target.** `working → in_progress` fires
  only from `open`, and `attention → blocked` only from `open` or `in_progress`.
  Never from `done` or `cancelled` — a re-opened session on a finished task is a
  normal thing to do and must not reopen the task.
- **Neither automatic write should produce a `TaskSyncOp`, and with the merge in
  provider space neither does.** Both move a task between statuses that project to
  the same GitHub `state`, so the status diff is empty by construction. If one of
  these writes is ever seen enqueueing an op, the provider-space rule has been lost
  somewhere and the no-op push loop is back — that is the cheapest available test
  for the regression, and worth writing as one.
- The only automation-grade completion signal is the raw `NotificationType`
  `task_complete` (kept in `WorkStatusState.notifications` before the fold
  discards the distinction). Even then, *propose* the transition in the UI
  rather than applying it; agents declare completion optimistically.
- `attention` is the genuinely valuable one to surface on a task row: it means a
  running agent is blocked on a permission or a question. It is the highest-value
  pixel in the feature — an agent waiting on you, visible from the list — and it
  belongs in the row spec, not only in the detail.

### Base-branch drift must be asked of Git

`CheckoutRecord.baseRef` carries an explicit contract: *"deliberately WRITE-ONLY
… a reader asking 'has the base moved since?' must put that question to Git
(merge-base against the session branch), never trust this string."* A task view
showing "behind `development` by N commits" runs `git merge-base` in the bridge
and returns a number; it does not read `baseRef`.

### Auth: cookie for the app, Bearer for the bridge

The Flutter app holds **both** credentials — a replayed Better-Auth session
cookie (`CookieApiClient` + `AuthStorage`, used today by `AccountApi`) *and* an
OAuth `client_credentials` device token (`LicenseTokenMinter`, mirroring
`bridge/src/auth/oauth-client.ts`).

**Decision: task routes take the cookie from the app and the browser, and the
Bearer token from the bridge.** Gate them the same way `routes/agents.ts` already
splits its two gates path-by-path — `requireUser` for app and browser,
`requireBearerJwt` for the bridge. Both resolve to a `userId`, so the account
lookup below is shared either way.

The device token is the more *convenient* carrier, and an earlier draft of this
plan recommended it on that basis: it re-mints silently against the keychain-held
client secret, whereas an expired session cookie needs a fresh magic-link or OAuth
sign-in. It loses to one thing. **The credential is the only actor-type signal the
server has.** `requireBearerJwt` blanks `sessionId`, so an app presenting a device
token is indistinguishable from the agent-driven bridge, and the publish rule above
— keep the irreversible verb off the programmatic gate — has nothing left to key
on. Publishing is the one unrecoverable action in the feature; keeping it gateable
outranks avoiding a re-auth prompt.

Two consequences to build to rather than discover:

- **`tasks_service.dart` sits on the existing `CookieApiClient`**, so the app needs
  no new bearer-capable HTTP client base. That is the cheap half of this decision
  and the reason it costs nothing today.
- **Cookie expiry becomes a task-surface UX problem**, not a hypothetical. A `401`
  on a task call has to route to re-auth *without* discarding the user's
  in-progress edit — an unsent title change must survive the sign-in round trip.
  Stated here so it lands in the phase-2 estimate instead of surfacing as a bug.

The `requireBearerJwt` prerequisite in the build order (scope enforcement plus a
`revokedAt` check) is therefore blocking for the **bridge** path only, not for the
app. It is no less a prerequisite: the bridge writes tasks, and widening the Bearer
gate before it can be scoped or revoked is precisely what that prerequisite exists
to prevent. **Shipped in `e7f08553`** — the gate now requires the `agent` scope,
rejects a revoked device, and sets `deviceId`; the run-report route depends on all
three.

### Account resolution — pick one of the two helpers, deliberately

Tasks are account-scoped, and `AccountMember` is the record of truth —
`User.accountId` is a denormalized pointer the schema explicitly warns is not
unique across a team. Do not read `user.accountId` in task code.

But "one helper, used everywhere" is aspirational, not the current state. There
are **two**, and they differ in a way that decides which account a task lands in:

- `findActiveMembership(userId)` — membership only, null if there is none.
- `resolveBillingAccountId(userId)` — membership first, **falling back to the
  user's own owned account**.

There is no shared middleware; call sites pick one directly, and `routes/ui.tsx`
documents a deliberate decision *not* to use `resolveBillingAccountId`. Tasks
must state which one they use and why. Recommended: `findActiveMembership`, with
an explicit 403 when there is none. The owner fallback silently writes a task to a
*different* account than the team the user is acting in, which is precisely the
bug class this section exists to prevent.

**Every member of an account can read and write every task on it.**
`AccountMember.role` is `owner | member` with no per-resource ACL, so there is no
"private to me" task — including the private notes the entire Publishing section
is written to protect. Adding a teammate retroactively grants them the full task
archive. At minimum, restrict **integration install, repo linking, `pushEnabled`
and `publishNewByDefault` to `owner`**; anyone can publish otherwise. And say it
in the customer-facing copy (see Trust posture).

Per-account `Task.number` allocation uses the existing anti-TOCTOU pattern from
`checkCapAndUpsert`: `SELECT pg_advisory_xact_lock(hashtext(<accountId>))` as the
first statement inside `prisma.$transaction`, then max+1 and insert.

### Env vars must be optional, or setup breaks

`web/src/env.ts` declares `GITHUB_CLIENT_ID`/`GITHUB_CLIENT_SECRET` as
**required** (`z.string().min(1)`). Adding `GITHUB_APP_ID`,
`GITHUB_APP_PRIVATE_KEY` and `GITHUB_APP_WEBHOOK_SECRET` the same way would fail
env validation on every existing `.env`, every CI job and `npm run setup`.

Declare them `.optional()` and feature-detect the integration, matching how
`ZEPTOMAIL_*`, `PADDLE_*` and `RAZORPAY_*` are handled (and the 503-on-unconfigured
precedent in `routes/webhooks.ts`). Note the private key is a multi-line PEM:
either base64 it into a single-line var or normalize `\n` escapes at load, and
decide that before writing `scripts/dev-setup.ts` support.

### The App private key is a cross-tenant master key

Every other secret in `web/` is scoped to Antgrid's own infrastructure. This one
mints installation tokens for **every customer's** installation — compromise means
read/write on every linked repo of every customer, private ones included. That
asymmetry decides how it is handled, and none of this is optional:

- **Not in `.env` in production.** A separate secret store. `scripts/dev-setup.ts`
  generates or writes only a development key, never the production one.
- **No at-rest story exists to lean on.** There is no symmetric-encryption
  primitive anywhere in `web/` — `crypto/` holds Ed25519 JWT signing and
  `util/hmac.ts` is HMAC + `timingSafeEqual`. So do **not** persist installation
  tokens: hold them in memory, cached to their 1-hour expiry, and re-mint. The
  `Integration` model has no token column and must not gain one.
- **Rotation, planned before launch** — for both the private key and the webhook
  secret. GitHub supports two active webhook secrets during rotation; verify
  against either while a rotation is in flight.
- **Never log a raw error from a GitHub call.** `app.ts`'s top-level handler
  `console.error`s anything that reaches it, and Octokit/fetch error objects
  routinely carry the outgoing request headers — including
  `Authorization: Bearer ghs_…`. Every call site catches and logs a field-selected
  object, following the `logPaddlePaymentFailure` precedent and the ZeptoMail path
  redaction already in `app.ts`.

### Device tokens must be scoped and revocable before they carry tasks

`requireBearerJwt` verifies signature, issuer and `uid` — it checks **no scope**
and never consults `Device.revokedAt`. That is safe today because Bearer gates
only two narrow routes in `routes/agents.ts`, both of which re-scope every write
by `userId`. Extending it to task CRUD changes the exposure:

- A lost or stolen phone's token reads **every task body on the account** — the
  customer names, unreleased plans and security findings this plan cites as the
  reason publishing needs a consent moment.
- Device revocation deletes the OAuth client and pushes a relay revoke, but does
  not invalidate an already-minted JWT for web's own routes. With
  `m2mAccessTokenExpiresIn: 3600`, **a revoked device keeps full task read/write
  for up to an hour.**

Before phase 2 ships task routes on the Bearer gate: enforce `scopes` in
`requireBearerJwt`, and have task routes resolve
`device.findFirst({ userId, deviceId: claims.deviceUuid, revokedAt: null })`. The
second doubles as the actor-type signal the publish rule needs.

### Migrations are cheap; the generated client is not automatic

`web/tests/helpers/preload.ts` builds one template DB per test process with
`prisma migrate deploy` and clones it per file, so new tables add no measurable
test cost. But the Prisma client is generated, not inferred — run
`bun run --filter antgrid-web prisma:generate` after every schema change;
`bun run migrate` only applies migrations.

### Multiple web instances are real, so the drain must tolerate them

`web/Dockerfile` exists and web is deployed behind a proxy (`TRUSTED_PROXY_IPS`
exists for exactly that), so more than one instance is a live possibility rather
than a hypothetical. A naked `setInterval` drain in each replica double-applies
outbox ops — and for `issue.create` a double-apply is **two public issues from
one consent**. `FOR UPDATE SKIP LOCKED` on the claim (see "Where the loop runs")
makes that safe without a leader, which is the point: the failure mode of a
broken election is a silently dead queue, and the failure mode of a correct claim
is nothing at all.

### Handler: explicitly out of scope

**No Handler mapping in this feature.** A task never seeds the Handler's
backlog, and no task verb touches `bridge/src/handler/`. The naming separation
still stands — Tasks and Handler backlog are different concepts and must read
that way in every UI string — but there is no code path between them.

Recorded because the seam looks tempting and someone will propose it:
`extract.ts` takes one instruction string with hard bounds — `MAX_INPUT_CHARS =
4000` and `MAX_ITEMS = 20` **truncate**, only `MAX_ITEM_CHARS = 400` fails the
parse. Truncation is the weaker objection but the more dangerous behaviour: a
discursive issue body would be silently cut rather than rejected, so a Handler fed
one would act on an arbitrary prefix and report success. If this is ever
revisited it needs a deliberate excerpt strategy, not a raw body.

## Surfaces

- **Flutter app** (`app/lib/`) — the primary one. New task list + detail screens
  and a `tasks_service.dart` on the `CookieApiClient` pattern. Design system
  only: `AbIcons.*`, `AbTokens`, existing `AbX` widgets — no Material, no inline
  colour/spacing literals, sans for chrome and mono for data.
- **Web HTMX UI** (`web/src/ui/`) — the natural home for the cross-machine
  "everything assigned to me" view. Cheap *relative to the app*, but not free: it
  would be the first mutating HTMX in the codebase, and `docs/tasks-ux.md` records
  that its idiom notes describe the `site-redesign` branch rather than
  `development`. A read-only page is a defensible v1.
- Because tasks come over HTTPS from web, not through the relay, **the task list
  works with every dev machine offline.** That is a real argument for this
  architecture and should be visible in the UI (a task can be read and edited;
  only "run it" needs a live bridge). It is *not* the same as working with the
  **network** offline — see the states table in `docs/tasks-ux.md`.

## A task body is untrusted input to an agent

This is the sharpest edge in the feature and it is easy to miss, because every
other risk here points outward — private text escaping to GitHub — and this one
points **inward**.

Once GitHub import ships, the task body is authored by whoever opened the issue.
On a public repo that is an anonymous stranger. `docs/tasks-ux.md` renders the
body into the agent's initial prompt; that becomes `session:start`'s
`initialPrompt`, which `bridge/src/initial-prompt.ts` turns into agent spawn argv
in terminal mode or the first user turn in chat mode. So a stranger's text
becomes **the opening instruction to an agent holding shell and filesystem access
on a worktree of the maintainer's real repository**, one click after triage.

Argv injection is already handled well — `initial-prompt.ts` passes the prompt as
a discrete argv element with verified `--` separators per agent. **Prompt
injection is not handled at all**, and the two documents bound the body only for
*quality* ("a 10k-char thread is a bad brief"). That is a different requirement
wearing the same clothes: a 200-character body is a fine brief and a perfectly
good injection.

Rules, all of them cheap now and awkward later:

- **Provenance decides the launch path.** A task whose body did not originate in
  Antgrid (`source != 'local'`, or any body touched by an inbound sync) requires
  the prompt sheet to be **seen** before launch. No one-key `r` accelerator
  straight to a running agent for imported tasks; the accelerator opens the sheet.
- **Label the untrusted span in the rendered prompt**, delimited, with a line
  saying it is an issue body from an external reporter and is data, not
  instructions. It is not a guarantee — nothing is, against a determined injection
  — but an unlabelled paste is strictly worse and costs the same.
- **Show provenance on the row and in the sheet.** `source` and the task's own
  `externalProvider`/`externalUrl` already record it; the UI currently does not
  use it for this.
- **Isolation is a mitigation and should be treated as one.** Defaulting a task
  run to `worktree` already bounds the blast radius to a throwaway checkout, which
  is a second reason that default is right.
- **Never let a task body reach a non-interactive runner.** Any future "run this
  task automatically" path re-opens this at full severity with nobody watching.

## Trust posture

Task title, body and comments — including comment text written by third parties
on GitHub — are plaintext in our Postgres, readable by every member of the
account. That is a genuine widening of what Antgrid's servers hold, and the
current claim ("the relay is zero-knowledge; agent traffic is E2E") needs a
second, equally plain sentence next to it:

> *Your code, terminal output and agent transcripts never leave your machine.
> Task titles, bodies and comments are stored on Antgrid's servers in plaintext
> and are visible to everyone on your account.*

**Do not call it "metadata."** It is full body text and full comment threads; a
task is described three paragraphs up as the place people keep a customer name,
an unreleased plan, a security finding. Shading that as metadata in
customer-facing copy is what turns a defensible design decision into a trust
incident the first time someone reads the schema. And "like your issue tracker's"
does too much work — GitHub Issues is where you *intend* to write publicly.

Enforce the boundary structurally: **never write agent output, diffs or
transcripts into a task body or comment.** `TaskRun.resultSummary` is capped at
`VarChar(200)` in the schema for exactly this reason — a rule a column enforces
survives, a rule stated in a design doc does not. Anything richer stays on the
machine behind a `sessionId` pointer. This is easy to hold now and impossible to
retrofit.

**Nothing scans a body for secrets before a publish.** Publishing is a single,
well-defined, low-volume code path with an irreversible outcome, which makes it
the one place a pattern scan is worth its false-positive rate: a pasted `.env`
line or a cloud key in a body a human is about to make public should require an
explicit override rather than sailing through. Worth doing when phase 5's publish
half ships; not worth doing anywhere else.

## Build order

1. **Repo identity** — remote normalization in bridge, `repoKey` on the advert,
   `Project` + `ProjectBinding` tables, Bearer-gated binding route. No user-visible
   feature; everything else stands on it.
2. **Tasks core** — `Task`/`TaskComment` tables, account-scoped CRUD under both
   gates (cookie for app/browser, Bearer for bridge), per-account `number`
   allocation, the assignee column pair. Ships as a usable local task list.
   **Prerequisite:** scope enforcement and a `revokedAt` check in
   `requireBearerJwt` — task routes must not widen the Bearer gate before it can
   be scoped or revoked.
3. **Task → session** — `taskRef` on `session:create`, `TaskRun` rows (with
   `branch`/`prUrl`), `working`/`attention` driving `Task.status` **via
   compare-and-set**, "Start task" in the app. **This is the demo.** Everything
   before it is plumbing and everything after it is reach. Fix the stale
   `new_session_action.dart` refusal contract first.
4. **GitHub App inbound** — App registration, install flow on an account settings
   page, `Integration`/`IntegrationRepo`, webhook verify + `webhook_events`
   ingest, one-way import with the shadow snapshot. Read-only mirror is already
   useful. Ships with the **import scope filter** and the PR exclusion, and with
   the untrusted-body prompt rules — the moment import lands, a stranger's text
   can reach an agent.
5. **Outbound + reconcile** — `TaskSyncOp` outbox, `SKIP LOCKED` drain, hash-based
   echo suppression, `since=` reconcile poll, rate-limit buckets. Closes the loop
   to bidirectional, **per repo and opt-in** (`pushEnabled`). Ships in two halves,
   in this order: **edits** to already-linked tasks first (PATCHes, low blast
   radius), then **publish** — `issue.create`, the required `publish` field, the
   create-form toggle, the after-the-fact action, repo selection, and
   `publishNewByDefault`. Publish depends on the drain being trustworthy, and it
   is the step that can put private text in public — do not build it first because
   it demos better.

   **Do not start phase 5 until the five questions below have written answers.**
   Every one is a correctness property that cannot be retrofitted once users have
   linked tasks. Proposed answers are in `docs/tasks-phase5-answers.md`, where
   three turn out to be settled by what 4b–4d had to build and two — the
   echo-suppression key and the no-effect counter — still need a decision:

   1. What exactly is the echo-suppression key, and how does it distinguish our
      own write from a third party's write we just clobbered?
   2. Where does the losing local value physically live on a conflict, and what
      clears it?
   3. What serializes the drain against the webhook processor for one task?
   4. What detects a push that succeeded but had no effect, and what stops the
      retry loop?
   5. When a local task is deleted, what happens to its external identity, its
      pending ops, and the next inbound webhook for its issue?
6. **Assignee import** — `IntegrationIdentity` reads, inbound login → member
   resolution, the snapshot triple, the `+n` marker for multi-assignee issues.
   **No push**, so this is a small phase rather than the largest one, and it can
   land alongside 4 rather than after 5. No notification of any kind in it.
7. **Notifications** — only after 1–6 are in place and dogfooded. Needs its own
   design (see the Notification note above).

UI is not a phase; it is built alongside 2 and 3 on both surfaces. Labels ship
with 2, since a task list without them is unusable for triage from day one. See
`docs/tasks-ux.md` for the full interaction design.

1–3 are dogfoodable without GitHub at all. Hardcoding one installation and
`antgrid/antgrid` behind a flag is fine for 4–5; the shortcut belongs in config
and UI, never in the tables.

## Open items

- **Entitlement.** Decide now whether tasks are free or a Pro lever —
  `CAPABILITIES` in `bridge/src/entitlement.ts` is the single place a gate goes,
  and retrofitting one after users have tasks is ugly. Do not gate for
  dogfooding; do decide. Note there is already an *implicit* gate: minting a
  device token throws `"no subscription for user"`, so every Bearer-gated task
  route requires an active subscription whether or not we add a capability. With
  the app on the cookie gate (see Auth), that implicit gate covers the **bridge**
  path only — the app and browser reach task routes with no subscription check at
  all unless one is added deliberately, which is an argument for deciding rather
  than inheriting.
- **`encryptOAuthTokens`.** The App decision means we no longer *need* it for
  this feature, but sign-in tokens are still plaintext. Separate ticket, still
  worth filing.
- **Account deletion needs explicit deletes, not a cascade.** `deleteUserAccount`
  **tombstones** — it sets `productAccount.deletedAt` and scrubs the `User` row
  rather than deleting either — so a `Task.accountId → ProductAccount onDelete:
  Cascade` FK **never fires**. This is not hypothetical: `models/account-member.ts`
  already carries a comment recording that `account_members.user_id ON DELETE
  CASCADE` never fires for exactly this reason. Task bodies in plaintext would
  survive a "deleted" account indefinitely, directly against Trust posture. Needs
  explicit deletes inside that transaction, plus a GitHub App uninstall attempt.
- **Third-party personal data has no retention story.** `Task.assigneeLogin`
  and `assigneeAvatarUrl`,
  `IntegrationIdentity.externalLogin`/`avatarUrl` and `TaskComment.authorExternalLogin`
  + `body` are personal data about **GitHub users who never signed up for
  Antgrid**, populated automatically from inbound issues. Add to that
  `remoteSnapshot` (a second full copy of every synced body) and
  `webhook_events.payload` (a third, raw, never purged). Decide the lawful basis
  and what "delete my data" means for someone who was merely assigned an issue —
  before the first non-dogfood customer, not after.
- **Comment volume — answered: the default is 100.** One provider page:
  `GET /issues/:n/comments` returns 100 per page, so the cap makes a first import
  cost exactly one request per issue (~5,000 requests for a 5,000-issue repo)
  against ~50k uncapped, and it covers the large majority of real threads whole.
  `CommentImportCapSchema` bounds the column at `0..10_000` — 0 is a legitimate
  "no comments", and the ceiling is an abuse bound deliberately far above
  anything real, since the column exists precisely so the one repo that needs
  more can have it. What remains open is the *copy*, not the number:
  deep-link to GitHub for the rest, and say plainly that it is a partial mirror.
  The cap still interacts badly with unhandled `issue_comment.deleted` — the local
  view can never be reconciled to the remote one — and that sentence has to reach
  the user rather than living here.
- **Import scope — the columns exist, the default does not.**
  `IntegrationRepo.importFilterKind` / `importFilterValue` are in the schema
  (`all | label | milestone | assigned_to_member`), so the remaining decision is
  which default ships. It should be **narrow**, so the Antgrid list is *curated
  work* rather than a mirror: pointed at a repo with a few hundred open issues, the
  account-wide "All open" view is unusable and the Running view — the
  differentiator — becomes a needle in a haystack we imported on purpose. `all`
  belongs behind an explicit per-repo opt-in, shown alongside the issue count so
  the choice is informed.

  **The schema ships `@default('all')`, which is the opposite of that lean.** It
  is inert rather than wrong: `IntegrationRepo.syncEnabled` deliberately has no
  default in either the column or the model layer, so nothing imports until a
  caller states it per repo, and the filter default only decides what a caller
  that says nothing gets. Changing it is a one-line migration or a call-site
  argument. But the plan and the schema currently disagree, and the decision has
  to be made where it is actually made — the install flow in phase 4c — rather
  than inherited from a column default nobody chose.

## Recorded decision: how much of "bidirectional" ships in v1

**Not yet decided. Flagged because a cold review of this plan argued the current
split is inverted, and the argument is strong enough to record rather than
bury.**

Bidirectional was chosen deliberately and remains the target. The question is
only *which writes ship in v1*. Walking the five synced fields by what each
write-back buys a team dogfooding on their own repo:

| Field | Value of pushing it | Cost |
|---|---|---|
| `title` / `body` | Low — rare, and renaming a public issue from a private tool is a hazard we then need provenance marks to soften | Full three-way merge + conflict UI |
| `status` | Only ever the close/reopen bit — `in_progress` and `blocked` are unrepresentable in GitHub | The shadow snapshot, which we need anyway |
| `labels` | Some, if triage happens in Antgrid | Element-wise set merge, rename/delete handling |
| `assignees` | Least | **Already cut** — see Assignment; the array-replace semantics make a one-element push destructive |
| `comments` | Some — a reply typed in Antgrid never reaching the issue is a real surprise | **Cut for v1** — see the standing-write-channel note; the second unretractable public verb after `issue.create`, needing its own op kind, its own double-post marker and its own line of trust copy |
| *run outcome* | **The reason the product exists** | Currently prohibited by Trust posture |

Cutting the assignee and comment pushes has already removed those rows' cost from
the plan, which narrows this decision rather than settling it: what remains on the
table is `title`/`body` and `labels`. Note the two comment rows are not the same
thing — a *user-authored* comment is cut, while a single bounded **run-outcome**
comment is exactly what the alternative shape below argues for, and it is a
different verb with a different consent story.

The observation that makes this worth deciding: **the highest-value write-back is
the one we banned, and the low-value ones are the fully-specified ones.** The
Trust-posture rule should forbid transcripts, diffs and agent output — it should
not forbid `branch`, `prUrl` and a diffstat, which are metadata that is already
public the moment the branch is pushed. `TaskRun` now carries those columns; what
is *not* decided is whether a bounded run-outcome comment goes back to GitHub.

The alternative shape, for the record: **import everything, write back only
close/reopen plus one structured run-outcome comment.** It deletes the remaining
element-wise set merge (labels) and the conflict UI — while keeping
`remoteSnapshot` for status, whose justification stands regardless. Call it
roughly a quarter of the sync cost. Note that the assignee and user-comment halves
of this argument have since been settled independently and in the same direction,
which is weak evidence for the rest of it. It also sharpens the remaining question:
having cut the *user* comment push, a run-outcome comment would be the **only**
comment we ever write — which makes it easier to reason about (one shape, one
template, one line of trust copy) and harder to defend as incidental.

The counter-argument is real and is why this is not simply applied: **a dashboard
you cannot act in gets abandoned.** If a task cannot be closed in Antgrid, users
close it in GitHub, and once they are in GitHub they stay. That is why the minimum
write set is not zero.

Decide before phase 5, not before phase 4 — phases 1–4 are identical either way.

## Appendix: how Superset built the same feature

Read against a local checkout of the Superset monorepo (`apps/api`,
`packages/db`, `packages/trpc`, `packages/mcp`, `apps/desktop`) at the time this
plan was revised. It is the closest available prior art — an agent-workspace
product at a comparable stage, shipping a task list that syncs to an external
tracker — so it is worth reading as evidence rather than as a competitor summary.
Four decisions in this document were changed because of it, and two of its
findings were confirmed by it. Paths below are Superset's, not ours.

### The one difference that explains the rest

**Superset did not build a task system. It built a Linear mirror.** `github` is in
their `integrationProvider` enum (`packages/db/src/schema/enums.ts`) but no task
ever carries it; `apps/api/src/app/api/github/` syncs repositories and pull
requests only, and there is no Issues integration at all. Tasks are Linear-shaped
down to the column list: `estimate` in story points, `externalCycleId` /
`externalCycleName`, a `branchName` fetched per-issue from Linear's GraphQL, and a
`task_statuses` table mirroring Linear's workflow states with a `progressPercent`
computed by Linear's own rendering formula
(`integrations/linear/jobs/initial-sync/utils.ts`).

That choice cascades. Linear has real workflow states, estimates, cycles and
derived branch names; GitHub Issues has a title, a body, labels, assignees and
open/closed. **We are targeting the weaker provider, so everything it cannot
represent we have to own** — which is the entire justification for the local
`status` vocabulary and the shadow snapshot, and it is why their `task_statuses`
table has no analogue here.

### What we adopted from it

**1. No link table.** External identity on the task row, with
`unique(organizationId, externalProvider, externalId)` doing all the inbound
idempotency work through a single `onConflictDoUpdate`. Our `TaskLink` bought
multi-tracker linking, which nothing in v1 reads. Adopted, with
`integrationRepoId` added because a GitHub installation spans many repos where a
Linear connection is one workspace.

**2. Assignee as a column pair with a snapshot triple.** `assigneeId` for a
matched member, `assigneeExternalId` / `assigneeDisplayName` / `assigneeAvatarUrl`
for a provider user who is not one, and setting the internal id clears all three
(`packages/trpc/src/router/task/task.ts`, the `"assigneeId" in data` branch). This
works for them because a Linear issue has exactly one assignee. It works for us
only because we also stopped pushing assignees — the storage model is safe to
copy, the write path is not.

**3. `task.start` as a compare-and-set.** Their start mutation is our
`working → in_progress` rule, done properly: it fires only from a `backlog` or
`unstarted` status, picks the started-status from the same provider's status set
the task already lives in, assigns the acting user only when genuinely
unassigned, and writes with the observed `statusId` in the `WHERE` clause so a
concurrent move to completed updates zero rows. Our plan specified the transition
and said nothing about the race.

**4. The dedup key comes from inside the signed envelope.** Their key is
`${connectionId}-${orgId}-${webhookTimestamp}`, and `webhookTimestamp` is part of
the Linear payload the signature covers — so it is not attacker-controlled the
way `X-GitHub-Delivery` is, and it costs nothing to compute. GitHub gives us no
such field, so a hash of the raw signed bytes is the equivalent; the *rule* is
what generalizes. Their `ON CONFLICT DO UPDATE` also re-arms a `failed` row to
`pending` with `retryCount + 1`, which closes the redelivery hole this plan
identified in `webhook_events` and had no answer for.

### What they left open that this plan closes

Not cheap shots — these are the specific places where a shipped implementation
shows what deferring the question costs.

- **No echo suppression exists.** The push job writes to Linear, Linear fires a
  webhook, and the webhook writes the whole payload back with
  `onConflictDoUpdate` (`integrations/linear/webhook/route.ts`). It converges only
  because the echoed value equals the pushed value; a local edit landing between
  the two is overwritten with no record. That is the `t0→t3` trace in Outbound,
  live. Their entire conflict surface is one `syncError` text column.
- **No create idempotency.** `syncTask` publishes to QStash with `retries: 3`, and
  the job creates the Linear issue *before* persisting `externalId`. A retried
  delivery makes a second issue.
- **Nothing serializes two jobs for one task.** Re-reading the task fresh inside
  each job is smarter than replaying a stored diff — it makes ops naturally
  latest-wins without a `seq` column, and is worth considering — but two
  concurrent deliveries still interleave read-then-PATCH.
- **The pushes are floating promises.** `syncTask(...)` is un-awaited and
  un-caught in `create`, `update` and `delete`; only `start` wraps it in
  `void … .catch()`. An unhandled rejection loses the push silently.
- **Status resolution is by name.** Pushing a status change resolves the Linear
  state with a case-insensitive name match, so a renamed state stops accepting
  pushes. Inbound has the mirror-image bug and it is flagged in their own code: a
  workflow state created after the status sync makes the webhook **skip the issue
  entirely** (`TODO(SUPER-237)`), with a comment claiming a periodic sync will
  recover it. There is no periodic sync in the repo — `initial-sync` is triggered
  only from the OAuth callback.
- **The slug churns.** A local slug is generated from the title with a retry
  against a uniqueness constraint, then **overwritten with the Linear identifier**
  on first sync. Every URL to that task breaks at publish. Our `number` is
  allocated once and never rewritten, which is the better trade even though it
  costs an advisory lock.
- **Tokens are plaintext at rest** in `integration_connections.accessToken`. The
  GitHub App decision avoids the equivalent — installation tokens are minted per
  use and expire — worth keeping as an explicit reason for that choice rather
  than an incidental benefit of it.
- **Import has no scope.** The initial sync pulls every issue updated in the last
  three months across every team the token can see; their `newTasksTeamId` config
  governs where *new* tasks go, not what comes in. Our per-repo import filter is
  still an open item, and their experience argues for closing it before the first
  non-dogfood repo rather than after.

### Two of this plan's findings, confirmed in shipped code

- **A task body is untrusted input to an agent.** Their `synthesizeTaskPrompt`
  builds the agent prompt as `${slug}: ${title}\n\n${description}` with no
  delimiter and no provenance label (`apps/desktop/.../OpenInWorkspaceV2`). Any
  Linear issue body, written by anyone in that workspace, becomes an agent prompt
  verbatim. That section was written before this was read; finding it live in a
  shipping product is why it is a section rather than a bullet.
- **Every client-supplied foreign key must be re-resolved under the caller's
  tenant.** `getScopedStatusId`, `getScopedAssigneeId`, `requireOrgResourceAccess`
  and `requireActiveOrgMembership` do exactly that, arrived at independently.

### Scope, for calibration

They ship materially more than this plan's v1 contemplates: six MCP tools
(`tasks_create` / `update` / `get` / `list` / `delete`, `tasks_statuses_list`)
letting the agent manage tasks directly, per-tool chat renderers, a link-task
command-palette entry, Electric SQL shapes filtered by organization at a proxy
feeding a local SQLite mirror for offline reads, and a documented Linear
"custom coding tool" script that opens an issue as a workspace from Linear's side.

Two of those are worth wanting. The **agent-facing tool surface** is the shape
this product should eventually have, and it inherits tenant scoping for free
because the tools call the same procedures the UI does — but every agent-created
task in their system publishes to Linear unconditionally, which is the
actor-identification problem this plan solved with a required `publish` field,
resolved the other way. The **offline mirror** is more infrastructure than v1
justifies, and their local schema has already drifted from the cloud one (a
`repository_id` column exists locally and nowhere in the server schema) — the
maintenance cost of that approach showing up early.

They ship materially less in one place: **no comments, in either direction.** No
comment table exists, and the task detail's activity section renders a single
hardcoded "created the issue" row. `TaskComment` is therefore both a
differentiator and, per Scale and Open items, the largest volume risk in this
plan. Those are the same fact.
