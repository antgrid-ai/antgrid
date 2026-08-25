# Bridge (`bridge/src/`)

Deep reference for the bridge. Root `CLAUDE.md` holds the repo-wide gotchas,
commands, and conventions — this file loads only when working under `bridge/`.

## Adding an agent

**`src/agents/registry.ts` is the single entry point.** Add the key to
`AgentKey` (`src/agents/types.ts`) and the compiler names every required field
the new record is missing — a forgotten one is a build error, not a session that
quietly lacks the feature. `AgentSpec`'s optional fields are capabilities;
absence is the honest answer, never a default. Every per-agent module under
`src/` lives in `src/agents/<key>/`: `hooks.ts` for a hook agent, `driver.ts`
and the `chat-backend.ts` / `mapping.ts` / `spawn.ts` it wires for a chat agent,
`title.ts` for one whose session name is read off disk. One thing lives outside
it on purpose: the installed-side integration assets in `bridge/plugin/<agent>/`
(the materialized hook scripts, and opencode's plugin, which runs inside
opencode's own Bun runtime — this is why `hooks.posts` is declared rather than
derived from `toPosts`). Nothing in `app/` changes: `BY_HOOK_NAME`, the tools advertisement, `isChatCapableTool`,
`handlerObservable`, and the judge / transcript / title dispatch all derive from
that one table.

The `agent:tools` advert (and the loopback `tools:list` reply) carries TWO
arrays, and the split is load-bearing. `tools[]` is the PATH probe — what this
machine can actually launch. `agents[]` (`agent-catalog.ts`, projected from the
whole registry) is what each agent IS: label, `chatCapable`, `judgeCapable`, and
`handler.{terminal,chat}` from `handlerObservable`. The app needs the second for
questions the probe structurally cannot answer — naming a cached session row
from a machine that never probed, or offering a judge the current target lacks —
so a new agent is named and capability-described in the app with no app release.
Widening `tools[]` instead was rejected: an app predating the change would read
every row as installed. `agents[]` is optional on the wire so an older bridge
still parses, and each row is total so a bridge that sends the array has
answered all of it.

`handlerObservable` has a SECOND reader, and the two are not interchangeable.
`agents[].handler` describes an agent, so it is the only answer available before
anything is armed; each `handler:status` session snapshot carries
`observability` (`full` | `escalate_only` | `unsupported`, from
`HandlerEngine.observabilityFor`), which describes a SESSION — its live mode and
its judge pick included — and is re-derived on every emit. It is optional on the
wire for an older app, so its absence is "not reported", never `unsupported`.
Keep `escalate_only` (watched, no headless judge) distinct from `unsupported`
(nothing reaches the engine at all): collapsing them is what made an unwatchable
arm look like an armed-and-quiet one.

A `HookProfile` declares two things beyond its `inject`/`events`/`toPosts`, and
both are REQUIRED so a new profile cannot leave them unstated:
- `posts` — every loopback path the agent's INSTALLED integration can reach,
  including one that posts from inside the agent's own runtime rather than
  through `bridge hook` (opencode). It is what answers "can an armed Handler
  ever hear from this agent's terminal sessions" (`/handler-event`) and "does it
  probe the hook channel at startup" (`/hook-alive`), so it is deliberately not
  derivable from `events`.
- `turnBoundaryEvents` — `{start, end}`, the boundaries this agent's events
  actually report; `needsKeystrokeTurnStart` reads it.

`portFileFallback` is the profile's third, optional field, and its absence is a
trust boundary rather than an omission — see its comment in `agents/types.ts`.

In-app self-update is `src/update/`, and no agent owns any of it: `version.ts`
is the injectable half (semver math, the one npm probe, the TTL latest-cache,
and the quiesce→update→restart runner), `specs.ts` derives the per-agent table
straight off `AgentSpec.update` and supplies the real spawns. An agent's whole
share is its `AgentUpdate` record — npm package, PATH binary, updater argv, and
`readState` for the one agent (codex) that writes updater state to disk
(`agents/codex/home.ts`). Absent `update` = ships no self-updater, and the
request fails soft. Which sessions a self-update quiesces resolves through
`agentKeyFor`, never `SessionEntry.tool`: that field is set only when a session
OVERRODE `agent.tool`, so reading it alone leaves every default-spec session
attributed to the wrong agent — and the processes actually holding the binary
running while it is replaced.

