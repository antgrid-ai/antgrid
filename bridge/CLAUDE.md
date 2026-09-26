# Bridge (`bridge/src/`)

Deep reference for the bridge. Root `CLAUDE.md` holds the repo-wide gotchas,
commands, and conventions — this file loads only when working under `bridge/`.

What may be written in any `CLAUDE.md`, this one included, is governed by
*Maintaining these files* in the root `CLAUDE.md`.

## Agent adapters

Agent definitions and runtime live in the ELv2 workspace package
`packages/antgrid-agents`. Its `src/agents/registry.ts` is the built-in registration
entry point; `src/contracts.ts` and `package.json` describe the public interface.
Bridge imports public package exports only. Provider invocation, storage knowledge,
hooks, and SDK behavior belong in the package; bridge owns authorization, checkout
selection, process containment, transport, and session persistence.

Compose the registry and host services in `src/agent-host.ts`; bridge consumers
use `src/agent-runtime.ts` for the resulting runtime.
Hook command resolution stays in bridge because development and compiled entrypoints
differ. Provider assets are embedded and materialized by `antgrid-agents/assets`;
external agent runtimes require real files, not paths inside Bun's executable.

The tools advertisement still separates installed `tools[]` from the full
`agents[]` catalog. The app uses the catalog to describe agents without a matching
local probe. Keep persisted provider IDs and hook aliases stable across releases;
hook aliases are part of existing trusted command fingerprints.

Handler support and runtime readiness travel separately: the session fields in
`src/protocol.ts` are mirrored in `app/lib/models/handler_state.dart`. Preserve
missing availability for older peers instead of interpreting it as unsupported.

Run package tests as well as bridge tests when changing adapters:
`bun run --filter antgrid-agents test` and
`bun run --filter antgrid-agents typecheck`.

## Component map

`peer-session-owner.ts` owns peer session establishment.
`central-control-client.ts` owns signed central authentication, presence,
policy invalidation and encrypted push delivery. It has no binary payload API and
cannot reset native payload sessions. `peer/native-host-connection.ts` composes
these boundaries with `peer/endpoint-lifecycle.ts` and preserves remote
command source semantics. Project readiness is host-local; the central socket
has no stream registration or payload frames.
The controller and local bridge retain distinct protected enrollment records;
endpoint seeds must never be written to an ordinary bridge file. Native
platform qualification lives in `docs/iroh-qualification.md`.
Desktop lifecycle resume notifies the existing host through owner-bearer
`POST /peer-resume` (`control-listener.ts`), with no body; its 202 acknowledges
synchronous remote-session fencing, while authorization refresh runs separately.
Keep that contract mirrored in the app's `HostControlClient` lifecycle caller.

What each area owns. Mechanism lives at the definitions in the files themselves;
what is here is identity plus the contracts that span more than one of them.

