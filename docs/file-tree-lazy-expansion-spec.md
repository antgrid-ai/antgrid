# On-demand file tree + `file:find` — implementer spec

Status: built, then amended. Code wins where this and the tree disagree.

**Amendment (supersedes D1 and one non-goal).** The whole-tree PULL is gone
too. `file:tree:snapshot:request` / `file:tree:snapshot`, `FileWatcher.getTreeSnapshot`,
`buildTree`/`walk` and the `MAX_TREE_NODES` / `MAX_DEPTH` budgets are all
removed, so an app predating this protocol now gets no tree rather than a large
one. Everywhere below that says the verb "keeps meaning the whole tree forever"
is superseded. `file:tree:unchanged` survives — the lazy
`file:tree:root:request` answers with it on a matching `sinceSeq`. `tree:full`
also survives, schema-only: it guards the OPPOSITE skew (a new app against an
OLD bridge that still replays a per-checkout full tree), so it retires with
`pullsTree`, separately.

Anchors below name files and symbols, never line numbers — grep the symbol.

Replaces the whole-checkout file tree with per-directory listings fetched when
a folder opens, and adds a bridge-side path search (`file:find`) to carry the
two features that today read the synced tree directly. The tree shows
everything on disk by default, including git-ignored files; `file:find` does
not. Ignored content is listed on demand and refreshed manually — it is never
live-watched (D14).

## Why

Three costs, all measured, all from the same root cause — the app holds the
entire checkout as one object:

1. **Snapshot size.** `buildTree` walks everything under `MAX_TREE_NODES`
   (10k). This worktree is 2,527 nodes with ignores on and **48,037 with them
   off**, before any `node_modules` exists. Showing ignored files is impossible
   at whole-tree granularity — it is 5x past the budget on a clean tree.
2. **Delta volume.** The comment on `IDLE_WINDOW_MS` in `file-watcher.ts`
   records the real number: one 245 s agent run put **2.76 MB of `tree:update`
   on the wire, 22% of that session's entire download**. Lazy expansion alone
   does not touch this; only D6 does.
3. **Merge cost.** `_mergeTreeUpdate` deep-clones the whole tree via `_cloneNode`
   on every delta, at up to 6 Hz, on the UI thread (`file_service.dart`).

## Non-goals

- Live updates for git-ignored content. See D8 and D14 — the watcher prune
  stays absolute and ignored files refresh on demand.
- Removing the `pullsTree` capability or the `tree:full` schema. The push path
  dies (see Removals) but the flag stays parsed-and-ignored for one release.
- Fuzzy-search ranking quality beyond "good enough for @-mentions".

---

## Decisions

**D1 — New verbs are self-identifying; no new capability key.**
`file:tree:snapshot:request` keeps meaning "the whole tree" forever. A lazy app
sends `file:tree:root:request` and `file:tree:children:request` instead, so
receiving one *is* the capability signal. This deliberately avoids adding to
`AppReadyMessage.capabilities` in `protocol.ts`, whose own comment warns that
*"Neither live reader parses `app:ready` through Zod … Adding a key here does
not make the bridge honour it; the reads are hand-written on both transports"* —
i.e. a new key must be hand-mirrored into `relay-client.ts` **and**
`local-listener.ts` **and** both app hello literals, and for `pullsTree` the
fail direction was silent. A new verb has no silent direction: an old bridge
answers `stream-invalid`, an old app never sends it.

**D2 — Listings are depth-1, and every expand re-lists.** A children request
returns one directory's immediate entries. No prefetch of grandchildren: it
doubles traffic to save a round trip the user does not perceive (the folder they
open is the one they asked for).

**There is no cross-expand cache.** Opening a directory always hits the disk,
whether or not the app already holds children for it, and whether or not those
children are ignored. A depth-1 `readdirSync` is sub-millisecond work, and a
directory the user just opened is precisely the one where being wrong is most
visible. This also means correctness does not depend on the delta stream having
been perfect while the folder was shut — every open is a fresh read, so a missed
delta self-heals at the next expand.