The spec's positional/launch declarations answer questions no caller may
re-derive from the key: `augmentsDefaultSpec` (does an antgrid.yaml
default-spec launch still get this agent's hook injection AND resume argv),
`resumeIsSubcommand` (does the resume argv fold AFTER the user's raw args), and
`notifyBodyFromTranscript` (does a `/notify` post with no inline message have a
transcript worth reading).

A chat agent's `chat-backend.ts` subclasses `ChatSession`
(`src/structured/chat-session.ts`), which owns everything that is not about one
provider: turn open/close and `stopReason`, the pending permission/question maps
and their retraction at every turn boundary and at dispose, the capability
state, the `setConfig` queue-then-validate path and `guardPick`, item
first-sighting (and the partial-item merge), the plan/usage/delta/replay frames,
and the transcript-snapshot guards. **Every `agent:*` frame is built there** — a
backend that emits one itself has forked the wire. What the backend declares is
its `ChatSessionProfile`: who names turns, whether its item frames are partial,
whether a mid-turn transcript read is trustworthy, and whether its interrupt
stops a turn or the whole session. Its own vocabulary is normalized in
`mapping.ts` through `structured/tool-card.ts` (`ToolKind`/`ToolStatus`/
`PlanStatus` + the item builders) and `structured/agent-error.ts` — the tables
are per-agent, the shapes are not.

`hookName` is deliberately a second vocabulary (`claude`, not `claude-code`) —
it is baked into on-disk hook configs and into codex's `trusted_hash`, so
renaming one to match its key silently un-trusts hooks in every install that
already has them.

- `config.ts` — Zod schemas for `antgrid.yaml`; var interpolation (`${project.path}`, `${env.VAR}`).
- `protocol.ts` — message types as Zod discriminated union. `createMessage()`, `parseMessage()`/`parseMessageFast()`.
- `terminal-manager.ts` → `terminal-session.ts` — PTY lifecycle; manager coordinates multiple sessions.
- `work-status.ts` — pure fold from outbound bus frames (+ the inbound turn-start/answer hooks) to PER-SESSION work status; `ProjectCore.workStatus` is only its rollup. **This is the ONLY per-session reduction** — `SessionManager` folds nothing, it stamps this one's answer onto each `session:updated` entry via the injected `sessionWorkStatusFor`, and `ProjectCore.commitWork` calls `refreshSessionWork()` when the per-session map moves (the list is otherwise re-emitted only when the sessions themselves change). That re-emit folds straight back in, so it terminates *only* because `foldSessions` returns the SAME state for an unchanged session set — keep that discipline. Two readers, two paths: the advert carries `status` + `sessionStatuses` (dots), and `SessionEntry.workStatus` carries the live per-session value the mode-switch dialog branches on (`undefined` for a session the reduction has no entry for, i.e. not running — which is right, a flip does not restart a stopped session). **Presence of `sessionStatuses` is the app's capability signal** — `{}` means "warm, nothing running", absent means an older bridge, so never omit it for a warm core. A session is "working" only while a TURN is open, never merely because it is alive, and "unread" once that turn ENDED with nobody looking at it — read state the bridge owns outright, because it is the only party that sees both every turn end and every client's `session:focus`. Read state is tracked PER CLIENT, keyed by `InboundSource` — the desktop reaches a core over loopback, the phone over the relay, and they look at different sessions. A session is "seen" if ANYONE is on it. One shared slot was tried first and is wrong: the last client to speak stole it, so a phone opening session B put a blue dot on session A under the desktop's cursor. Three inbound signals feed it — `sessionFocus` (`session:focus`), `clientFocusState` (`client:focus-state`) and `clientGone` (the socket closed: `onPeerOffline` for the phone, `LocalListener.onOwnerDisconnected` for the desktop, without which a client that quit keeps one session permanently exempt). All arrive on the DATA plane, so a project nobody has opened reports no read state at all. It is gated on `readTracking`: until some client says what it is looking at, nothing may be called unseen — otherwise a bare agent, an eval, or a desktop driven from its own terminal turns every finished turn blue with nothing able to clear it. Backgrounding (`client:focus-state{paused}`) releases only THAT client's session, so a sibling still watching keeps its own read; an answer landing in someone's pocket is unread; the app RESTATES its focus on resume, since only it knows what is still on screen. Nothing persists it on either side — a bridge restart is a fresh read state, and the app is forbidden from caching it (`app_shell.dart` skips `unread` when writing the status cache). The four "user acted" signals are asymmetric on purpose, and each asymmetry is load-bearing:
  - `/turn-start` hook (Claude only) → `turnStart`: clears the block AND opens a turn.
  - chat resolve (`agent:permission-resolve`/`-question-resolve`) → `answerRequest`: same, but ONLY if something was actually pending — a resolve racing a retraction would otherwise open a turn no turn-end closes.
  - bare PTY keystroke → `userReply`: clears the block only. Typing in an idle session is not work.
  - PTY keystroke that SUBMITTED (`isSubmitKeystroke` in `agent-core.ts`: a trailing CR, but not `\x1b\r` — alt+enter inserts a newline and may never be sent) → `userReply({submitted:true})`: also opens a turn, but only for a session in `keystrokeTurnSessions` — an agent with turn-END hooks and no turn-start (codex/cursor/copilot; see `needsKeystrokeTurnStart` in `agents/registry.ts`, which reads it off each agent's own `hooks.turnBoundaryEvents`). Never for Claude (it has a real signal) nor for the hookless agents (opencode/antigravity/kilo/kimi/mistral-vibe — nothing would close the inferred turn).

  The submit gate has **two** halves and both are required. A PTY delivers one keystroke per frame, so the submitting CR normally arrives alone and `isSubmitKeystroke` alone cannot tell a prompt from enter on an empty line or on a TUI menu — which start no turn, so the stop hook the inference depends on never fires. `hasTypedContent` (also `agent-core.ts`) marks the session in `typedSessions`, and only a submit with that marker opens a turn; opening consumes it. Which agent a session runs is `s.tool ?? defaultTool`, where `defaultTool` is folded from `agent:hello` — a `SessionEntry` carries `tool` only when it OVERRODE the project's `agent.tool`, so reading the entry alone silently opted every default-spec session out of the inference.

  Two ordering rules fall out of the fold being keyed by session id: an attributed turn-start that beats its session's first `session:updated` is HELD in `pendingTurns` for exactly one session list, and a notification whose `terminalId` is not a running session (config-`terminals:` slots stamp one too) falls back to the project-wide key rather than being filed where nothing can read it. That fallback FANS OUT — `statusFor` reads it for every running session — and a turn-start clears it on the word of one session; both are accepted (losing the signal is worse than over-reporting it), and both are the reason a config-`terminals:` error dots every session on the project.
- `port-scanner.ts` — platform-specific dev-port detection (polling).
- `tunnel-manager.ts` — maps ports→preview URLs; only emits `preview:url` for proxies with `browser: true`. An entry whose label/scheme is unchanged is not re-pushed, so anything recorded while `connState.suppressed` is ALSO tracked in `undelivered` and re-pushed on the next unsuppressed pass — reconnect re-enters `onPortsUpdate` with identical ports (via `resyncState`'s `emitCurrent()`), and the app's own pull is the other half: `PreviewService` registers a `preview:snapshot:request` hydrator per checkout, so the handler answers with `preview:snapshot` plus an `emitCurrent()` on every (re)establish — a checkout whose bundle is built after the connect-time replay has no other way to learn its ports. Preview bodies are compressed inside the tunnel message (`encodeBody` in `localhost-fetch.ts`, `bodyEncoding: "gzip-base64"`), never at the WebSocket layer — the relay carries AES-GCM ciphertext, so permessage-deflate has nothing to squeeze. **Only compress what the request's `acceptEncodings` advertised**: `bodyEncoding` reaches the app as a bare string, so an app that predates the encoding renders the gzip bytes as the body. Compatibility rides on that one field in both directions — `z.object` strips it for an old bridge, and an old app never sends it.
- `file-watcher.ts` → `file-tree.ts` — Chokidar watching with .gitignore support.
- `file-search.ts` — ripgrep when present, else `git grep --untracked`. Both are handed the abDir as an exclude, and it is load-bearing rather than cosmetic: every managed worktree lives under it, so a project root that CONTAINS the state dir would otherwise report the isolated checkouts' files as main's own hits. The exclusion is anchored at the search root (ripgrep leans on the spawn's `cwd` for that) and dropped when it does not lie inside — a searcher rooted at a worktree sits under the state dir and must not anchor an exclude at its own ancestor.
- `worktrees/` — managed checkouts for isolated sessions: Git lifecycle (`worktree-manager.ts`), the durable record (`checkout-store.ts`), repository identity (`project-resolver.ts`). See **Isolated sessions** below.
- `e2e/` — v2 handshake crypto (`transcript.ts`, `key-schedule.ts`, `confirm.ts`, `transport.ts`, `handshake-sig.ts`). See `docs/protocol/e2e-handshake.md` for the spec. `key-exchange.ts` provides the underlying X25519 ECDH primitive.
- `relay-client.ts` — the ONE machine WebSocket (a machine holds exactly one `RelayClient`, owned by `HostServer`). v3 auth: single signed `hello` (epoch from `relay-epoch.ts`, persisted at `<abDir>/relay-epoch`, minted once per process); `welcome` = authenticated — backoff resets ONLY there, equal jitter applied to the scheduled delay only. `getLicenseToken` runs before each (re)connect. Terminal-vs-retryable is the v3 error contract (last error frame's `retryable:false` → stop reconnecting; stream-scoped `ref` errors never count): `onAuthRevoked` fires only on the identity-dead verdicts `LICENSE_INVALID|LICENSE_REVOKED` (`LICENSE_AUTH_DEAD`; index.ts emits `{"event":"auth_revoked"}` to stderr). `LICENSE_EXPIRED` is deliberately NOT one — it is recoverable by time, so it takes the plain terminal path (stop reconnecting) while token maintenance keeps re-minting, and `onMinted` → `redialWithFreshToken()` brings the socket back on the first fresh mint with no process restart. `SUPERSEDED` = another socket now holds our deviceId — either a newer instance of ourselves, or (equal epoch, same key) our own redial evicting the half-open socket we just abandoned, which is the ordinary watchdog path and lands on the dead socket; log + stop reconnecting on THIS socket, never auth_revoked. Clock-skew self-heal: `error{AUTH_FAILED, serverTime}` → offset applied to the next hello's `ts`, once per offset value. E2E session is reactive, acked, make-before-break: kind-byte dispatch (0x01 = handshake plaintext, 0x00 = sealed), sealed `established`/`ping`/`pong` liveness, rekey keeps ≤2 receive contexts and zeroizes old keys only after the new confirm verifies.
- `relay-slot.ts` — re-export of `antgrid-wire`'s slot helpers (one TS copy, shared with the relay). The phone reaches us on a per-machine SLOT (`<accountDeviceUuid>#<machineDeviceUuid>`; see `packages/antgrid_relay_client/CLAUDE.md`). The slot is the ROUTE address — `_peerId`, `pending.peerId`, the `phoneEd25519ByDeviceId` key and the single-active-phone takeover check all stay on it. Everything keyed by the ACCOUNT device uses `baseSlotDeviceId`: both transcripts in `handleClientHello` (the agent one is the HKDF salt — a slot there derives keys the app can't open), the `trustedPeers`/`pairedPhones` lookups in `resolvePhoneEd25519PubB64`/`backfillPeerPubkey`, and the `pairedPhones.upsert` row. Stripping never widens admission — every candidate is still gated by `verifyTranscriptSig`. Presence is filtered by `isForeignSlot`: the relay fans it to every same-account peer, so a sibling slot would otherwise repoint our reply address (`peer-online`) or suppress our heavy stream because another machine's socket closed (`peer-offline`).
- `stream-mux.ts` — multiplexes project cores over the machine socket as sealed `{s, m}` envelopes (`s` absent/`"0"` = machine control plane; the ENVELOPE JSON is what gets fragmented, so `s` survives reassembly). `attachStream(bus, opts)` → `StreamHandle{streamId, detach, sendTunnel}`; admission = `stream-open` → `stream-opened` vs `error{ref: streamId}` (a rejection leaves the socket and other streams live); `opts.mayDeliver` is the OUTBOUND authorization hook, re-read on every bus frame and every `sendTunnel` (tunnel bypasses the bus) — absent means always-deliver, so a caller that answers to a switch must fail closed in its own provider; on each `welcome` the mux re-opens every attached stream (the relay dropped its `openStreams` on the disconnect). Current relays admit every stream a healthy machine opens — no per-account quota survives (`SESSION_LIMIT_EXCEEDED` is retired, kept only for relays predating the worker-limit change; `ErrorCode` in `packages/antgrid-wire/src/relay-protocol.ts` reserves the name for exactly that reason, and the relay side is the Streams bullet in `relay/CLAUDE.md`). The one rejection a current relay can still send is `STREAM_LIMIT_EXCEEDED`, the relay's structural per-connection ceiling: orders of magnitude above real use, so treat it as our bug (a leak of undetached streams), never as backpressure to retry. An inbound frame for an unknown streamId is dropped AND answered with a control-plane `stream-invalid {streamId}` (rate-limited per dead id): a host restart re-attaches every project under fresh ids, and without that notice the phone replays onto the dead id forever with nothing to trigger a renegotiation.
- `host-server.ts` + `paired-phones.ts` — machine-level device trust. `HostServer.startRemoteControlPlane()` owns the single machine RelayClient (bare `deviceUuid` — the only registration shape; compound `deviceUuid.projectId` is gone); project cores attach as streams via `remoteDepsFor(projectId)` (`ProjectCoreRemoteDeps = {attachStream, currentPeerPubkey, sendPushDeliver}` — `wireRelaySlot` is deleted). Stream admission publishes `stream-ready {projectId, streamId}`, and `buildProjectsAdvertisement` (`agent:projects`) carries per-project `streamId` so a reconnecting phone binds without a fresh `project:start`; stopped projects start on demand (`handleControlPlaneVerb` → `project:start`). `startCore` re-advertises unconditionally: an open no phone asked for (restart re-open, desktop-side open) lands AFTER the handshake advert, and nothing else announces it. A rejected verb returns `control:result {ok:false,error}` to the phone (never silently dropped). Authorization for a remote device is `loadRemoteAccessPolicy(abDir)` (`agents/mobile-access-policy.json` — the filename and the `mobile-access:*` verbs keep the old spelling on purpose: both cross a version boundary the rename cannot reach) — ONE machine-wide boolean, the only gate, read live at every check via `remoteAccessEnabled()` so `mobile-access:set` takes effect without restarting a core. It gates the stream in BOTH directions and both halves are load-bearing: inbound at `currentPhoneAllowed()` (agent-core's bus handler + `handleTunnelMessage`), outbound at the stream's `mayDeliver` (`attachRelayStream`). Inbound alone is not enough — a project the phone cold-started opens as a `mode:"remote"` core with no `PromotionHandle`, so `demoteAllPromoted()` (which turning the switch off also runs, for every PROMOTED slot) never touches it and it would keep streaming terminal/tree/git at the phone. Gating at the send, not at detach, is deliberate: the core and its stream stay alive, so flipping the switch back on resumes the same `streamId` with no re-attach and no destroyed work. Which projectId that phone may name is bounded solely by `isSafeProjectId` + the `seenProjects` catalog — every remote verb (`project:start`, both sessions RPCs) must do that lookup, there is no second gate behind it. `loadPairedPhones(abDir)` (`agents/paired-phones.json`) is NOT authorization: it is the identity/push-token/`lastSeenAt` row, kept for push targeting and freshness (hence `watch()` + `touchLastSeen` survive).
- `auth/` — in-memory OAuth (no on-disk store). `credentials.ts` parses one JSON line from stdin into a `BootstrapPayload` (`local | remote`, 10s idle timeout) written by the app on spawn. `oauth-client.ts` mints tokens via `POST /api/auth/oauth2/token` (`grant_type=client_credentials`, `resource=<licenseApiUrl>/api/auth`); `startTokenMaintenance` re-mints at 80% of TTL (30s retry). On `invalid_client` → emit `auth_revoked` to stderr, exit 4 — that verdict is keyed on the ERROR CODE, not the status: Better-Auth answers a revoked device with 401 but a deleted client row with **400** ("missing client"), and a sign-out rotates the device and drops its row, so both mean the cached pair is dead. Credentials reach the host only once, via the stdin bootstrap, so a host left running on a rotated-away pair can never recover on its own — the app respawns it when the account device changes (`local_host_warmup.dart`). **The boot-time control-plane mint is exempt from the exit** (`fatalRevokeArmed`, disarmed across `start()`'s `startRemoteControlPlane()`): host.json and the ready marker are already out by then, so exiting would have the app's supervisor respawn straight back into the same dead pair — a permanent crash loop that also takes down the loopback plane local work depends on. Boot logs and serves loopback-only; a verdict from token maintenance afterwards is still fatal.

## Isolated sessions (`src/worktrees/`)

The routing model — which message types carry a `checkoutId`, and the app-side set
they are mirrored into by hand — is in `docs/architecture.md`. This is the
host-side lifecycle and its traps.

`WorktreeManager` owns managed-worktree lifecycle alone and DERIVES the worktree
path; it accepts one from neither a client nor `SessionManager`. `CheckoutStore`
is the durable record, `CheckoutRuntimeRegistry` the in-memory index of the
per-checkout services `prepareCheckoutRuntime` (`agent-core.ts`) builds.
`project-resolver.ts` answers "which repository is this folder", and it must keep
ANSWERING rather than throwing for a non-repository: `HostServer.open` runs it
first for every project on the machine, Git-backed or not.

- **A managed checkout is state in three places, and only one of them is in the
  project's store dir.** `agents/<projectId>/sessions.json` (`SessionManager`)
  holds the session→checkout binding; `checkouts.json`, in that SAME dir
  (`CheckoutStore`), holds the path and branch; the worktree itself lives under
  `<abDir>/wt/<repo-label>-<4>/<word-pair>-<4>` (`checkout-names.ts`, readable on
  purpose and capped for Windows MAX_PATH) and its branch is an `antgrid/*` ref
  in the user's own repository. Erasing the store dir destroys the only map from
  a session to the two things outside it, so a project-forget must reclaim those
  FIRST — afterwards nothing on the machine says which `wt/` directories and
  `antgrid/*` branches were ours. The readable root name is derived from the
  repository FOLDER, so it cannot be recomputed once that folder is gone:
  removal reads `CheckoutRecord.path`, and `WorktreeManager.projectRoots` keeps
  the pre-rename `wt/<projectId>/` as a candidate for older checkouts.
- **Two projects can share one worktree root, so nothing may delete a directory
  it has not proved is its own.** The root name carries only 4 characters of the
  projectId, and a repository cloned twice gives both copies the same label — so
  `<label>-<4>` collides at 1-in-65536 per such pair, permanently for that
  machine. Both sweeps therefore gate on `readCheckoutOwner` (`checkout-owner.ts`),
  which reads the checkout's own `.git` pointer: it survives the main repository
  being deleted, which is exactly when `reclaimForgottenProject` runs and when
  `git rev-parse` refuses to answer. Reclaim removes RECORDED paths one by one —
  never a blanket `rm` of the root, which destroyed the other project's
  uncommitted work and reported `stranded: 0`. Regression: `worktree-shared-root.test.ts`.
- **`main` is synthesized, never persisted.** `agent-core.ts` mints the `main`
  `CheckoutRecord` from the project path at construction; nothing writes it to
  `checkouts.json`, and `CheckoutRuntimeRegistry.remove("main")` is a no-op. A
  store lookup for `main` therefore misses BY DESIGN — every reader special-cases
  the id (`HostServer.handleCheckoutPath` is the pattern) rather than reporting an
  unknown checkout. `checkout-types.ts` is where both kind questions are
  answered, and they are not the same question: `isManagedCheckoutKind` (ours to
  remove) and `isIsolatedCheckoutKind` (not the primary working tree, so
  checkout-scoped routing applies). Comparing a `kind` literal inline instead is
  how a new checkout kind becomes silently wrong in several places at once.
- **The checkout path never crosses the session wire.** Frames carry a
  `checkoutId`; the one place a host path is handed out is the loopback control
  verb `checkout:path`, and even there the caller only NAMES a checkout (`main`
  resolves from the host's seen catalog, anything else from `checkouts.json`). Its
  absence from the E2E control plane is deliberate — a phone has no use for a path
  on this machine.
- **The dirty/unpushed refusal is duplicated on purpose and must stay in
  lockstep.** `SessionManager.deleteManaged` preflights so the UI can refuse
  without destroying anything; `WorktreeManager.removeNow` repeats it under the
  project lock, closing the race. `WORKTREE_DIRTY` and `WORKTREE_UNPUSHED` are
  distinct because the two losses are not the same — a directory, versus commits
  that outlive it — and the app's dialog copy branches on which one it got. The cold-project path
  (`HostServer.deleteColdSession`) has no preflight at all and leans entirely on
  the manager's copy — that is the one that can never be relaxed.
- **`git worktree remove` is the point of no return, and nothing after it may
  throw.** The agent and the user are free to switch, rename or delete the
  session's branch at any time — `git:checkout` is checkout-scoped, so the
  isolated tree is theirs to move — and both of the branch's ordinary end states
  make `git branch -D` exit non-zero: renamed away ("not found"), or checked out
  in the user's own tree, which Git refuses to delete out from under a worktree.
  Throwing there left the store row behind with no directory under it, and
  `inspect` then reports the worktree missing forever, so the session could never
  be deleted again. The branch is kept, `worktree_delete_branch_kept` is logged,
  and the row goes. For the same reason `inspect`'s unpushed check reads
  rev-list's EXIT CODE: it answers "nothing unpushed" and "I could not answer"
  with the same empty stdout, and only a branch that is genuinely GONE means
  nothing is at risk — every other failure refuses, and `force` is the way past.
  `dirty` reads the exit code for the same reason, and the reclaim below sharpens
  it: an unreadable `git status` counts as DIRTY wherever a `.git` link survives,
  because taking it for clean would now hand the user's work to an `rm` rather
  than to a Git that would have refused.
- **A delete is seconds of real work, so it is advertised and it refuses.**
  `SessionManager.deleting` (sessionId → checkoutId, in-memory, never in
  `toPersisted`) is the single source for BOTH `SessionEntry.deleting` on the
  wire and `isCheckoutDeleting`, which agent-core's inbound dispatch pulls to
  refuse every checkout-variable verb for that checkout with
  `control:result{CHECKOUT_DELETING}`. One set, one lifetime — a pushed mirror
  could let the flag an app saw and the refusal it then gets disagree. The
  refusal cannot be a skipped prepare: `runtimeFor` ends in `?? mainRuntime`, so
  skipping answers a checkout-scoped request out of MAIN's tree. Three orderings
  are load-bearing: the flag is set only AFTER the dirty/unpushed preflight (a
  refusal the user can still answer must not blink the row through pending), it
  is cleared BEFORE the failed-removal rollback re-prepares the runtime (never in
  a `finally` — the checkout is being restored by then, not removed), and a
  second `deleteManaged` or a `start()` on a flagged session is refused with
  `WORKTREE_DELETE_IN_PROGRESS` so the flag's life is exactly one operation.
  The guard only covers what enters agent-core's inbound dispatch — anything
  served by `host-server.ts` or the HTTP tunnel bypasses it by construction,
  `deleteColdSession` included, and leans on `WorktreeManager.removeNow`'s own
  checks instead.
- **Runtime teardown precedes `git worktree remove`, always, and must take whole
  process TREES with it.** The checkout's runtime holds the very directory Git is
  about to delete: auto-started `services:` PTYs are cwd'd inside it and the
  watcher keeps handles open. On Windows an open handle is a sharing violation,
  so `deleteManaged` tears the runtime down first and rebuilds it if Git refuses
  anyway. Killing the PTY is not enough to achieve that: `IPty.kill()` signals the
  leader alone, and Windows has no process group to signal in its place, so a
  shell's children — and the headless `conhost.exe` every console child gets —
  survive with the directory still open. `killProcessTree` (`terminal-session.ts`)
  closes that, and it reaches the two platforms by different means that fail in
  different ways. Windows walks parent links (`taskkill /T`), so it must be
  issued BEFORE the leader dies — a dead leader no longer provides the links —
  which is why `TerminalSession.kill()` chains its handle kill onto the tree
  kill rather than firing both. The tree kill is issued synchronously and
  AWAITED asynchronously: it returns a promise, so the delete path waits — on
  Windows, where the promise settles on taskkill's exit and Git sweeps the
  directory the instant it resolves; the POSIX arm settles at `kill(2)` return
  and guarantees nothing, which costs nothing because POSIX unlinks regardless.
  Every other caller ignores the promise and leaves the loop free: a blocking
  wait on an ordinary terminal close is what made a delete go dark for its whole
  duration. It therefore must never reject.
  POSIX names the process GROUP, which needs no ordering but exists
  only if the child leads one: a pid leading no group names no group and the
  signal reaches nothing, silently. `processGroupSpawn()` is therefore a
  PRECONDITION, not a preference, and every non-PTY spawn whose children must
  die with it has to carry it (a PTY child already leads a session via its own
  `setsid`). `command:run` is the case that needs all of it: `shell: true` means
  the handle `teardownCheckoutRuntime` holds is the shell, never the command
  whose cwd is inside the checkout — `killChildTree` is that pairing, and
  `TerminalManager.killAndAwaitTree` its PTY counterpart (the same signal
  `kill()` sends; only the waiting differs). Waiting for the tree is NOT waiting
  for the PTY's exit — `SessionManager.awaitTerminalExit` is the other question,
  and `stopAndAwait` needs both answers: an asynchronous taskkill can deliver
  the leader's exit while it is still walking the rest of the tree, so the exit
  alone no longer implies the directory is free.
  Mind the asymmetry in what a survivor costs
  — on Windows it blocks the delete outright, while POSIX unlinks the directory
  out from under it and leaves only a process nobody will reap.
- **A delete Git cannot finish, Antgrid finishes itself.** `removeNow` no longer
  treats a non-zero `worktree remove`, or a checkout Git has stopped registering,
  as a refusal to be reported and left alone. Both leave identical wreckage — a
  directory that is ours, past guards the user already answered — and the older
  behaviour made that wreckage PERMANENT: Git deletes `.git` early in its sweep,
  so the next prune reaped the registration, and every retry then landed in an
  unregistered-but-present branch that threw unconditionally. `reclaimOwnedPath`
  deletes it directly and prunes afterwards (the registration is only prunable
  once nothing claims the directory). It is guarded on the PATH being under
  `<abDir>/wt/`, never on `record.managed` or `kind`: those are store metadata a
  hand-edited file can lie about. It is best-effort — the caller re-tests and
  still raises `WORKTREE_DELETE_FAILED`, because whatever held the directory open
  is worth surfacing. Git's stderr goes to the local log via `logGitFailure`, and
  deliberately NOT into the structured `logWorktreeEvent` payloads, which feed
  analytics and so carry a code and no message.
- **A rollback is not a delete.** `rollbackPrepared` bypasses the dirty/unpushed
  guard on purpose — no agent was ever admitted to that checkout — but never
  drops a branch whose head has moved out from under it.
- **Reconciliation may only DELETE on a complete read of the store.** `reconcile`
  rides on an isolated create the user asked for, and its orphan sweep removes a
  directory on the strength of no row naming it — so `CheckoutStore.read()`
  reports `healthy` and the sweep refuses to run without it. `list()` answers `[]`
  for an unreadable or unparseable file and silently drops an individually bad
  row (deliberately, so one bad row cannot hide its siblings), and reading that
  as "no checkouts exist" force-deletes every live worktree in the project. The
  row-pruning half is safe on a partial read because its failure direction is
  inaction. The sweep also repeats `removeNow`'s dirty refusal: housekeeping must
  never be less reluctant than the delete the user asked for.
- **A row whose worktree is gone must be pruned, not counted as live.** The
  row-pruning half drops a managed row in two shapes, and both are the same
  permanent loss wearing opposite symptoms: no directory at all, and a directory
  Git has stopped registering that has ALSO lost its `.git` link (`isStranded`).
  A row kept in either state makes its session undeletable forever — `remove()`
  can neither find a worktree nor let Git drop one — and the second shape used to
  read as healthy purely because the directory still existed. Both signals are
  required for `isStranded`, and the `.git` check is what makes it safe: a
  checkout someone is still working in keeps its link however odd its
  registration looks. A row is only ever written AFTER `worktree add` and
  `verifyCreated` succeeded under this same project lock, so a missing directory
  is always post-hoc loss and never a create in flight. `registeredPaths`
  distinguishes "Git says none" from "Git could not be asked" (`undefined`) — an
  empty set standing in for an unanswered question would condemn every checkout
  in the project at once.
- **`baseRef` is retained without a reader on purpose** — see its comment in
  `worktrees/checkout-types.ts`.

### Checkout setup (`worktree.setup`)

The config schema, the variable table and the `ANTGRID_*` contract are in
`docs/architecture.md`. This is the host-side lifecycle: `CheckoutSetupRunner`
(`worktrees/checkout-setup.ts`) resolves the checkout's own block into a plan
file and runs the whole thing in ONE PTY — the bridge re-invoked under the
hidden `worktree-setup` subcommand (`cli/worktree-setup.ts`), because the
shipped bridge is a compiled single-file executable and `process.execPath` plus
a subcommand is the only self-invocation that works, the same shape
`resolveHookCommand` relies on. One PTY per step would reset the scrollback of
the step that actually failed.

- **Setup runs before the checkout's `services`, and the deferral is the point.**
  `prepareCheckoutRuntime(checkout, { deferServices: true })` holds back the
  `services` block ALONE — watchers, port detection and tunnels still start — and
  `startDeferredServices` is the only thing that clears it (the config watcher
  also refuses to spawn a service added while a checkout is deferred, or a setup
  step editing `antgrid.yaml` would start what the deferral is holding).
  Auto-starting `bun run dev` against an empty `node_modules` is a guaranteed
  failure the user then has to read past. Every terminal state releases it, so
  `runCheckoutSetup` MUST report exactly one of `done`/`failed`/`skipped` for
  every run it is handed — a checkout with no block reports `done` with
  `stepCount: 0` rather than staying silent, and a runner that returned nothing
  would leave that checkout with no services at all. The run starts strictly
  AFTER `createWorktree` has flushed, emitted and re-announced (the create reply
  must go out well inside the app's 15 s pending-reply timeout), and it is never
  awaited.
- **A `running` setup state is never persisted.** `checkouts.json` carries
  `setupState` only for the durable outcomes (`DURABLE_SETUP_STATES`,
  `worktrees/checkout-types.ts`); `running` and `interrupted` can never be
  written. `interrupted` is DERIVED on load from a marker's absence, so a bridge
  that died mid-run comes back "Setup didn't finish" instead of a row that is
  permanently preparing and unfixable — the same trap `deleting`'s comment in
  `protocol.ts` was written to avoid. A marker's absence alone is not enough,
  though: every checkout cut before the project declared a setup block carries
  none either, so the derivation is gated on the checkout still DECLARING one
  (`checkoutDeclaresSetup`), or an upgrade banners "Setup didn't finish" on every
  isolated session the user already had. A rerun clears the marker BEFORE it starts,
  for the same reason. There is deliberately no auto-rerun on launch: a setup
  step can be expensive or destructive and the user did not ask for one on this
  launch.
- **The setup PTY must stay registered in the runtime's `configuredTerminalIds`
  or a Windows delete breaks.** That map is what `teardownCheckoutRuntime` sweeps
  with `killAndAwaitTree` before `git worktree remove`, and a live `bun install`
  holding the checkout as its cwd is exactly the open handle Windows refuses to
  delete around. It is registered identity-mapped (`<checkoutId>:setup` → itself,
  since the app is handed the full id) and off the runner's OWN reported
  terminalId, so a checkout that spawned nothing registers nothing.
  `deleteManaged` additionally cancels a live run and AWAITS the kill on both of
  its branches — after the dirty/unpushed preflight, since a refusal the user can
  still answer must not have destroyed the run first — and never refuses a delete
  on account of setup. The PTY carries no `type` (typing it `service` would put a
  provisioning log in the services list) and is the one terminal spawned with
  `retainScrollbackOnExit`: the failing step's output is read after the run at
  least as often as during it, and `TerminalManager.forget` in teardown is what
  gives that retention a definite end.
- **`suppressOscTitle` must never be set on the setup PTY.** Step transitions
  ride OSC 2 titles (`formatSetupStepMarker`), and that flag suppresses the
  `onTitle` callback itself — the channel being used. The other half is
  `onTerminalTitle` feeding `setupRunner.handleTitle` and RETURNING before the
  namer fallback; without that guard the session namer reads setup progress as a
  conversation title. `suppressOscNotifications` IS set: provisioning must never
  raise an attention signal. Coarse transitions ride the immediate
  `notifyObservers()` path, never the debounced activity emit, or the banner lags
  a step behind; live output stays on the setup terminal's own `terminal:output`.
- **The start gate lives on the bridge, in memory.** A `session:start` arriving
  while setup runs records `pendingStart` (with its `initialPrompt`) and replies
  `ok: true` — the entry carries `setup.pendingStart`, so the reply is honest.
  A user who creates a session on a phone and locks the screen must come back to
  a running agent, which is why the queue is not the app's. The prompt is
  never persisted: a restart legitimately drops it and the session sits stopped
  with a Start affordance. `session:setup` (`skip` releases the gate and leaves
  the run going, `cancel` kills the tree, `rerun` starts fresh from a settled
  state) is the only verb over it.
