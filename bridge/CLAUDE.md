# Bridge (`bridge/src/`)

Deep reference for the bridge. Root `CLAUDE.md` holds the repo-wide gotchas,
commands, and conventions — this file loads only when working under `bridge/`.

What may be written in any `CLAUDE.md`, this one included, is governed by
*Maintaining these files* in the root `CLAUDE.md`.

## Adding an agent

**`src/agents/registry.ts` is the single entry point.** Add the key to
`AgentKey` (`src/agents/types.ts`) and the compiler names every required field
the new record is missing — a forgotten one is a build error, not a session that
quietly lacks the feature. `AgentSpec`'s optional fields are capabilities;
absence is the honest answer, never a default. Every per-agent module under
`src/` lives in `src/agents/<key>/`: `hooks.ts` for a hook agent, `mcp.ts` for one
pointed at the bridge's MCP server, `driver.ts`
and the `chat-backend.ts` / `mapping.ts` / `spawn.ts` it wires for a chat agent,
`title.ts` for one whose session name is read off disk. One thing lives outside
it on purpose: the installed-side integration assets in `bridge/plugin/<agent>/`
(the materialized hook scripts, and opencode's plugin, which runs inside
opencode's own Bun runtime — this is why `hooks.posts` is declared rather than
derived from `toPosts`). Nothing in `app/` changes: `BY_HOOK_NAME`, the tools advertisement, `isChatCapableTool`,
`handlerObservable`, and the judge / transcript / title dispatch all derive from
that one table.

Every field of `AgentSpec` and `HookProfile` is documented at its own declaration
in `agents/types.ts`, which is where the rules a new entry must satisfy live —
`headless` (verified argvs by reach; naming borrows, a judge never does),
`gracefulExit` (narrows the default ask; see **Stopping an agent**), `posts` and
`turnBoundaryEvents` (both REQUIRED so a profile cannot leave them unstated),
`portFileFallback` (absence is a trust boundary), `augmentsDefaultSpec`,
`resumeIsSubcommand`, `notifyBodyFromTranscript`, `update`. Two suites gate the
table itself — `agent-hook-declarations.test.ts` checks each profile against the
events the agent actually dispatches, and `agent-spec-characterization.test.ts`
pins the resume/prompt argvs, the materialized hook files and codex's
`trusted_hash` strings byte-for-byte. `headless.test.ts` covers reach selection
and `judgeCapable`.

Four things are NOT answered at any declaration:

**An agent's native session id is not stable across a resume**, so nothing may
read a change of it as "a new conversation started". Measured on Claude Code:
`--resume` copies the transcript into a NEW file and appends under a fresh id, so
the same thread comes back wearing a different name. Every guard against
re-naming is otherwise per-run — `SessionNamer` and `TitleAttempts` both die with
the PTY — which is why the winning signal is also written to the session row as
`autoTitleRank`, and why `SessionManager.noteConversationStart` records AT LAUNCH
that a run continues the previous conversation. The first identity report spends
that claim; every rotation after it is a real `/clear`. Get either half wrong and
a stop/start pays another model spawn and renames the session — not back to the
same title, since the transcript read returns the LAST few messages. Nothing
tests this.

**The `agent:tools` advert carries TWO arrays and the split is load-bearing.**
`tools[]` is the PATH probe — what this machine can launch. `agents[]`
(`agent-catalog.ts`, projected from the whole registry) is what each agent IS.
The app needs the second for questions the probe structurally cannot answer —
naming a cached session row from a machine that never probed, or offering a judge
the current target lacks — so a new agent is named and capability-described in
the app with no app release. Widening `tools[]` instead was rejected: an app
predating the change would read every row as installed. `agents[]` is optional on
the wire so an older bridge still parses, and each row is total.

**`handlerObservable` has a SECOND reader and the two are not interchangeable.**
`agents[].handler` describes an agent, so it is the only answer available before
anything is armed; each `handler:status` snapshot carries `observability`
(`HandlerEngine.observabilityFor`), which describes a SESSION and is re-derived on
every emit. Optional on the wire, so its absence is "not reported", never
`unsupported` — and `escalate_only` (watched, no headless judge) must stay
distinct from `unsupported` (nothing reaches the engine), or an unwatchable arm
looks armed-and-quiet.

**Which sessions a self-update quiesces resolves through `agentKeyFor`, never
`SessionEntry.tool`** — that field is set only when a session OVERRODE
`agent.tool`, so reading it alone attributes every default-spec session to the
wrong agent, leaving the processes that hold the binary running while it is
replaced. `src/update/` owns the rest: `version.ts` is the injectable half,
`specs.ts` derives the table off `AgentSpec.update`.