Collapse clears `childrenLoaded`. The previous children stay in the node and
remain on screen during the next expand's round trip (no flash of empty), but
they are stale-by-definition and are replaced when the listing lands.

**D3 — Requests are batched by path list, capped at 64.** Restoring
`PreferencesModel.expandedPaths` (reapplied in `FileService._applyPreferences`)
would otherwise fan out to one round trip per remembered folder at every project
open. A caller with more than 64 paths chunks — see D5.

**D4 — The global `seq` stays and gains a second job.** `ConnState.fileSeq`
remains one counter per checkout. It still answers "nothing anywhere changed,
everything you hold is current" in one round trip (`file:tree:unchanged`), and
it is also the staleness input for the `file:find` cache (D12). Per-directory
revisions are not worth their bookkeeping.

**D5 — A forced resync becomes an invalidation, not a tree.** The
null-filename overflow branch in `FileWatcher.handleNativeEvent` currently
answers with `sendFullTree({force: true})`. It sends
`file:tree:invalidated { seq }` instead. The app then clears `childrenLoaded`
everywhere and refetches the root plus its subscribed set **in chunks of at most
64 paths** (D3), deepest-first so the visible rows fill before the folded ones.
Requests are issued concurrently; the app applies each `file:tree:children` as
it lands.

**D6 — The expanded set is a subscription, and the delta filter is a union.**
The app tells the bridge which directories it has open; `flushBatch` filters
`added`/`modified`/`removed` to `dirname(path) ∈ subscribed ∪ {""}`. Because the
bus broadcasts, the filter is the **union across attached clients**, and a client
that has sent no subscription is treated as subscribed to everything — the same
fail-open shape as `everyClientPullsTrees()` in `agent-core.ts`, for the same
reason: a second device on the same bus must not go treeless.

The rule is closed under removal: you cannot subscribe to a directory without
its parent, so a subscribed directory's own removal has a subscribed `dirname`.

**D7 — Without D6 the change is cosmetic.** Waves 1–3 ship with unfiltered
deltas and the app dropping those for unloaded directories. That is correct but
keeps cost 2 above. D6 is where the bandwidth actually falls; do not declare the
project done before it.

**D8 — Watch-ignores and display-ignores are separate rule sets.** `IgnoreRules`
is used in three places: the tree walk (`walk` in `file-tree.ts`), chokidar's
`ignored` predicate, and the native recursive prune in
`FileWatcher.handleNativeEvent`. On Windows and macOS the OS hands over the
*entire* subtree (the comment above `startNativeRecursiveWatch` explains why it
cannot prune at the subscription level), so the JS prune is the only thing
standing between a `bun install` and the event stream. The display rules relax
(D10); **the watch prune never does** — see D14.

**Rejected: watching only the root and the expanded folders.** The natural
optimisation once D6 exists, and wrong, because the watcher is not the tree's
watcher — `onFilesChanged` also drives `scheduleGitRefresh`, which both triggers
the debounced `git status` *and* resets the git poll cadence. Its comment is
explicit: a checkout the watcher is firing on is under active work and must
never drift into a slow tier while a build writes into it. Narrow the watch and
an edit inside a collapsed folder produces no event, so the Changes list waits
for the backstop poll while the cadence ladders down — `GIT_POLL_TIERS` against
the 10 s base means main caps at 30 s and an isolated worktree at 120 s. A
two-minute-stale Changes list during an agent run is not worth what scoping
saves.

What it saves is also less than it looks. On Windows and macOS the recursive
`fs.watch` is a *single* OS subscription whatever the tree's size, so scoping
buys nothing there in principle and costs the per-directory storm that
`startWatching`'s comment measures at ~10.9 s. Only Linux would genuinely gain
(chokidar attaches one watch per non-ignored directory, against an inotify
`max_user_watches` that is user-wide and shared across worktrees) — and it loses
git coverage the same way. Scope delivery (D6), never the subscription.

