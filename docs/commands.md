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
antgrid watch --ui                  # ...in its own window instead (see below)
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

**Loopback: one side sees the whole wire.** A co-located app may take the
`LocalListener` path instead of the relay (`app/lib/providers/agent_transport.dart`
tries relay first, local second) — plain JSON on 127.0.0.1, no seal, no frames,
no streams. That socket is point-to-point with nothing in between, so
`bridge/src/local-listener.ts` alone is a *complete* capture: every frame
`deliver()` sends is one the app received, and every frame `handleFrame()` sees
is one the app sent. No second half, no `--join`, no app-side arming — the relay
case needs all three only because a router sits between the endpoints and can
swallow a frame neither of them ever hears about.

The one thing the listener structurally cannot see is a frame the app **never
put** on the wire. `LocalTransport` (`packages/antgrid_relay_client`) records
those into the same `ANTGRID_NETWATCH` file its relay half writes: a send into a
torn-down channel, a reply this app could not decode, a port that accepted the
socket and never upgraded it, and the handshake refusals — including the close
code the listener answered with, which is what makes "won't connect" legible
from both ends rather than as an absence of traffic. Drops only, never a
successful frame (the listener already recorded those; a merged capture would
otherwise carry every row twice) and never a body — the app's mirror of the
schema has no body field at all, and the hello this side sends carries the
core's shared token.

```bash
antgrid watch --local     # loopback only
antgrid watch --relay     # relay only — omit both to see every transport
antgrid watch --bodies    # ...and the plaintext of each loopback frame
```

Both transports are recorded either way: `--local`/`--relay` narrow what is
rendered, never what the host keeps, and with neither given the table carries a
transport column. The join key is free here — a loopback frame is a whole
`AbMessage`, so its own `id` (the UUID `createAbMessage` mints) *is* the frameId,
with nothing hashed on the hot path. The relay path's nonce-derived key exists
only because its route header carries no message id. The one id-less loopback
frame that reaches the ring is a refused `hello`, which falls back to
`frameIdFor`'s sha256 prefix.

**Bodies are opt-in, capped, and lapse on their own.** Metadata is recorded
always — an intermittent bug is only diagnosable if the ring was already holding
it by the time someone went looking — but a payload is recorded only while
`--bodies` has armed it over the loopback control plane (`netwatch:local`, same
bearer as `/netwatch`; it arms a flag in this process, sends nothing to the app,
and adds no wire message type). Each body is truncated to
`NETWATCH_BODY_MAX_CHARS` (4 KiB) at the record site rather than at render, so a
screen of build log cannot evict the ring on its way to being shortened. The arm
carries the same **dead-man TTL** `--remote` does, renewed while the watcher runs
and clamped host-side to an hour: the watcher that armed it is the only thing
that ever disarms it, and a `SIGKILL`ed watcher sends no disarm. It therefore
needs a live stream — `--no-follow` and `--join` refuse it, though bodies already
in the ring render under both.

Two things to be blunt about. A body is plaintext — prompts, file contents,
terminal output — so `--bodies --json > cap.jsonl` puts them unencrypted on disk
for that run, and nothing scrubs or rotates the file. And a `hello` is never
captured with its text, armed or not (`recordHelloRefused`): the envelope carries
this core's shared secret in cleartext, so a refusal is recorded as a drop with a
reason, a size and a hashed id, and nothing else.

**A window instead of a table.** `antgrid watch --ui` mints a launch link, opens
it as its own OS window (Chromium's `--app=`, falling back to an ordinary browser
tab) and exits — the window is the session, not this terminal. It reads the same
ring live and adds what a table cannot: a text filter over type, channel, reason,
detail and body; transport chips; drops-only; pause; stick-to-bottom with a jump
pill; click-for-detail with the full body; and both arming switches, each with
its own heartbeat and the same dead-man TTL. **export** writes exactly what is on
screen as JSONL. `--local`/`--relay`/`--limit` set the window's opening state;
every other flag is refused, because the window owns what it would have answered.

```bash
antgrid watch --ui                  # a window, and the terminal is yours again
antgrid watch --ui --local          # ...opening on the loopback transport
antgrid watch --ui --no-open        # print the link instead of launching
```

The link is a credential and is treated as one. `host.json`'s bearer never
reaches the browser — it opens `POST /control`, which starts projects, checks out
branches and discloses host paths — so the URL carries a **single-use ticket** in
its fragment, which no browser sends to a server. The page spends it for a
session token that reaches `GET /netwatch` and the two `netwatch:*` arming verbs
and nothing else, holds it in `sessionStorage` (origin-scoped down to the port,
unlike a cookie) and strips the fragment, so the copy left in browser history is
already spent. Every `/netwatch` route additionally refuses a `Host` this
listener never published and any cross-site fetch, which is what closes DNS
rebinding. The page loads nothing from anywhere, renders every peer-supplied
value through `textContent`, and runs under a nonce CSP whose default is `'none'`.

Two things it still does NOT show. A relay session that never established: both
halves of that capture ride the sealed control plane, so `--remote` can describe
a connection that is misbehaving but structurally cannot describe one that never
came up (a refused loopback hello, by contrast, is an ordinary event). And which
machine an app-side frame belongs to: the app's recorder is process-wide, so an
app connected to two machines that are BOTH watching reports every frame to both
— same account, same user, and the events carry types and sizes, never payloads,
but the reading is confusing rather than wrong.

