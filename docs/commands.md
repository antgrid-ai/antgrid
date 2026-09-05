# Commands reference

On-demand commands. The everyday ones (setup, launchers, the test/analyze
gates) live in the root `CLAUDE.md`; this file holds the rest so they cost no
context until you need them.

## Occasional dev commands

```bash
# Grant Pro to an OAuth-created user (dev only, idempotent). `npm run setup`
# only seeds dev@antgrid.local; real OAuth sign-ins need this.
bun run scripts/dev-grant.ts <email>

cd web && bun run migrate        # prisma migrate deploy
cd web && bun run generate:key   # Ed25519 signing seed
```

## Worktrees

Only when asked — see the note at the top of the root `CLAUDE.md`.

`scripts/worktree.ts` provisions the gitignored artifacts a bare `git worktree
add` leaves missing (`node_modules`, prisma client, per-service `.env`, Flutter
`.dart_tool`) — use it, not raw git, so the worktree is test-ready. `.env` is
copied from main (run `npm run setup` there first).

```bash
npm run worktree -- <name>   # create .claude/worktrees/<name> + provision
npm run worktree             # provision the CURRENT worktree
# flags: --branch <b> --from <ref> --no-flutter --no-db --seed (--seed ⊥ --no-db)
```

## Read-only helpers (agent quality-of-life)

Both are read-only and replace common multi-command probes; prefer them over
hand-rolling `git rev-parse`/`merge-base`/`ls .env` or per-file `git grep`.

```bash
npm run wt                   # where am I + is this worktree provisioned? (--json)
                             # reports worktree-vs-main, branch, ±commits vs main,
                             # and presence of the provision artifacts worktree.ts copies
npm run sym -- <Symbol>      # locate a symbol across ALL workspaces, defs split from
                             # usages (git grep -w; code only, .md/docs excluded).
                             # flags: --defs  --ts | --dart | --all  --json
```

## Bridge CLI

```bash
cd bridge && bun run dev init    # Generate default antgrid.yaml
```

**Phone management:** `antgrid phones list|remove` (`bridge/src/cli/phones.ts`).
Trust is machine-level (one `<ANTGRID_DIR>/agents/paired-phones.json` —
`resolveAbDir()` in `antgrid-dir.ts`, `~/.antgrid` by default, `~/.antgrid-dev`
for a local dev build; no `<projectId>` segment — see `paired-phones.ts`).

`remove` is **NOT** a revocation: an account-trusted phone re-creates its row on
the next hello, so removal only clears the local record (label, `lastSeenAt`,
push token). Cutting a phone off means turning the machine's remote-access
switch off (all phones) or signing that device out of the account.

The CLI resolves `ANTGRID_DIR` from its own shell env, so it only sees a dev
host's store if that env matches how the host was launched.

**Network watcher:** `antgrid watch` (`bridge/src/cli/netwatch.ts`) streams every
frame crossing the machine relay socket — direction, channel, stream, size, the
plaintext message type, and the drops. It attaches to the *already-running* host
over the loopback control plane (`GET /netwatch`, same bearer token as
`host.json`), so it starts nothing and needs no restart to arm; the host keeps a
bounded ring recording at all times, which is replayed before the live tail.

```bash
antgrid watch                       # rendered table, replay then follow
antgrid watch --json > cap.jsonl    # raw JSONL
antgrid watch --no-follow           # buffered snapshot, then exit
antgrid watch --dir ~/.antgrid-dev  # a debug-build app's host
```

**Both halves.** The app records its own side when `ANTGRID_NETWATCH` is set in
its environment (runtime, so arming it needs no rebuild), to
`<ANTGRID_DIR>/netwatch.log`. `--join` pairs the two on `frameId` — the sealed
frame's AES-GCM nonce, which the relay forwards untouched and both endpoints
therefore compute identically:

```bash
ANTGRID_NETWATCH=1 <launch the app>
antgrid watch --dir ~/.antgrid-dev --join ~/.antgrid-dev/netwatch.log
```

```
22:11:56.211  app  -> tx  ctrl  sealed  412B  a3f9c211  terminal:input  s:9f1c22ab
22:11:56.233  brg  <- rx  ctrl  sealed  412B  a3f9c211  terminal:input  +22ms
22:11:56.240  app  -> tx  ctrl  sealed   88B  cc12ef44  file:read       ✗ never arrived
```

This answers what neither endpoint can alone — the route header carries no
message id, so the relay's `MESSAGE_RATE_LIMITED` tells the sender that
*something* died but never which. A frame is only called lost inside the window
both captures cover: that window runs to *now* (both halves are read live), but
starts wherever the shorter one reaches, because the ring evicts and the file
rotates. Frames from the last second are held back — the app annotates and
batches before writing, so the newest ones are legitimately not on disk yet.

**A phone's half comes back over the socket, not through a file.** `hostDir()`
resolves from `USERPROFILE`/`HOME`, so there is no `netwatch.log` on a phone and
no environment to arm one with. `--remote` asks the connected app directly
(`netwatch:configure`), and its events arrive as `netwatch:events` batches that
land in this host's own ring — so one live stream already carries both halves,
with an origin column instead of a merge:

```bash
antgrid watch --remote          # ⊥ --join: this merges live, --join merges files
```

Four things worth knowing about it. It is **not retrospective** — the app
installs its tap on receipt, so nothing before the command exists on that side
(the desktop's env-armed capture is the retrospective one). The arm carries a
**dead-man TTL** the watcher renews while it runs, because a `SIGKILL`ed watcher
sends no disarm and nothing on the phone can turn a capture off. Timestamps are
**shifted onto this machine's clock** using the batch's own send time; deltas
between two app-side events stay exact, and one-way relay latency is not
subtracted. And the app's uploader **drops rather than queues** past its
per-batch cap and byte budget — a capture that slows the session it is
diagnosing has changed what it was measuring — so the batch carries a `dropped`
count and never a silent gap.

Three things it still does NOT show. Loopback traffic: a co-located app may take
the `LocalListener` path instead (`app/lib/providers/agent_transport.dart` tries
relay first, local second), which speaks plain JSON with no frames and never
touches the relay — every event is tagged `transport` so a capture cannot be
misread as relay traffic it is not. A session that never established: both
halves ride the sealed control plane, so `--remote` can describe a connection
that is misbehaving but structurally cannot describe one that never came up. And
which machine an app-side frame belongs to: the app's recorder is process-wide,
so an app connected to two machines that are BOTH watching reports every frame
to both — same account, same user, and the events carry types and sizes, never
payloads, but the reading is confusing rather than wrong.