**D9 — `.git`, `.antgrid` and config excludes are a floor under every flag.**
They are in `DEFAULT_IGNORES` in `file-tree.ts`, not in anyone's `.gitignore`.
`.antgrid` holds staged uploads the tree is documented to hide. `antgrid.yaml`
excludes are the user's own statement about their project, not a git artifact.
"Show everything" means *git's* ignore rules are off, nothing else.

**D10 — The two surfaces deliberately differ, and each caller states its own
default.** There is no single global toggle.

| surface | `includeIgnored` | why |
|---|---|---|
| file tree (root + children) | **true** | browsing: you want to see `dist/`, `build/`, `.dart_tool/` |
| `file:find` for @-mentions | **false** | you are handing a path to an agent; `node_modules` is noise |
| `file:find` for the tree's filter box | **true** | it filters the tree, so it must agree with the tree |

A user setting may override the tree's default for people who want the old
behaviour; it does not reach `file:find`'s mention path, which is always
ignore-respecting. The asymmetry is the product decision, not an oversight —
call it out in any code comment that reads as inconsistent.

**D11 — `file:find` gets its own frame pair, not the generic RPC.** The
`request`/`response` schema in `protocol.ts` carries no `checkoutId`, and path
search is filesystem-variable.

**D12 — `file:find` caches its path list per `(checkoutId, includeIgnored)`
under a minimum TTL, not on `seq` alone.** @-mention autocomplete fires per
keystroke, and `bumpFileSeq` fires on every watcher flush (100–750 ms) — so a
seq-only cache is cold on nearly every keystroke during an agent run, which is
exactly when mentions are used. Re-list when `seq` has moved **and**
`FIND_CACHE_MIN_TTL_MS` (2 s) has elapsed since the last list; serve the
slightly stale list otherwise. A path list that is two seconds old is a correct
answer to "what can I mention".

**D13 — `file:find` needs a third engine, and it must not block the thread.**
`detectEngine()` in `file-search.ts` throws when neither `rg` nor `git` exists,
and `file:search` reports that as an error. Acceptable for content search; not
for `file:find`, which after this is the *only* thing backing @-mentions and the
filter box. A `readdirSync` walk fallback keeps them working — **chunked with
`yieldToEventLoop`**, because an unignored walk is 48k–300k stats and a
synchronous one reproduces the ~10.9 s block documented above
`FileWatcher.startWatching`, the one that made the app reap a healthy host
mid-open.

**D14 — Ignored content is refresh-on-demand, never live.** The watcher drops
ignored events before any bookkeeping, and that prune stays absolute (D8). So a
git-ignored file the tree is showing does not update when it changes, appear
when created, or vanish when deleted, until the user asks for a fresh listing.

This is a deliberate trade, not an oversight. Watching ignored paths would put
every `bun install`, every build and every `.dart_tool` rewrite back on the
event stream — the exact storm D8 exists to prevent — to keep a row current
that nobody is reading while it churns. Manual refresh costs one gesture on the
rare occasion it matters.

Three consequences the implementation owes:

1. **The refresh gesture already exists, for free.** D2 re-lists on every
   expand, so collapse-then-expand *is* the per-directory refresh — no new
   affordance, and no special case for ignored directories. Whole-tree
   pull-to-refresh (`requestFullTree`) re-lists everything as it does today.
2. **The app must still know which entries are ignored.** `FileTreeNodeSchema`
   gains `ignored?: true` (see the wire contract), set by the bridge for any
   entry present only because `includeIgnored` was true.
3. **Ignored rows render dimmed**, the way VS Code marks them. This is now the
   whole job of the `ignored` flag: a dimmed row reads as "not part of the
   project, and not live" without a tooltip. An expanded ignored directory's
   *contents* are as fresh as any other — they were read on expand — but
   nothing arriving afterwards will change them until the next open.

**D15 — `file:find` derives directories; it cannot list them.** Verified in this
repo: `rg --files` and `git ls-files` both emit files only. Today's
`flattenFileTree` emits `isDir`, so @-mentions can currently mention a folder,
and that must not regress. Derive the directory set from the path prefixes of
the returned files. Consequence to state in the UI copy or accept knowingly:
**an empty directory is invisible to `file:find`** (two exist in this checkout).
`kinds: "dirs"` with a query that would only match an empty directory returns
nothing; the tree still shows it.