**Model-call watcher:** `antgrid calls` (`bridge/src/cli/modelwatch.ts`) is the
sibling command, over the same plumbing, watching a different thing: the headless
agent CLIs the bridge spawns on *your own provider accounts*. Three calls exist —
a session title, and the handler's decision and extraction — and all three funnel
through `runHeadless` (`bridge/src/agents/headless.ts`), which is where the
recorder is tapped. It attaches to the already-running host exactly as `watch`
does (`GET /modelwatch`, the `host.json` bearer, a ring that has been recording
since the host started), so the call worth reading about is normally already in
it by the time you attach.

```bash
antgrid calls                        # replay the ring, then follow
antgrid calls --purpose decision     # only the handler's judge calls
antgrid calls --json > calls.jsonl   # the raw records
antgrid calls --no-follow            # buffered snapshot, then exit
antgrid calls --limit 0              # no replay; watch what happens next
```

```
20:40:06.095  9f8e7d6c  title        #1  codex→claude-code  default   3.1s/45.0s   named
20:40:12.480  abc123de  decision     #1  claude-code        default  28.4s/45.0s   shape-rejected  16.6s left for the retry  quote not found in RECENT CONTEXT
20:40:41.220  abc123de  decision    ↳#2  claude-code        default   7.2s/16.6s   retried-parsed
20:41:07.900  deadbeef  extraction   #1  claude-code        default  19.8s/20.0s   timeout         200ms left for the retry — unreachable  no output
```

**A row is an attempt, not a record.** The recorder writes three per attempt —
the spawn starts, the spawn exits with its timings, and the *caller* says what it
made of the answer, which the spawn cannot know — and the rendered view folds
them into one row on the call id they share. `--json` does not fold: it prints
the records as recorded, for a reader piping them somewhere else.

**The retry budget is the number this exists for.** A judge gets two attempts
against ONE budget (`runWithRetry` in `bridge/src/handler/judge.ts`), so what the
first attempt leaves is the whole of what the second gets — which is why the two
rows above share a call id, why the retry is indented under the attempt it
retried, and why attempt #1's leftover is literally attempt #2's budget column. A
first attempt that leaves a few hundred milliseconds has dispatched a retry that
was already dead: no vendor CLI has ever finished in that (each loads twelve to
twenty-three thousand tokens of its own preamble before reading the prompt), so
anything under five seconds is called unreachable on the row and counted in the
closing tally. Nothing else on the machine would ever say so.

The other columns answer questions that are equally unanswerable elsewhere. The
agent **asked for** is shown beside the one that **actually ran** when they differ
(`codex→claude-code`): a title needs no repo access and therefore borrows
whichever agent is installed, which bills a vendor this session never chose. And
`default` in the model column is not a missing value — it is a call that passed no
`--model` at all and so ran on whatever that CLI defaults to on this machine,
which for a three-word naming task is the largest single cost lever there is.

**Prompt text is never recorded unless armed, and the arms are separate.**
Metadata is always in the ring — that is what makes a call diagnosable hours
later — but nothing the user typed and nothing the agent read is, until a run
asks for it:

```bash
antgrid calls --prompts   # the parts WE wrote: scaffold, handler goal,
                          # a count for the backlog, a digest for the transcript
antgrid calls --context   # ...and the transcript and PTY scrollback themselves,
                          # plus the model's answer, which quotes them back
```

`--context` is a second flag rather than a stronger setting of the first because
what it admits is not ours. A decision prompt is built around thousands of
characters of transcript and PTY scrollback, which can hold a pasted key, an
`.env` the agent opened, or a password typed at a prompt — there is no list of
types that could make it safe the way `BODY_REDACTED_MESSAGE_TYPES` makes a frame
body safe, which is the whole reason `bridge/src/modelwatch.ts` gives it its own
switch. It implies `--prompts`: transcript text and the model's answer are
admitted only while both arms are up, so arming it alone would arm the dangerous
capture and record nothing through it. For the same reason the capture viewer may
arm the prompt parts and may **not** arm the context arm — it is refused at that
route with `CONTEXT_ARM_FORBIDDEN` and is reachable only from this CLI.

Both arms carry the **dead-man TTL** `--bodies` does, renewed while the watcher
runs and clamped host-side, and both need a live stream (`--no-follow` refuses
them, since arming records the future). The two ceilings differ, because what the
arms admit does: `prompts` may be held for up to an hour, `context` for five
minutes. A run renews well inside either, so the shorter one costs a live watcher
nothing — what it bounds is the run that is no longer there. One thing these arms
do that netwatch's does not: a disarm — on exit, on `Ctrl-C`, or when the window
simply lapses — **purges the text already in the ring**. That ring is sized to
hold days rather than seconds, so without the purge an excerpt admitted during a
one-minute window would still be readable a week later by a reader who armed
nothing.

**Nothing leaves the machine.** `modelwatch:arm` and `modelwatch:ui` are
`ControlRequest` verbs answered in this process on the loopback plane; they add no
AbMessage type, so a phone — which speaks AbMessage over the relay and cannot name
a `ControlRequest` at all — has no way to reach either. There is no outbound
direction and no `--remote` analogue, by construction rather than by omission. The
durable feed the recorder also writes (`<ANTGRID_DIR>/model-calls.jsonl`, machine
level, one rolled generation) holds metadata only, always, armed or not, and
`--export` writes the same — literally the same field list, `MODEL_CALL_LOG_FIELDS`
in `bridge/src/modelwatch-log.ts`, so the two cannot drift apart as fields are
added. An export file is written to be pasted into a bug report, and it outlives
the run, the window and the arm's own TTL. `--json` is the mode that withholds
nothing: it goes to a pipe the operator is watching, not to a file they attach to
a ticket a week later.