A chat agent's `chat-backend.ts` subclasses `ChatSession`
(`src/structured/chat-session.ts`), which owns everything that is not about one
provider — turn open/close, the pending permission/question maps and their
retraction, the capability state, the `setConfig` queue-then-validate path, item
first-sighting, and the transcript-snapshot guards. **Every `agent:*` frame is
built there**: a backend that emits one itself has forked the wire. What the
backend declares is its `ChatSessionProfile`. Its own vocabulary is normalized in
`mapping.ts` through `structured/tool-card.ts` and `structured/agent-error.ts` —
the tables are per-agent, the shapes are not.

`hookName` is deliberately a second vocabulary (`claude`, not `claude-code`) — it
is baked into on-disk hook configs and into codex's `trusted_hash`, so renaming
one to match its key silently un-trusts hooks in every install that already has
them.

## Component map

What each area owns. Mechanism lives at the definitions in the files themselves;
what is here is identity plus the contracts that span more than one of them.

- `config.ts` — Zod schemas for `antgrid.yaml`; var interpolation (`${project.path}`, `${env.VAR}`).
- `protocol.ts` — message types as Zod discriminated union. `createMessage()`, `parseMessage()`/`parseMessageFast()`.
- `terminal-manager.ts` → `terminal-session.ts` — PTY lifecycle; manager coordinates multiple sessions. On Windows each PTY also joins a kill-on-close job (`win32-process.ts`); the invariants are under **Isolated sessions**, because what they protect is a checkout delete. `terminal-screen.ts` is a headless `@xterm/headless` VT per PTY, fed the same bytes BEFORE the `suppressed` drop so it stays current through a socket drop, and its serialization — not the `ScrollbackBuffer` tail — is what an attaching app replays. **Only the client may ask for history** (`history: true` on `terminal:snapshot:request`), because only it knows what its engine holds: the app keeps far more than the bridge does (`SCREEN_SCROLLBACK_LINES` against `maxScrollbackLines` in `app/lib/models/terminal_models.dart`), so every bridge-initiated push (`resyncState`) is screen-only. How the blob is composed — the `3J` rule, the mode restatement, `pendingTail()` — is documented at each definition in `terminal-screen.ts` / `terminal-modes.ts`.
- `work-status.ts` — pure fold from outbound bus frames (+ the inbound turn-start/answer hooks) to PER-SESSION work status; `ProjectCore.workStatus` is only its rollup. **This is the ONLY per-session reduction** — `SessionManager` folds nothing, it stamps this one's answer onto each `session:updated` entry via the injected `sessionWorkStatusFor`, and `ProjectCore.commitWork` calls `refreshSessionWork()` when the per-session map moves. That re-emit folds straight back in, so it terminates *only* because `foldSessions` returns the SAME state for an unchanged session set — keep that discipline. **Presence of `sessionStatuses` is the app's capability signal**: `{}` means "warm, nothing running", absent means an older bridge, so never omit it for a warm core. Read state is tracked PER CLIENT (keyed by `InboundSource`) and fed by three inbound signals — `sessionFocus`, `clientFocusState`, and `clientGone` (`onPeerOffline` for the phone, `LocalListener.onOwnerDisconnected` for the desktop). Nothing persists it on either side, and `app_shell.dart` must keep skipping `unread` when writing the status cache. The reasoning behind each rule is on the declarations in the file.
  - `/turn-start` hook (Claude only) → `turnStart`: clears the block AND opens a turn.
  - chat resolve (`agent:permission-resolve`/`-question-resolve`) → `answerRequest`: same, but ONLY if something was actually pending — a resolve racing a retraction would otherwise open a turn no turn-end closes.
  - bare PTY keystroke → `userReply`: clears the block only. Typing in an idle session is not work.
  - PTY keystroke that SUBMITTED (`isSubmitKeystroke` in `keystrokes.ts`: a trailing CR, but not `\x1b\r` — alt+enter inserts a newline and may never be sent) → `userReply({submitted:true})`: also opens a turn, but only for a session in `keystrokeTurnSessions` — an agent with turn-END hooks and no turn-start (codex/cursor/copilot; see `needsKeystrokeTurnStart` in `agents/registry.ts`, which reads it off each agent's own `hooks.turnBoundaryEvents`). Never for Claude (it has a real signal) nor for the hookless agents (opencode/antigravity/kilo/kimi/mistral-vibe — nothing would close the inferred turn).

  Not every `terminal:input` frame is a keystroke. A viewer's VT engine answers
  the modes the guest turned on over the SAME channel, so a session with DEC
  1004 focus reporting or mouse tracking on gets `CSI I`/`CSI O` on every window
  focus change and a mouse report per click — `isTerminalReport` (`keystrokes.ts`)
  is what keeps those out of every "the user acted" consumer in agent-core's
  `terminal:input` case while still writing them to the PTY. The guard is the
  `break` those consumers all sit below, so one added there inherits it.
  Without it, clicking back into the window to ANSWER a blocked agent was itself
  what cleared its "needs you" dot.

  The submit gate has **two** halves and both are required. A PTY delivers one keystroke per frame, so the submitting CR normally arrives alone and `isSubmitKeystroke` alone cannot tell a prompt from enter on an empty line or on a TUI menu — which start no turn, so the stop hook the inference depends on never fires. `hasTypedContent` (also `keystrokes.ts`) marks the session in `typedSessions`, and only a submit with that marker opens a turn; opening consumes it. Which agent a session runs is `s.tool ?? defaultTool`, where `defaultTool` is folded from `agent:hello` — a `SessionEntry` carries `tool` only when it OVERRODE the project's `agent.tool`, so reading the entry alone silently opted every default-spec session out of the inference.

  Two ordering rules fall out of the fold being keyed by session id: an attributed turn-start that beats its session's first `session:updated` is HELD in `pendingTurns` for exactly one session list, and a notification whose `terminalId` is not a running session (config-`terminals:` slots stamp one too) falls back to the project-wide key rather than being filed where nothing can read it. That fallback FANS OUT — `statusFor` reads it for every running session — and a turn-start clears it on the word of one session; both are accepted (losing the signal is worse than over-reporting it), and both are the reason a config-`terminals:` error dots every session on the project.
- `port-scanner.ts` — platform-specific dev-port detection (polling).
- `tunnel-manager.ts` — maps ports→preview URLs; only emits `preview:url` for proxies with `browser: true`. An unchanged entry is not re-pushed, so anything recorded while `connState.suppressed` is ALSO tracked in `undelivered` and re-pushed on the next unsuppressed pass; the app's `PreviewService` registers a `preview:snapshot:request` hydrator per checkout, which is how a checkout whose bundle is built after the connect-time replay learns its ports at all. HTTP responses stream as start/chunk/end on the preview channel; every slice is one frame under `FRAG_THRESHOLD`, base64 with gzip per slice when it pays (`encodeChunk` in `localhost-fetch.ts`, never at the WebSocket layer — the relay carries AES-GCM ciphertext, so permessage-deflate has nothing to squeeze), and the loop awaits each frame's hand-off, so the credit window is the only pacing and a stream holds at most one queued frame. Bun buffers the upstream body regardless of read pace — pacing bounds the send queue, not RSS. The outbox retains whole small streams for the app's same-requestId retry; a cancel from the app aborts the fetch, and every in-flight run is aborted when the peer goes offline or a session is (re)established (`abortHttpStreams`, driven from `project-core`'s peer hooks) — the relay client's queue clear only reaches a run parked on a settle. Aborting the fetch's signal is what closes the upstream on Bun; `reader.cancel()` alone does not. A `tunnel:ws-data` the send path cannot deliver closes that tunnel (`teardownWs` then `releaseUpstream`, code 1009/1001); one the remote-access switch refuses (`"gated"`) is dropped and the tunnel kept. **The bridge, not the phone, is the authority on a port's scheme**, and the self-signed-cert exemption applies to the WebSocket upstream as well as to fetch. Everything else is documented at its own definition in the file: the abandoned-socket park and its bounded exception (`WS_ABANDONED_MAX`), the `vite-hmr` subprotocol negotiation, the forwarded handshake headers, and why `openUpstream` must catch.
- `file-watcher.ts` → `file-tree.ts` — Chokidar watching with .gitignore support.
- `file-search.ts` — ripgrep when present, else `git grep --untracked`. Both are handed the abDir as an exclude, and it is load-bearing rather than cosmetic: every managed worktree lives under it, so a project root that CONTAINS the state dir would otherwise report the isolated checkouts' files as main's own hits. The exclusion is anchored at the search root (ripgrep leans on the spawn's `cwd` for that) and dropped when it does not lie inside — a searcher rooted at a worktree sits under the state dir and must not anchor an exclude at its own ancestor.
- `worktrees/` — managed checkouts for isolated sessions: Git lifecycle (`worktree-manager.ts`), the durable record (`checkout-store.ts`), repository identity (`project-resolver.ts`). See **Isolated sessions** below.
- `e2e/` — v2 handshake crypto (`transcript.ts`, `key-schedule.ts`, `confirm.ts`, `transport.ts`, `handshake-sig.ts`). See `docs/protocol/e2e-handshake.md` for the spec. `key-exchange.ts` provides the underlying X25519 ECDH primitive.
- `relay-client.ts` — the ONE machine WebSocket (a machine holds exactly one `RelayClient`, owned by `HostServer`). v3 auth: single signed `hello` (epoch from `relay-epoch.ts`, minted once per process), `welcome` = authenticated, and backoff resets ONLY there. **Terminal-vs-retryable is the v3 error contract and the verdicts are not interchangeable**: `onAuthRevoked` fires only on the identity-dead pair `LICENSE_INVALID|LICENSE_REVOKED` (`LICENSE_AUTH_DEAD`); `LICENSE_EXPIRED` is deliberately NOT one — it is recoverable by time, so it takes the plain terminal path while token maintenance keeps re-minting and `onMinted` → `redialWithFreshToken()` brings the socket back with no process restart; `SUPERSEDED` means another socket now holds our deviceId (often our own redial evicting a half-open one), so log and stop on THIS socket, never `auth_revoked`. The E2E session — kind-byte dispatch, acked make-before-break rekey, ≤2 receive contexts — is documented in `e2e/`. Outbound APP frames go through `send-scheduler.ts` — one FIFO queue per channel, control drained ahead of preview, and **sealed at dequeue**, so a frame queued across a rekey goes out under the keys live at that moment and a torn-down session drops its backlog instead of writing it under retired keys. Sealed SESSION frames and the relay's own JSON verbs (`sendJson`) never enter it: liveness and stream admission must not queue behind app bulk. Session frames sealed under the ESTABLISHED keys are still CHARGED against the window even though the gate never holds them, because a relay drop report names only a channel and a byte count — bytes written outside the accounting would un-charge something that was never charged. The receiving half counts every kind-0 frame the established keys opened or nothing opened (a frame nobody can decrypt was charged too) and answers with a sealed `credit` session frame per batch of consumed bytes and unconditionally for both channels on every liveness tick; a received `credit` is also what refreshes a peer's liveness while bulk drains. Every routed frame the relay discards comes back as an `error` naming that frame's `channel` and `bytes`, and the sender un-charges them — a lost DATA frame is the one thing a cumulative credit cannot heal. Spec: `docs/protocol/e2e-handshake.md` §8.8. Neither end can read its socket buffer — Bun's client `bufferedAmount` reads 0 even with a gigabyte queued, and dart:io exposes nothing — so never gate on it; what the sender writes is bounded by its own accounting. `sendAppEnvelope`/`sendTunnel` return a `SendOutcome` promise that settles when the message left the queue (written or dropped); `TunnelManager` is the one consumer that awaits it.
- `relay-slot.ts` — re-export of `antgrid-wire`'s slot helpers (one TS copy, shared with the relay). The phone reaches us on a per-machine SLOT (`<accountDeviceUuid>#<machineDeviceUuid>`; see `packages/antgrid_relay_client/CLAUDE.md`). The slot is the ROUTE address — the `sessions`/`pending` map keys, the `phoneEd25519ByDeviceId` key and the capacity check all stay on it, so two devices on one account are two sessions and not a takeover. Everything keyed by the ACCOUNT device uses `baseSlotDeviceId`: both transcripts in `handleClientHello` (the agent one is the HKDF salt — a slot there derives keys the app can't open), the `trustedPeers`/`pairedPhones` lookups in `resolvePhoneEd25519PubB64`/`backfillPeerPubkey`, and the `pairedPhones.upsert` row. Stripping never widens admission — every candidate is still gated by `verifyTranscriptSig`. Presence is filtered by `isForeignSlot`: the relay fans it to every same-account peer, so a sibling slot would otherwise repoint our reply address (`peer-online`) or suppress our heavy stream because another machine's socket closed (`peer-offline`).
- `stream-mux.ts` — multiplexes project cores over the machine socket as sealed `{s, m}` envelopes (`s` absent/`"0"` = machine control plane; the ENVELOPE JSON is what gets fragmented, so `s` survives reassembly). `attachStream(bus, opts)` → `StreamHandle{streamId, detach, sendTunnel}`. **`opts.mayDeliver` is the OUTBOUND authorization hook**, re-read on every bus frame and every `sendTunnel` (tunnel bypasses the bus) — absent means always-deliver, so a caller that answers to a switch must fail closed in its own provider. On each `welcome` the mux re-opens every attached stream, because the relay dropped its `openStreams` on the disconnect. An inbound frame for an unknown streamId is dropped AND answered with a control-plane `stream-invalid {streamId}`: a host restart re-attaches every project under fresh ids, and without that notice the phone replays onto the dead id forever with nothing to trigger a renegotiation. The admission errors, and which a current relay can still send, are documented at their definitions (`ErrorCode` in `packages/antgrid-wire/src/relay-protocol.ts`; the relay side is the Streams bullet in `relay/CLAUDE.md`).
- `host-server.ts` + `paired-phones.ts` — machine-level device trust. `HostServer.startRemoteControlPlane()` owns the single machine RelayClient (bare `deviceUuid`, the only registration shape); project cores attach as streams via `remoteDepsFor(projectId)`. Stream admission publishes `stream-ready {projectId, streamId}`, and `buildProjectsAdvertisement` (`agent:projects`) carries per-project `streamId` so a reconnecting phone binds without a fresh `project:start`; stopped projects start on demand. `startCore` re-advertises unconditionally: an open no phone asked for (restart re-open, desktop-side open) lands AFTER the handshake advert, and nothing else announces it. A rejected verb returns `control:result {ok:false,error}`, never a silent drop. The authorization rule is repo-wide — see **Conventions** in the root `CLAUDE.md` — but three bridge-side details are not. The switch is read live via `remoteAccessEnabled()`, so `mobile-access:set` takes effect without restarting a core (the verbs and `agents/mobile-access-policy.json` keep the old spelling on purpose: both cross a version boundary the rename cannot reach). It gates the stream in BOTH directions — inbound at `remoteFrameAllowed()`, outbound at the stream's `mayDeliver` (`attachRelayStream`) — and inbound alone is not enough, because a project the phone cold-started opens as a `mode:"remote"` core with no `PromotionHandle`, so `demoteAllPromoted()` never touches it and it would keep streaming terminal/tree/git at the phone. Gating at the send rather than at detach is deliberate: the core and its stream stay alive, so flipping the switch back on resumes the same `streamId` with no re-attach and no destroyed work.
- `auth/` — in-memory OAuth (no on-disk store). `credentials.ts` parses one JSON line from stdin into a `BootstrapPayload` (`local | remote`, 10s idle timeout) written by the app on spawn; `oauth-client.ts` mints tokens via `POST /api/auth/oauth2/token` and `startTokenMaintenance` re-mints at 80% of TTL. An `invalid_client` verdict means the cached pair is dead: emit `auth_revoked` to stderr and exit 4 (why that is keyed on the ERROR CODE rather than the status is documented on the callback in `oauth-client.ts`). Two consequences are cross-file and belong here. Credentials reach the host only ONCE, via the stdin bootstrap, so a host left running on a rotated-away pair can never recover on its own — the app respawns it when the account device changes (`local_host_warmup.dart`). And **the boot-time control-plane mint is exempt from the exit** (`fatalRevokeArmed`, disarmed across `start()`'s `startRemoteControlPlane()`): host.json and the ready marker are already out by then, so exiting would have the app's supervisor respawn straight back into the same dead pair — a permanent crash loop that also takes down the loopback plane local work depends on. Boot logs and serves loopback-only; a verdict from token maintenance afterwards is still fatal.
- `crash-reporting.ts` — Sentry (`@sentry/bun`) for the HOST process only, into the same self-hosted errex project as the app. **Consent is the one gate the file cannot state on its own**: it arrives on the stdin bootstrap as `telemetryEnabled`, the app reads the SAME setting that decides its own Sentry init (so one install cannot report from one half and not the other), and its ABSENCE means off — a CLI or test host has nobody who consented. It is fixed for the host's lifetime, which is the same restart-scoped gate the app applies to itself, not an oversight. `SENTRY_DSN` is baked in at build time by `--define`, exactly like `LICENSE_API_URL`; errex issues SLUGS while the JS SDKs require a NUMERIC project id, so the DSN that works for the app does NOT work here. Everything else is documented at its definition in the file: which integrations are excluded and why, why `OnUncaughtException`/`OnUnhandledRejection` are KEPT and what `index.ts` owes them, the scrubber's lockstep with `app/lib/analytics/crash_reporting.dart`, and why the `hook` subcommand is uninstrumented.
- `mcp/server.ts` — the Antgrid MCP server, and it ships as a bridge SUBCOMMAND (`antgrid-bridge mcp`, registered hidden in `index.ts`) rather than as a script an installer points at: the shipped bridge is a compiled single-file executable, so `process.execPath` plus a subcommand is the only self-invocation available — the same shape `worktree-setup` and the hook command use, and `resolveMcpCommand` (`hook-command.ts`) is `resolveHookCommand`'s sibling over one `resolveBridgeCommand`. That is what lets it be INJECTED per spawn, by `augmentAgentLaunch` off each spec's `AgentSpec.mcp`, exactly the way hook configs already are — so a session the app started has the tools with no `antgrid setup` ever run on the machine, and an agent that declares no profile gets none. `plugin/setup.ts` still writes the same `antgrid` entry for a session started OUTSIDE the bridge, and generates it from the same resolver so the two entries cannot desync. Two invariants the code says less loudly than they deserve: stdout is the JSON-RPC transport, so `cli/mcp.ts` moves the root logger to stderr BEFORE the server module loads (pino's default destination is fd 1, and one line there surfaces as an agent-side "server failed to initialize" with nothing in our logs); and `getApiUrl` reads `ANTGRID_API_PORT` from the environment ALONE, with no `api.port` fallback — the per-agent opt-in `HookProfile.portFileFallback` expresses has nothing to key on here, since nothing in the invocation names who spawned it, and the comment there says what a universal one would hand out. The two injected mechanisms are per-agent and measured, never guessed: claude gets `--mcp-config=<abDir>/mcp/claude.json` as ONE token, because the flag is variadic (measured: the separated form reads the next two words as further config paths) and `session-manager.ts` folds the session's own args in directly after it, whose config file must stay OUTSIDE `<abDir>/plugin/claude` (the `--plugin-dir` loader also reads a `.mcp.json` in the plugin tree, and the server would register a second time under a `plugin:<name>:` tool prefix), and never `--strict-mcp-config`, which would drop the user's own servers; codex gets three `-c mcp_servers.antgrid.*` overrides, which merge with the user's servers and feed none of the `hooks.*` fingerprints, so every `trusted_hash` is unchanged by them. Neither entry names a port or a terminal id: claude expands `${ANTGRID_API_PORT}` in the entry's `env` at spawn, and codex — which passes NONE of its own environment down to an MCP server — forwards the two by name through `env_vars`, so one file and one fixed override triple serve every terminal on the machine. The terminal id is what makes that safe rather than merely convenient: the loopback API is per CORE while an isolated session runs in a managed worktree, so the server puts its slot on every request and `api-server.ts` resolves the CALLER's checkout from it (`AgentContext.checkoutFor`, wired to the same `terminalOwner` lookup the message plane routes terminal frames by). A named command is looked up in that checkout's own `antgrid.yaml` and run in its tree, and a terminal belonging to another checkout answers as not found rather than as content — an agent must not run its build against another session's uncommitted work, nor read that session's conversation. Codex CHAT sessions get none of it, because `codexNotifyOnlyArgs` keeps just the `notify=` pair.

## Stopping an agent

Every teardown path asks the agent to leave and then sweeps unconditionally. The
reason the ask exists is external to this repo, so it is stated here: Claude Code
withdraws its `fullscreenBootPending[pid]` canary from `~/.claude.json` in a
`process.on("exit")` hook, and a stale entry silently disables the fullscreen
renderer MACHINE-WIDE, for every project, until the file is hand-edited
(`agents/registry.ts`). Neither `TerminateProcess` nor `SIGKILL` runs one.

The ladder itself is documented at each definition — `TerminalSession.close`
(`terminal-session.ts`), `gracefulBudget` and the same-id respawn's exit
bookkeeping (`terminal-manager.ts`), `AgentSpec.gracefulExit` (`agents/types.ts`),
`snapshotDescendants` / `survivingProcesses` and their null contract
(`win32-process.ts`), `AGENT_GRACE_MS` for how the budgets nest. Chat mode has no
PTY and so no ladder: codex's ask is its stdin closing (`agents/codex/spawn.ts`).

`terminal-graceful-exit.test.ts` gates all of it, and five of its cases PARSE the
source rather than run it — close is not `async` and assigns its tree-kill promise
before any suspension, nothing returns between the grace and the sweep, the grace
is refused unless the sweep is job-backed, and the agents layer takes no runtime
import. Break the shape and a test names the
invariant, which is why the reasoning lives beside the code rather than here.

## The session bus (`src/session-bus/`)

The agent-to-agent plane: one session on one machine reaching another.
`docs/session-messaging.md` is the spec; this is the set of invariants a future
edit breaks silently.

- **Outbound on the machine that opened the exchange goes to the loopback owner
  and nowhere else.** `ProjectCore.sendToOwner` is the only path, and
  `local-listener.ts` hands a bus frame to an owner only if its hello declared
  `capabilities.sessionBusCarrier` (`ownerCarriesSessionBus`, surfaced to the
  loopback API as `carrierPresent`). The desktop app is the carrier; no
  attached carrier means the frame is HELD and retried by the coordinator, never
  dropped, so a closed desktop is an indefinitely delayed exchange rather than a
  failed one.
- **Nothing this side of the relay may be reported as delivery.** The carrier
  taking a frame says only that it left this machine, so a post answers `sent`
  and never "received". The one honest answer is the other side's ack, and
  `session-bus:ack` is a reserved verb nothing on this bridge emits yet — so
  until it is re-keyed to a message id, the only witnesses a frame that goes
  nowhere has are downstream of the send: the RECEIVING coordinator says so when
  a frame names a session that bridge does not hold, and the app says the other
  half (`no leg for addressed member`, `lead project not open`). The sending
  machine has none at all — a carrier that accepts frames and delivers none is
  already silent there, which it was, for three hours, across a restart. Take a
  log line out of either survivor and it is silent in both processes again.
- **An artifact id from the other machine is a reference, not a handle.**
  `coordinator.onFetch` answers a `session-bus:fetch`; nothing sends one, so the
  requester half of cross-machine fetch does not exist. Every surface has to say
  so — `publish_artifact`'s description and the note card — because an id
  offered as fetchable that then is not teaches the reader to distrust the whole
  list.
- **A bus address is matched on machine + session; the project id is a LABEL.**
  `addressesSameSession` (`session-bus/address.ts`) is what `handleInbound`
  gates on, and the carrier matches a session on its id alone
  (`classifyBusFrame`). One checkout can be open as more than one project — a
  managed worktree opened in its own right hashes to an id of its own — so the
  two machines legitimately hold different project ids for the same session, and
  comparing them refused every frame forever over a display string. `sameAddress`
  stays strict and stays correct for a session the app names on this bridge's
  own row: both sides of that comparison come from one record. When the ids do
  differ, both processes say so once (`the other machine addresses session … as
  project …`, and the app's `peer addresses this lead by another project`) —
  routing no longer depends on it, but the row still renders it.
- **Outbound on the machine that is answering is `sendToAppSession(peerId)`,**
  keyed by the app session that carried the exchange in (`busOriginByContext` /
  `noteBusOrigin` in `agent-core.ts`). Falling through to the loopback owner
  would hand the answer to THIS machine's desktop, which accepts it and returns
  true — booking a delivery that never happened and retiring the only outbox
  entry that could retry it. A broadcast would additionally leak the whole
  exchange to the human's phone, which is the mirror of the sending-side
  invariant above.
- **Every delivery into an agent is rendered, and lands at a TURN BOUNDARY.**
  `session-bus/delivery.ts` wraps the other agent's content as fenced data —
  never raw, never a bare instruction — and `delivery-queue.ts` holds the line
  until the turn closes. `DeliveryKindSchema` there is the whole set of queued
  kinds.
- **The Capability Card travels on the address and may only ever be FENCED.**
  It is `SessionMemberCardSchema` on `SessionMemberRefSchema` (`protocol.ts`),
  observed by that machine's own bridge (`capability-card.ts`), and it is what
  answers OS + repo for a machine this bridge can never reach. Its values are a
  hostname and a repo path — precisely what `authorizeInstruction` reads as a
  grant — so no template may put it in a wrapper, and any kind that carries it
  must stay on the `injectReply` path rather than reaching `instruct`.
- **The no-progress halt is `session-bus/task-guard.ts`, and it is per SESSION,
  not per machine** — two agents can trade messages that advance nothing
  forever, and a per-machine ceiling would let one session spend another's
  budget. Nothing counts an exchange into it today: the guard state is
  in-memory and only the human clear is wired, so the ceiling is declared and
  dormant until there is a notion of progress on a message plane to feed it.
- **`/session-bus/*` in `api-server.ts` is the loopback route table**, keyed off
  `?terminalId=` — which is what says whose session a request is about, and the
  same slot that resolves an isolated session's checkout. Bus frames route by
  `sessionId` on the project stream, so nothing here carries a `checkoutId` (the
  comment above `session:setup` in `protocol.ts` is the standing reason).

Known gaps, stated rather than papered over: a codex CHAT session gets no MCP
server at all (`codexNotifyOnlyArgs`), so nothing in it can reach the bus; and
artifacts (`session-bus/artifact-store.ts`) are session-scoped with no
cross-context fetch and nothing that reclaims them.

## The MCP subcommand

`src/mcp/server.ts` and its `antgrid-bridge mcp` entry are described under
**Adding an agent** (the `mcp/server.ts` bullet): how it is self-invoked, how
`augmentAgentLaunch` injects it per spawn from `AgentSpec.mcp`, and why stdout
and `ANTGRID_API_PORT` are what they are. One thing the session bus adds to it:

- **A tool is DISPATCHED by name, not by whether this process believes the call
  can succeed.** The server holds one tool table and evaluates nothing about the
  caller, so a call it cannot answer must still reach the bridge and be refused
  there — the refusal is the bridge's to author, never the server's to guess.

## Isolated sessions (`src/worktrees/`)

The routing model — which message types carry a `checkoutId`, and the app-side set
they are mirrored into by hand — is in `docs/architecture.md`. This is the
host-side lifecycle: what owns what, and where each invariant is written down.

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

The rest of the lifecycle is a set of named invariants, each documented at its
own definition and each gated by a test that fails when you break it. Named here
so you know they exist; read the reasoning where it lives.

`worktree-manager.ts` — **nothing deletes a directory it has not proved is its
own** (two projects can share a worktree root; both sweeps gate on
`readCheckoutOwner`, and reclaim removes recorded paths one at a time, never a
blanket `rm`); **`git worktree remove` is the point of no return** and nothing
after it may throw, which is why a kept branch is logged rather than raised and
why `inspect` reads rev-list's EXIT CODE; **a delete Git cannot finish, Antgrid
finishes itself** (`reclaimOwnedPath`, guarded on the path being under
`<abDir>/wt/`, never on store metadata); **naming a holder is why that failure
has its own code** — `WORKTREE_DELETE_HELD` must never gain a
`friendlyErrorCopy` arm in the app or the clause goes silent; **eviction is
wired only into the explicit delete**, never the reconcile sweep; **reconcile
may only DELETE on a complete store read**, and **a row whose worktree is gone
must be pruned** (`isStranded` needs both signals). Gated by
`worktree-shared-root`, `worktree-reclaim`, `worktree-reconcile` and
`worktree-manager-failures`.

`session-manager.ts` — **the dirty/unpushed refusal is duplicated on purpose and
must stay in lockstep** with `WorktreeManager.removeNow`, which closes the race
under the project lock; the cold path (`HostServer.deleteColdSession`) has no
preflight and leans entirely on the manager's copy. **A delete is advertised and
refuses**: `SessionManager.deleting` is one in-memory set feeding both the wire
flag and `isCheckoutDeleting`, and its three orderings are load-bearing. Gated by
`session-delete-in-flight`.

**Runtime teardown precedes `git worktree remove`, always, and must take whole
process TREES with it** — Windows walks parent links so the tree kill must be
issued before the leader dies, POSIX needs `processGroupSpawn()` as a
precondition, and orphans are reached only by the kill-on-close job assigned the
instant a pid exists. `terminal-session.ts` (`killProcessTree`),
`win32-process.ts`, and **Stopping an agent** above.

Two more are documented at their definitions and hold no trap worth restating:
`main` is synthesized and never persisted (`checkout-runtime-registry.ts`,
`checkout-types.ts` for the two distinct kind questions), and a rollback is not a
delete (`rollbackPrepared`).
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
  `services` block ALONE — watchers, port detection and tunnels still start.
  Auto-starting `bun run dev` against an empty `node_modules` is a guaranteed
  failure the user then has to read past. The deferral and the run are taken
  TOGETHER or not at all, so `runCheckoutSetup` MUST report exactly one of
  `done`/`failed`/`skipped` for every run it is handed — a runner that returned
  nothing leaves that checkout with no services at all. The gate, the empty-steps
  case and the create-reply ordering are on `checkoutSetupPolicy`
  (`session-manager.ts`) and in `checkout-setup.ts`.

The rest of the lifecycle is documented at its definitions and gated by
`checkout-setup.test.ts`: **a `running` state is never persisted** and
`interrupted` is DERIVED from a marker's absence, gated on the checkout still
declaring a block (`DURABLE_SETUP_STATES` in `checkout-types.ts`,
`checkoutSetupPolicy` and the recovery loop in `session-manager.ts`); **the setup
PTY stays in `configuredTerminalIds`** or a Windows delete breaks on its open
handle, and `agent-core`'s `setupTerminalIds` is what still identifies it after
`finish()` has dropped the run; **`suppressOscTitle` must never be set on it**
because step transitions ride the OSC 2 channel that flag suppresses
(`checkout-setup.ts`), while `suppressOscNotifications` IS set.

Three couplings reach into `app/` and so are gated by nothing on this side:
- The setup PTY carries no `type`, which is not the same as hidden — the app's
  ad-hoc list selects by EXCLUDING `agent` and `service`, so `terminal_list_view.dart`
  must keep dropping every id a session's `setup.terminalId` claims, or the user
  gets an interactive tab over a live `bun install` with a close button.
- Its owner row in `terminalOwners` SURVIVES its exit, unlike every other
  terminal's: `sendStatus` routes by that row, so dropping it prunes the
  transcript the banner's "View setup log" reads — exactly when the run failed.
- **The start gate lives on the bridge, in memory.** A `session:start` during a
  run records `pendingStart` (with its `initialPrompt`) and replies `ok: true`; a
  start carrying NO prompt never clears one already queued, because the app gates
  its auto-start paths on `sessionStartQueued` and this is the backstop for the
  path that forgets to. The queue is not the app's so a user who creates a
  session on a phone and locks the screen comes back to a running agent. The
  prompt is never persisted. `session:setup` (`skip`/`cancel`/`rerun`) is the
  only verb over it.