---

## Wire contract

All frames are `...CheckoutScoped`. Every one of the six goes through the full
checklist below.

```ts
// ── Listings ──────────────────────────────────────────────────────────────
const FileTreeRootRequestMessage = BaseMessage.extend({
  type: z.literal("file:tree:root:request"),
  /** Same contract as file:tree:snapshot:request's — only a caller that can
   *  vouch the seq came from THIS agent process may send it. */
  sinceSeq: z.number().int().nonnegative().optional(),
  /** Defaults TRUE here and FALSE on file:find — see D10. The asymmetry is
   *  intentional: the tree browses, find feeds an agent. */
  includeIgnored: z.boolean().default(true),
  ...CheckoutScoped,
});

const FileTreeChildrenRequestMessage = BaseMessage.extend({
  type: z.literal("file:tree:children:request"),
  /** Checkout-relative, `/`-separated. "" is the root. Max 64 per request;
   *  a caller with more chunks (D5). */
  paths: z.array(z.string()).min(1).max(64),
  includeIgnored: z.boolean().default(true),
  ...CheckoutScoped,
});

// FileTreeNodeSchema (existing) gains ONE optional field:
//   ignored: z.literal(true).optional()
// Set when the entry is present only because includeIgnored was true. The app
// dims the row with it (D14) — a visual signal that the entry is outside the
// project and receives no live updates.

const DirectoryListingSchema = z.object({
  path: z.string(),
  children: z.array(FileTreeNodeSchema),
  /** Cut at the per-listing cap or the batch budget — `children` is an
   *  ordered prefix. See MAX_LISTING_ENTRIES / MAX_BATCH_NODES. */
  truncated: z.literal(true).optional(),
  /** The directory no longer exists, or resolved outside the checkout.
   *  Distinguished from an empty directory, which the app must render as
   *  empty rather than as still-loading. */
  missing: z.literal(true).optional(),
});

const FileTreeChildrenMessage = BaseMessage.extend({
  type: z.literal("file:tree:children"),
  listings: z.array(DirectoryListingSchema),
  seq: z.number().int().nonnegative(),
  ...CheckoutScoped,
});

const FileTreeInvalidatedMessage = BaseMessage.extend({
  type: z.literal("file:tree:invalidated"),
  seq: z.number().int().nonnegative(),
  ...CheckoutScoped,
});

const FileTreeSubscribeMessage = BaseMessage.extend({
  type: z.literal("file:tree:subscribe"),
  /** REPLACES the sender's whole set — idempotent, so the reconnect hydrator
   *  just re-sends it. Empty array unsubscribes. Purely a delta-bandwidth
   *  hint (D6) — it does NOT influence what the watcher watches (D14). */
  paths: z.array(z.string()).max(512),
  ...CheckoutScoped,
});

// ── Path search ───────────────────────────────────────────────────────────
const FileFindMessage = BaseMessage.extend({
  type: z.literal("file:find"),
  projectId: z.string(),
  requestId: z.string(),
  query: z.string().max(256),
  /** FALSE by default — the opposite of the tree's frames. See D10. */
  includeIgnored: z.boolean().default(false),
  /** Directories are DERIVED from file path prefixes (D15); empty ones are
   *  not visible to find at all. */
  kinds: z.enum(["files", "dirs", "both"]).default("both"),
  limit: z.number().int().positive().max(500).default(100),
  ...CheckoutScoped,
});

const FileFindResultMessage = BaseMessage.extend({
  type: z.literal("file:find-result"),
  projectId: z.string(),
  requestId: z.string(),
  entries: z.array(z.object({ path: z.string(), isDir: z.boolean() })),
  /** The scan hit its cap — `entries` is the best-scoring prefix. */
  truncated: z.boolean(),
  engine: z.enum(["ripgrep", "git-ls-files", "walk"]),
  error: z.string().optional(),
  ...CheckoutScoped,
});
```