- `config.ts` — Zod schemas for `antgrid.yaml`; var interpolation (`${project.path}`, `${env.VAR}`).
- `protocol.ts` — message types as Zod discriminated union. `createMessage()`, `parseMessage()`/`parseMessageFast()`.
- `terminal-manager.ts` → `terminal-session.ts` — PTY lifecycle; manager coordinates multiple sessions. On Windows each PTY also joins a kill-on-close job (`win32-process.ts`); the invariants are under **Isolated sessions**, because what they protect is a checkout delete. `terminal-frames/source.ts` owns the authoritative VT, `delivery.ts` owns subscriptions and acknowledgments, and `history.ts` persists indexed scrollback. The app's frame application and paged-history models mirror their protocol; raw output remains bridge-internal. Both components must upgrade together: an unsupported terminal version requires an upgrade, never raw-stream fallback. Cross-engine compatibility is gated by `app/test/terminal_frame_prototype_test.dart`, also executed by desktop packaging; the bridge suite alone cannot qualify Ghostty behavior. Terminal qualification commands live in `bridge/package.json` and `evals/package.json`.
- `work-status.ts` — pure fold from outbound bus frames (+ the inbound turn-start/answer hooks) to PER-SESSION work status; `ProjectCore.workStatus` is only its rollup. **This is the ONLY per-session reduction** — `SessionManager` folds nothing, it stamps this one's answer onto each `session:updated` entry via the injected `sessionWorkStatusFor`, and `ProjectCore.commitWork` calls `refreshSessionWork()` when the per-session map moves. That re-emit folds straight back in, so it terminates *only* because `foldSessions` returns the SAME state for an unchanged session set — keep that discipline. **Presence of `sessionStatuses` is the app's capability signal**: `{}` means "warm, nothing running", absent means an older bridge, so never omit it for a warm core. Read state is tracked PER CLIENT (keyed by `InboundSource`) and fed by three inbound signals — `sessionFocus`, `clientFocusState`, and `clientGone` (`onPeerOffline` for the phone, `LocalListener.onOwnerDisconnected` for the desktop). Nothing persists it on either side, and `app_shell.dart` must keep skipping `unread` when writing the status cache. The reasoning behind each rule is on the declarations in the file.
  - `/turn-start` hook (Claude only) → `turnStart`: clears the block AND opens a turn.
  - chat resolve (`agent:permission-resolve`/`-question-resolve`) → `answerRequest`: same, but ONLY if something was actually pending — a resolve racing a retraction would otherwise open a turn no turn-end closes.
  - bare PTY keystroke → `userReply`: clears the block only. Typing in an idle session is not work.
  - PTY keystroke that SUBMITTED (`isSubmitKeystroke` in `keystrokes.ts`: a trailing CR, but not `\x1b\r` — alt+enter inserts a newline and may never be sent) → `userReply({submitted:true})`: also opens a turn, but only for a session in `keystrokeTurnSessions` — an agent with turn-END hooks and no turn-start (codex/cursor/copilot; see `needsKeystrokeTurnStart` in `packages/antgrid-agents/src/agents/registry.ts`, which reads it off each agent's own `hooks.turnBoundaryEvents`). Never for Claude (it has a real signal) nor for the hookless agents (opencode/antigravity/kilo/kimi/mistral-vibe — nothing would close the inferred turn).

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
- `tunnel-manager.ts` — maps ports→preview URLs; only emits `preview:url` for proxies with `browser: true`. An unchanged entry is not re-pushed, so anything recorded while `connState.suppressed` is ALSO tracked in `undelivered` and re-pushed on the next unsuppressed pass; the app's `PreviewService` registers a `preview:snapshot:request` hydrator per checkout, which is how a checkout whose bundle is built after the connect-time replay learns its ports at all. HTTP-proxy and browser-WebSocket preview traffic never rides the bus — each request/response and each WebSocket gets its own QUIC stream, admitted by `TunnelStreamRegistry` (`peer/tunnel-streams.ts`) and exposed to it as `TunnelStreamServer`/`TunnelAdmission` (`docs/protocol/peer-session.md` §1c has the wire shape; `AgentCore.tunnelStreams.admit` the admission order). `TunnelManager.serveHttp`/`serveWs` are called directly per stream and know nothing about streams themselves: bodies are raw bytes; a FIN is a clean end, a reset an aborted one, and the reader/writer pair is the only pacing (no credit window on this stream, and no permessage-deflate layer to lean on, so the app must compress it itself or not at all). Bun buffers the upstream body regardless of read pace — pacing bounds the send queue, not RSS. Cancel is the app resetting or FIN-ing its own send half, which `TunnelStreamRegistry` observes as a failed pending read and treats as cancel — aborting the fetch or WS in turn; every in-flight run belonging to ONE peer is also aborted when that peer's session ends (`abortHttpStreams(peerId)`, driven only from `project-core`'s `onPeerSessionGone` hook, not from `onPeerOnline`/`onPeerOffline`, so a second phone establishing does not abort a first phone's in-flight preview load). Aborting the fetch's signal is what closes the upstream on Bun; `reader.cancel()` alone does not. **The bridge, not the phone, is the authority on a port's scheme**, and the self-signed-cert exemption applies to the WebSocket upstream as well as to fetch. Everything else is documented at its own definition in the file: the `vite-hmr` subprotocol negotiation, the forwarded handshake headers, and why `openUpstream` must catch.
- `file-watcher.ts` → `file-tree.ts` — Chokidar watching with .gitignore support.
- `file-search.ts` — ripgrep when present, else `git grep --untracked`. Both are handed the abDir as an exclude, and it is load-bearing rather than cosmetic: every managed worktree lives under it, so a project root that CONTAINS the state dir would otherwise report the isolated checkouts' files as main's own hits. The exclusion is anchored at the search root (ripgrep leans on the spawn's `cwd` for that) and dropped when it does not lie inside — a searcher rooted at a worktree sits under the state dir and must not anchor an exclude at its own ancestor.
- `worktrees/` — managed checkouts for isolated sessions: Git lifecycle (`worktree-manager.ts`), the durable record (`checkout-store.ts`), repository identity (`project-resolver.ts`). See **Isolated sessions** below.
- `key-exchange.ts` — the X25519 ECDH primitive behind `push/seal.ts` (per-push sealing to the phone's push pubkey). The peer payload path carries no app-layer sealing of its own, since QUIC/TLS between authorized Iroh endpoints is its confidentiality layer — see `docs/protocol/peer-session.md` for that session protocol.
- `central-control-client.ts` owns the machine control WebSocket. A single signed v3 `hello` authenticates it; `welcome` alone resets backoff. It carries presence, policy invalidation, heartbeat and encrypted push delivery only. `SUPERSEDED` is terminal for that central socket and never tears down an authoritative native lease or reports auth revocation.
- `peer-session-owner.ts` + `peer/native-host-connection.ts` own Iroh payloads and session establishment; `project-streams.ts`'s `ProjectStreamRegistry` (constructed in `peer-session-owner.ts`'s constructor, `this.projectStreams`) owns the host-local project bindings themselves. The session stream's I/O is the same `StreamRecordWriter`/`StreamRecordReader` pair as every other stream: one JSON record per frame, dispatched on its own `type` (`receiveSessionRecord`, `peer-session-owner.ts`) — a `session:*` type is a session frame, anything else is one `AbMessage` of the control plane. Central reconnects and presence changes cannot close or establish native sessions — a live session has no in-place rekey (`docs/protocol/peer-session.md` §3): a dead peer surfaces as the Iroh connection's `closed()` (QUIC idle), which retires the peer, and the bridge never pings. Host resume and authorization recheck are required capabilities of every `RemoteHostConnection`.
- `relay-slot.ts` — re-export of `antgrid-wire`'s slot helpers (one TS copy, shared with the relay). The phone reaches us on a per-machine SLOT (`<accountDeviceUuid>#<machineDeviceUuid>`; see `packages/antgrid_relay_client/CLAUDE.md`). The slot is the ROUTE address — the `sessions` map key, the `phoneEd25519ByDeviceId` key and the capacity check all stay on it, so two devices on one account are two sessions and not a takeover. Everything keyed by the ACCOUNT device instead uses `baseSlotDeviceId`: the authorization-lease lookups in `acceptPeer`/`authorized` (`peer/native-host-connection.ts`) and the `pairedPhones` upsert/`touchLastSeen` in `admitPeer` (`peer-session-owner.ts`) — stripping the slot never widens admission, since the lease itself is still keyed by endpoint ID (`docs/protocol/peer-session.md` §1). The relay's own `peer-online`/`peer-offline` presence fan-out is no longer consulted for anything (no handler is wired to it in `native-host-connection.ts`): a native peer's online/offline state is derived from that peer's own Iroh session lifecycle (`ProjectStreamRegistry.notifyPeerOnline`/`notifyPeerOffline`), so a sibling account slot's connect/disconnect on the relay can no longer repoint our reply address or suppress our stream.
- `project-streams.ts` — gives each project its OWN native QUIC bidi stream: a project record carries no session-stream wrapper, and the session stream itself carries only machine control-plane frames. `ProjectStreamRegistry.attach(bus, opts)` returns `StreamHandle{detach, sendTo, deliverableTo, terminalHooks?}` — no host-minted id, because the stream itself (admitted by `projectId` off the open frame) is the binding. **`opts.mayDeliver` is the OUTBOUND authorization hook**, re-read on every bus frame, so callers controlled by a policy switch must fail closed. `stream-ready {projectId}` is BOTH the Hazard-J ready notice on the session stream (gates the app's project-stream open: too-early is refused in-band `NOT_READY`, never parked) AND the bridge's own first record on an admitted project stream, which is what makes the bind itself observable — there is no separate ack. An admitted stream that overflows resets only that stream (the app reopens and resyncs); an app record over the stream's cap is a protocol violation, and that or a peer proven unauthorized retires the whole connection. Tunnel (preview) traffic carries no bus frames — it rides its own per-exchange QUIC streams (`docs/protocol/peer-session.md` §1c) — so `attachStream`'s `opts.tunnels` (a `TunnelStreamServer`) and `projectBinding(projectId)` are how `TunnelStreamRegistry` reaches a project's admission and outbound-authorization hooks. `peer/upload-streams.ts`'s `UploadStreamRegistry` is the same shape: a remote file upload rides its own `upload` stream rather than the project stream's bus frames, and `attachStream`'s `opts.uploads` plus the same `projectBinding` are its admission and delivery hooks. All three stream registries admit through one `gateProjectStream` (`peer/stream-dispatch.ts`).
- `host-server.ts` + `paired-phones.ts` — machine-level device trust. `HostServer.startRemoteControlPlane()` owns the single machine `NativeHostConnection` (bare `deviceUuid`, the only registration shape); project cores attach as streams via `remoteDepsFor(projectId)`, which is now a thin passthrough to `ProjectStreamRegistry.attach` — no per-project id to allocate or track (A4). Project readiness publishes `stream-ready {projectId}` on the session stream (Hazard J: the app's project-stream open is refused in-band `NOT_READY` before this arrives), and `buildProjectsAdvertisement` (`agent:projects`) still lists every dialable project so a reconnecting phone knows what it may open a stream for; stopped projects start on demand. `startCore` re-advertises unconditionally: an open no phone asked for (restart re-open, desktop-side open) lands AFTER the handshake advert, and nothing else announces it. A rejected verb returns `control:result {ok:false,error}`, never a silent drop. The authorization rule is repo-wide — see **Conventions** in the root `CLAUDE.md` — but three bridge-side details are not. The switch is read live via `remoteAccessEnabled()`, so `mobile-access:set` takes effect without restarting a core (the verbs and `agents/mobile-access-policy.json` keep the old spelling on purpose: both cross a version boundary the rename cannot reach). It gates the stream in BOTH directions — inbound at `remoteFrameAllowed()`, outbound at the stream's `mayDeliver` (`attachRelayStream`) — and inbound alone is not enough, because a project the phone cold-started opens as a `mode:"remote"` core with no `PromotionHandle`, so `demoteAllPromoted()` never touches it and it would keep streaming terminal/tree/git at the phone. Gating at the send rather than at detach is deliberate: the core and its stream stay alive, so flipping the switch back on resumes delivery with no re-attach and no destroyed work.
- `auth/` — in-memory OAuth (no on-disk store). `credentials.ts` parses one JSON line from stdin into a `BootstrapPayload` (`local | remote`, 10s idle timeout) written by the app on spawn; `oauth-client.ts` mints tokens via `POST /api/auth/oauth2/token` and `startTokenMaintenance` re-mints at 80% of TTL. An `invalid_client` verdict means the cached pair is dead: emit `auth_revoked` to stderr and exit 4 (why that is keyed on the ERROR CODE rather than the status is documented on the callback in `oauth-client.ts`). Two consequences are cross-file and belong here. Credentials reach the host only ONCE, via the stdin bootstrap, so a host left running on a rotated-away pair can never recover on its own — the app respawns it when the account device changes (`local_host_warmup.dart`). And **the boot-time control-plane mint is exempt from the exit** (`fatalRevokeArmed`, disarmed across `start()`'s `startRemoteControlPlane()`): host.json and the ready marker are already out by then, so exiting would have the app's supervisor respawn straight back into the same dead pair — a permanent crash loop that also takes down the loopback plane local work depends on. Boot logs and serves loopback-only; a verdict from token maintenance afterwards is still fatal.
- `crash-reporting.ts` — Sentry (`@sentry/bun`) for the HOST process only, into the same self-hosted errex project as the app. **Consent is the one gate the file cannot state on its own**: it arrives on the stdin bootstrap as `telemetryEnabled`, the app reads the SAME setting that decides its own Sentry init (so one install cannot report from one half and not the other), and its ABSENCE means off — a CLI or test host has nobody who consented. It is fixed for the host's lifetime, which is the same restart-scoped gate the app applies to itself, not an oversight. `SENTRY_DSN` is baked in at build time by `--define`, exactly like `LICENSE_API_URL`; errex issues SLUGS while the JS SDKs require a NUMERIC project id, so the DSN that works for the app does NOT work here. Everything else is documented at its definition in the file: which integrations are excluded and why, why `OnUncaughtException`/`OnUnhandledRejection` are KEPT and what `index.ts` owes them, the scrubber's lockstep with `app/lib/analytics/crash_reporting.dart`, and why the `hook` subcommand is uninstrumented.
- `mcp/server.ts` — the Antgrid MCP server, and it ships as a bridge SUBCOMMAND (`antgrid-bridge mcp`, registered hidden in `index.ts`) rather than as a script an installer points at: the shipped bridge is a compiled single-file executable, so `process.execPath` plus a subcommand is the only self-invocation available — the same shape `worktree-setup` and the hook command use, and `resolveMcpCommand` (`hook-command.ts`) is `resolveHookCommand`'s sibling over one `resolveBridgeCommand`. That is what lets it be INJECTED per spawn, by `augmentAgentLaunch` off each spec's `AgentSpec.mcp`, exactly the way hook configs already are — so a session the app started has the tools with no `antgrid setup` ever run on the machine, and an agent that declares no profile gets none. `plugin/setup.ts` still writes the same `antgrid` entry for a session started OUTSIDE the bridge, and generates it from the same resolver so the two entries cannot desync. Two invariants the code says less loudly than they deserve: stdout is the JSON-RPC transport, so `cli/mcp.ts` moves the root logger to stderr BEFORE the server module loads (pino's default destination is fd 1, and one line there surfaces as an agent-side "server failed to initialize" with nothing in our logs); and `getApiUrl` reads `ANTGRID_API_PORT` from the environment ALONE, with no `api.port` fallback — the per-agent opt-in `HookProfile.portFileFallback` expresses has nothing to key on here, since nothing in the invocation names who spawned it, and the comment there says what a universal one would hand out. The two injected mechanisms are per-agent and measured, never guessed: claude gets `--mcp-config=<abDir>/mcp/claude.json` as ONE token, because the flag is variadic (measured: the separated form reads the next two words as further config paths) and `session-manager.ts` folds the session's own args in directly after it, whose config file must stay OUTSIDE `<abDir>/plugin/claude` (the `--plugin-dir` loader also reads a `.mcp.json` in the plugin tree, and the server would register a second time under a `plugin:<name>:` tool prefix), and never `--strict-mcp-config`, which would drop the user's own servers; codex gets three `-c mcp_servers.antgrid.*` overrides, which merge with the user's servers and feed none of the `hooks.*` fingerprints, so every `trusted_hash` is unchanged by them. Neither entry names a port or a terminal id: claude expands `${ANTGRID_API_PORT}` in the entry's `env` at spawn, and codex — which passes NONE of its own environment down to an MCP server — forwards the two by name through `env_vars`, so one file and one fixed override triple serve every terminal on the machine. The terminal id is what makes that safe rather than merely convenient: the loopback API is per CORE while an isolated session runs in a managed worktree, so the server puts its slot on every request and `api-server.ts` resolves the CALLER's checkout from it (`AgentContext.checkoutFor`, wired to the same `terminalOwner` lookup the message plane routes terminal frames by). A named command is looked up in that checkout's own `antgrid.yaml` and run in its tree, and a terminal belonging to another checkout answers as not found rather than as content — an agent must not run its build against another session's uncommitted work, nor read that session's conversation. Codex CHAT sessions get none of it, because `codexNotifyOnlyArgs` keeps just the `notify=` pair.

## Stopping an agent

Every teardown path asks the agent to leave and then sweeps unconditionally. The
reason the ask exists is external to this repo, so it is stated here: Claude Code
withdraws its `fullscreenBootPending[pid]` canary from `~/.claude.json` in a
`process.on("exit")` hook, and a stale entry silently disables the fullscreen
renderer MACHINE-WIDE, for every project, until the file is hand-edited
(`packages/antgrid-agents/src/agents/registry.ts`). Neither `TerminateProcess` nor `SIGKILL` runs one.

The ladder itself is documented at each definition — `TerminalSession.close`
(`terminal-session.ts`), `gracefulBudget` and the same-id respawn's exit
bookkeeping (`terminal-manager.ts`), `AgentSpec.gracefulExit` (`packages/antgrid-agents/src/agents/types.ts`),
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
  failed one — on every path except the agent-initiated verbs, which read
  `carrierPresent` up front and refuse `PEER_UNREACHABLE`
  (`session-bus/api.ts`) rather than report a held frame to an agent that reads
  every answer but a refusal as delivered.
- **The remote half of the directory arrives by loopback push and by nothing
  else.** The app peeks at control-plane sessions it already holds, asks each
  machine for a session-bearing `machine.capability-card`, and pushes the
  answers to the `session-bus:remote-directory` control verb. Never give it a
  relay-side arm: `bus.setInboundHandler` accepts frames from any
  account-trusted peer while the machine switch is on, so a directory verb
  reachable there lets a phone write rows a local agent then reads as peers.
  Mirrored rows are re-validated on arrival and decay on a TTL
  (`REMOTE_ROWS_TTL_MS`, `session-bus/constants.ts`) rather than persisting,
  because a bridge cannot dial another bridge and so can never ask again — and
  the near end proves a carrier exists by having been pushed to, not by a
  capability flag Zod could strip in silence.
- **Nothing this side of the relay may be reported as delivery.** The carrier
  taking a frame says only that it left this machine, so a post answers `sent`
  and never "received". The one honest answer is the other side's ack: the
  receiving coordinator emits a `session-bus:ack` keyed to the message id for
  every post and notify it folds, and the sender stamps it onto its own log
  entry. An unstamped entry is not a failed one — a receipt is fire-and-forget
  and an unacked one is never retried — so the witnesses a frame that goes
  nowhere has still carry the weight: the RECEIVING coordinator says so when
  a frame names a session that bridge does not hold, and the app says the other
  half — `no leg for addressed member` when the address was good and the machine
  was not there, and `refused bus frame` with a `because` field naming the fact
  it did not have. The sending machine has none at all — a carrier that accepts
  frames and delivers none is already silent there, which it was, for three
  hours, across a restart. Take a log line out of either survivor and it is
  silent in both processes again.
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
  project …`, and the app's `this app holds the session under a project the
  other machine does not address it by`) — routing no longer depends on it, but
  the row still renders it.
- **One coordinator now answers for every project a host has open (E9/§5.4),
  which is what makes the invariant above load-bearing rather than academic:**
  a peer admitted onto ANY project's stream can apply a frame naming a session
  in any OTHER project this machine holds, because `addressesSameSession` was
  always machine+session and never machine+session+project. What still bounds
  that — and what does NOT, which is the half worth writing down — is named
  here so it is a decision rather than something discovered later.
  `remoteFrameAllowed` (`agent-core.ts`, gate applied once per inbound frame in
  `attachTransport`, before dispatch) refuses every relay-origin frame while the
  machine's mobile-access switch is off; that switch is machine-wide, so it
  bounds the widened address space exactly as it bounded the narrow one —
  loopback is exempt, but a loopback caller is this machine's own desktop,
  already trusted with every session on it. A session id is
  `crypto.randomUUID()` (`session-manager.ts`), so naming one is guessing a
  UUID, never enumerating a small keyspace. Isolation among the projects one
  host has open rests on the admission rules that remain: a peer must open
  each project's own stream before it may address a session on it
  (`mayAcceptFrom` at open, `mayDeliverTo` on every send —
  `ProjectStreamRegistry`, `project-streams.ts`), and that stream open is
  itself gated on `seenProjects` and `isSafeProjectId`. The carrier
  route table is keyed by CONTEXT id alone, so the same already-admitted peer
  can re-point another project's context at itself by stamping that context id
  on a frame addressed to a session it may legitimately name — refusing the
  mismatch at `noteRoute` is not the fix, because E9's own case (a worktree
  session answering its parent) is that mismatch, and the two are
  indistinguishable there. Net: WHO may
  address this machine is unchanged (an account-trusted peer, mobile access on,
  on a project in the host's catalog); what an already-admitted peer may NAME
  once inside is every session in a project it has opened a stream for.
- **Outbound on the machine that is answering is `sendToAppSession(peerId)`,**
  keyed by the app session — and, since the route table moved onto the
  coordinator itself (E9/§5.4), the PROJECT — that carried the exchange in
  (`SessionBusCoordinator.noteRoute`/`routeFor`, `session-bus/coordinator.ts`).
  Falling through to the loopback owner
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
- **The no-progress halt is per (sender, target) PAIR** — two agents can trade
  messages that advance nothing forever; a per-machine ceiling would let one
  session spend another's budget, and a per-session one would let a halted pair
  carry on through a third. `session-bus/pair-budget.ts` is pure and the host
  holds the one store (beside the directory), because a halt "cleared only by a
  human" has to outlive a restart. The record is MIRRORED per end, never shared:
  the two ends can be on two machines, so each charges its own copy — outbound in
  `SessionBusCoordinator.message`, inbound in its `onMessage` — and an edit that
  drops either half leaves each end counting only what IT sent, which doubles
  both ceilings and halts one side of a pair without the other. REFUSAL stays in
  `message` alone, the single point every verb leaves through; a gate in the
  loopback API or the MCP tools instead would be one a new caller could be
  written around without noticing. A caller may ASK the same
  question read-only through `SessionBusCoordinator.pairRefusal`, which charges
  nothing and exists so the verb layer can order its own ladder (a halted pair
  aimed at a stopped session has to hear about the halt, which only a human
  lifts). It never replaces the check inside `message`.
- **`/session-bus/*` in `api-server.ts` is the loopback route table**, keyed off
  `?terminalId=` — which is what says whose session a request is about, and the
  same slot that resolves an isolated session's checkout. Bus frames route by
  `sessionId` on the project stream, so nothing here carries a `checkoutId` (the
  comment above `session:setup` in `protocol.ts` is the standing reason).

Known gaps, stated rather than papered over: a codex CHAT session gets no MCP
server at all (`codexNotifyOnlyArgs`), so nothing in it can reach the bus; and
artifacts (`session-bus/artifact-store.ts`) are session-scoped with no
cross-context fetch, and are reclaimed only by the delete of the session that
published them — nothing bounds them by age or total size while it lives.

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