No `file:find-cancel`: supersede by `requestId`, killing the previous process
the way `FileSearcher.search` does, and let the app drop replies for a
`requestId` it no longer wants.

### Registration checklist (per CLAUDE.md, all six frames)

1. schema in `protocol.ts`
2. add to `AbMessageSchema` union
3. add to `KNOWN_TYPES`
4. export the type
5. handle in `handleAbMessage`'s switch (`agent-core.ts`)
6. add to `CHECKOUT_VARIABLE_MESSAGE_TYPES` — all six read or address a working
   tree
7. hand-mirror into `kCheckoutVariableMessageTypes`
   (`project_message_classification.dart`)
8. app-inbound frames (`file:tree:children`, `file:tree:invalidated`,
   `file:find-result`) go in `_heavyTypes`; app-outbound requests go in
   `kUnroutedInboundTypes` beside `file:tree:snapshot:request`
9. **none** go in `REPLAY_TYPES` — a listing is a one-shot answer, not durable
   state
10. add each to `serviceWireTypes['FileService']` in
    `app/test/project/classification_completeness_test.dart`

---

## Bridge

### `file-tree.ts`

```ts
export const MAX_LISTING_ENTRIES = 2_000;   // one directory's entries
export const MAX_BATCH_NODES     = 10_000;  // one children response, all listings
```

**Batch budget allocation (was unspecified):** a 64-path request could ask for
128k entries against a 10k budget. Allocate **fair-share first, remainder by
need**: give each listing `floor(MAX_BATCH_NODES / paths.length)`, let listings
that need less return their surplus, then distribute the surplus in request
order. Any listing cut this way carries `truncated: true`. This keeps one huge
directory from starving the other 63, which first-come would do.

- New `listDirectory(absPath, projectRoot, rules, opts): DirectoryListing`.
  Depth-1: `readdirSync`, `lstatSync` each entry, skip symlinks (keep `walk`'s
  `isSymbolicLink()` refusal), apply rules, sort directories-first then
  `localeCompare`, cut at the allocated budget.
- Path guard: resolve `relPath` against the root and confirm containment, using
  the **case-folded** comparison `FileWatcher.handleResolvePathRequest`
  documents (a `file:///c:/…` path against a `C:\…` root otherwise reads as
  outside). Reject, do not clamp. A rejected path answers `missing: true`.
- `loadIgnoreRules(root, excludes, { gitignore: boolean })`. With
  `gitignore: false`, skip the root and nested `.gitignore` reads and keep
  `DEFAULT_IGNORES` + config excludes (D9). Cache both variants per checkout —
  the nested-gitignore `Map` inside `IgnoreRules` is worth keeping warm.
- `MAX_DEPTH` and the tree-wide `budget: { left }` threading are deleted (see
  Removals), along with the `depth === MAX_DEPTH` truncation probe.

### `file-watcher.ts`

- `getRootListing()` / `getChildListings(paths, includeIgnored)` replace
  `getTreeSnapshot()`; `sendFullTree()` is deleted.
- Subscriptions: `setSubscription(clientKey, paths)`, `dropSubscription(clientKey)`,
  `isSubscribed(dirPath)`. `clientKey` is the peer id from
  `establishedPeersProvider` or a sentinel for the loopback owner. Drop on peer
  disconnect **and** on checkout teardown, or the union never shrinks.
- `flushBatch` filters by `dirname(path) ∈ union ∪ {""}` when every attached
  client has a subscription, and sends everything otherwise (D6). Count the
  dropped entries and log the count — a silently over-filtering tree is the
  failure mode that looks like "the watcher stopped working".
- The overflow branch sends `file:tree:invalidated` (D5).
- **Unchanged, and deliberately so:** the churn-widening window, the
  `suppressed` gate and seq counting through it, `needsFullResync` deferral, and
  **both ignore filters, unconditionally** — the watcher never learns about
  `includeIgnored` at all (D14). Nothing in this wave touches
  `handleNativeEvent`'s prune or chokidar's `ignored` predicate.

### `agent-core.ts`

- Five new cases in `handleAbMessage`, modelled on the
  `file:tree:snapshot:request` case, including its comment's warning: answer
  only the checkout that asked, because `runtimeFor` falls back to `mainRuntime`
  and `sendFromRuntime` restamps the reply with the resolved id — so a fallback
  answer is filtered out by the requester and force-pushes main's picture to
  everyone else.
- `file:tree:root:request` keeps the `sinceSeq` → `file:tree:unchanged`
  short-circuit and the unconditional forced git-status re-emit that follows it
  — an unchanged tree says nothing about the decorations drawn on it.
- Delete the resync re-push block and both `sendFullTree({ replayOnly: true })`
  calls.

### `file-find.ts` (new)

Engine selection extends `file-search.ts`'s `detectEngine`, adding the `walk`
fallback (D13). `includeIgnored` maps as:

| engine | `false` | `true` |
|---|---|---|
| ripgrep | `rg --files` | `rg --files --no-ignore --hidden` |
| git | `git ls-files --cached --others --exclude-standard` | `git ls-files --cached --others` |
| walk | `IgnoreRules` with gitignore | `IgnoreRules` without |

`--no-ignore`, not `--no-ignore-vcs`: the latter leaves `.ignore`/`.rgignore` in
force, which is a different and surprising answer. `--hidden` must accompany it
or dotfiles stay invisible and the flag looks broken. (`git ls-files -o` without
`--exclude-standard` does recurse into ignored directories — verified.)

**Floor, applied on every call regardless of the flag (D9):** `--glob '!/.git/**'`,
the Antgrid state dir, and each config exclude — reusing `containedExcludes`
(which explains why a worktree-rooted searcher must drop an exclude anchored
above it), `escapeGlob`, and the leading-`/` anchor (without which `!state/`
also hides a `sub/state/` the project owns). Do not pass `-L`; symlinks stay
unfollowed, matching `walk`'s refusal.

Directory entries are derived per D15. Matching is in JS over the cached list:
subsequence match, prefer basename hits, prefer shallower paths, bounded top-N.
Do **not** push the query into `rg --glob` — it loses fuzzy matching, which is
the whole point.

Guards: `MAX_SCANNED` line budget then `truncated: true`; a timeout mirroring
`file-search.ts`'s `TIMEOUT_MS`; kill-previous-on-new-request; the D12 cache.

---

## App

### `file_tree_models.dart`

`FileNode` gains two fields, and **every rebuild must carry them** — the same
hazard the `truncated` doc comment already names:

```dart
/// Directories only. False means [children] is not the directory's contents —
/// it has not been fetched. Distinct from a fetched-and-empty directory, which
/// is `childrenLoaded: true` with an empty list.
final bool childrenLoaded;
final bool childrenLoading;
```

### `file_service.dart`

- Replace whole-tree merge with a **spine copy**: `_updateAt(root, dirPath, fn)`
  copies only the nodes along `dirPath` and reuses every other subtree. O(depth),
  not O(n). This is what deletes the 6 Hz full clone.
- **A delta into a truncated directory forces a re-list, not an insert.**
  `children` is documented as an ordered prefix; inserting into it silently
  makes it not one.
- `toggleExpanded` becomes async: **every** expand sets `childrenLoading` and
  sends a children request — there is no cache-hit branch (D2). Existing
  children stay on screen during the round trip; a directory with none renders a
  loading row. Collapse clears `childrenLoaded` and updates the subscription;
  expand updates it too (D6).
- **Supersede in-flight requests per directory.** Fast collapse/expand toggling
  puts two listings for the same path in flight, and they can land out of order
  — the older one then overwrites the newer. Key pending listings by path and
  drop a reply that is not the newest request for it.
- `revealDirectory` and `_expandedWithAncestorsOf` must now *await* each level —
  they back OSC 8 terminal link routing, which otherwise reveals nothing.
- `_pullTree` sends `file:tree:root:request` + chunked children requests for the
  subscribed set; the `_claimableSeq`/`_rememberSeq`/`_snapshotEpoch` machinery
  is unchanged and still correct.
- Subscription re-send on reconnect rides the existing hydrator under a new key
  `_subscriptionHydratorKey = 'file:tree:sub'`, registered alongside
  `_treeHydratorKey` in `setTreeInterest` and torn down with it.
- On `file:tree:invalidated`: clear `childrenLoaded` everywhere, refetch per D5.
- `requestFullTree()` must stop resetting `expandedPaths: {}` — harmless today,
  but after this it discards every loaded directory and forces a refetch of
  everything the user had open.
- New `find(query, {includeIgnored})` using the existing `PendingReply` pattern
  (`_pendingResolves`), debounced per keystroke.

### Widgets

- `file_tree_view.dart`: a loading row beside `_TruncationRow`; `_flattenFiltered`
  is deleted and the filter box repointed at `file:find` with
  `includeIgnored: true` (D10). Rows carrying `ignored` render dimmed — the
  design-system muted foreground token, not a hand-rolled opacity.
- `agent_transcript_view.dart`: `flattenFileTree(root)` is deleted; @-mentions
  call `file:find` with `includeIgnored: false` (D10).
- Settings: an optional "Hide git-ignored files" override for the tree only,
  defaulting to off (i.e. tree shows everything).

---

## Removals

**Dies:** `FileWatcher.sendFullTree`; `everyClientPullsTrees` + the resync push
block; both `replayOnly` calls; the retain chain — `MessageBus.retain`,
`retainAb`, `retainFromRuntime`, and the `opts?.replayOnly` branch in **both**
FileWatcher send hooks (main and per-checkout); `"tree:full"` from `REPLAY_TYPES`
and `kCheckoutDurableReplayTypes`; the `exclude: ['tree:full']` machinery in all
three Dart clients (`local_transport.dart`, `machine_session.dart`, the eval
client's `commands.dart`); `_mergeTreeUpdate`/`_cloneNode`/`_removeNode`/
`_insertAtPath`/`_insertChildInto`/`_handleTreeFull`; the tree-wide budget and
`MAX_DEPTH`; `_flattenFiltered`; `flattenFileTree`.

Two tests in `bridge/tests/message-bus.test.ts` exercise `retain` and go with it.

> **Name collision.** `tunnel-manager.ts` has its own unrelated
> `this.retain(requestId, st)` at four call sites. A grep-driven deletion will
> hit it. It is not part of this change.

**Survives despite looking dead:** the watcher's ignore prune, unconditionally
(D14); `DEFAULT_IGNORES`; the churn window; `needsFullResync`; the
seq/epoch/`file:tree:unchanged` machinery; `truncated`; the symlink refusal and
traversal guard.

**Deferred:** `pullsTree` stays parsed-and-ignored for one release. Removing it
with a new bridge against an old app leaves that app treeless with no error.

---

## Waves

Each wave gates and commits itself (`bun run --filter antgrid-bridge test`,
`cd app && flutter test -j 2`, then `flutter analyze` once, never concurrently).

| # | Content | Gate |
|---|---|---|
| 1 | `listDirectory`, path guard, batch allocation, ignore-variant loading, the four listing frames + registration | `file-tree.test.ts`, `checkout-mirror-contract.test.ts` |
| 2 | App: `childrenLoaded`, spine copy, always-fresh async expand + per-path supersede, chunked restore, loading row, truncated re-list | `flutter test`, `classification_completeness_test.dart` |
| 3 | `file-find.ts` + frames + D15 derivation + D12 cache; repoint @-mentions (ignore-respecting) and the filter box (show-all) | new `bridge/tests/file-find.test.ts` |
| 4 | Subscriptions + delta filter (D6) — **the wave that pays** | new `bridge/tests/tree-subscription.test.ts` |
| 5 | The `ignored` node flag, dimmed rows, the tree's show-all default and its override | both suites |
| 6 | Removals + `tree:full` push teardown | full sweep, then one eval run |

Waves 1–2 are the user-visible feature. 3 is the regression you would otherwise
ship. 4 is the performance payoff. 5 makes the show-all default honest. 6 is the
cleanup that cannot land earlier without breaking old apps mid-series.

---

## Tests each wave must add

**Wave 1** — listing a directory returns only its immediate entries; symlink
entries are omitted; a path escaping the root answers `missing`, case-folded on
Windows; a deleted directory answers `missing`, an empty one answers
`childrenLoaded` with `[]`; a 64-path batch over budget allocates fair-share and
marks the cut listings `truncated`; `includeIgnored` true/false differ exactly
by the gitignored set and never by `.git`/`.antgrid`/config excludes.

**Wave 2** — a rebuilt `FileNode` preserves `childrenLoaded`/`childrenLoading`/
`truncated`/`ignored`; `_updateAt` leaves untouched subtrees identical by
reference; a delta into an unloaded directory is dropped; a delta into a
truncated directory triggers a re-list; restoring 100 expanded paths issues two
requests, not 100; **collapse-then-expand always issues a fresh request even
though children are already held** (D2); two rapid expands of one path land out
of order and the older reply is discarded.

**Wave 3** — `kinds: "dirs"` returns derived directories and an empty directory
is absent (D15); `--no-ignore` results include a gitignored file and exclude
`.git`; the cache serves a stale list inside `FIND_CACHE_MIN_TTL_MS` and
re-lists after it; a superseding `requestId` kills the prior process; the `walk`
engine yields to the event loop.

**Wave 4** — union across two clients; a client with no subscription forces
unfiltered delivery; `dropSubscription` on disconnect shrinks the union; a
subscribed directory's own removal survives the filter.

**Wave 5** — a gitignored entry comes back with `ignored: true` and a tracked
one without it; an ignored file created on disk produces **no** delta (the prune
is unconditional); a file created inside an expanded ignored directory is absent
until that directory is re-expanded, and present after.

---

## Traps (these compile clean and are wrong)

1. **Rebuilding a `FileNode` without `childrenLoaded`.** Silently re-marks a
   loaded directory as unloaded, or an unloaded one as empty. Same class as the
   `truncated` hazard already documented on that field.
2. **`rg --files --no-ignore --hidden` walks `.git/`.** Tens of thousands of
   objects. The `!/.git/**` glob is not optional (D9), and the `/**` is
   load-bearing: a bare `!/.git/` is a silent no-op on ripgrep 14.
3. **Subscription set that never shrinks.** Forget `dropSubscription` on peer
   disconnect or checkout teardown and the union is permanently everything —
   the filter appears to work and saves nothing.
4. **Filtering deltas while an old app is attached.** It never sent a
   subscription; it must be treated as subscribed to everything, or its tree
   silently stops updating (D6).
5. **`missing: true` vs an empty directory.** Collapsing them leaves a deleted
   folder spinning forever.
6. **"The tree shows ignored files, so the watcher should watch them."** D8/D14.
   This is the one that takes the bridge down under `bun install`, and the
   show-all default makes it a tempting inference. Ignored content is
   refresh-on-demand by design; the fix for a stale row is a re-list, never a
   watch.
7. **Answering a children request from `mainRuntime`'s fallback.** The
   requester filters the reply out by checkout id and every *other* client gets
   main's listing force-pushed.
8. **`--no-ignore-vcs` instead of `--no-ignore`.** Leaves `.ignore`/`.rgignore`
   in force; the flag half-works, which is harder to diagnose than not working.
9. **Assuming `rg --files` lists directories.** It does not, and neither does
   `git ls-files` — verified. Deriving them is the whole of D15.
10. **Adding a cache-hit branch to expand.** `if (childrenLoaded) return;` is
    the single most natural optimisation to reach for here, it compiles, it
    looks obviously right, and it removes the only refresh gesture the tree has
    (D2/D14). Ignored directories then never update at all.
11. **Out-of-order listings for one path.** Every expand now issues a request,
    so toggling a folder twice puts two in flight; the older reply overwriting
    the newer looks like "the tree shows the wrong contents sometimes".
