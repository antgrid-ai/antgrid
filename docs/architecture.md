# Architecture reference

Background detail pulled out of the root `CLAUDE.md`. The per-component
`CLAUDE.md` files are the authority for their own subsystems; this file holds
only the cross-cutting shape.

## Message flow

Remote payloads use Iroh; QUIC/TLS 1.3 between two endpoint IDs the
authorization snapshot names is the confidentiality layer, with no app-layer
sealing on top of it and no application-level WebSocket fallback. The central
WebSocket remains for discovery, presence and revocation. See
[`docs/protocol/peer-session.md`](protocol/peer-session.md) for the
session hello, stream admission and the stream catalogue.

```
App (Flutter) <--QUIC/TLS over Iroh (direct or relayed)--> Agent (Bun)
```

The central relay authenticates devices via a signed `hello` frame (Ed25519
proof-of-possession) — unrelated to peer payload admission, which is decided
entirely by the authorization lease (`docs/protocol/peer-session.md` §1). The
session stream carries the hello, the app's wedge-probe `session:ping`, and
machine-scoped verbs such as `agent:projects` and `stream-ready` — QUIC
keep-alive/idle is the liveness layer (`docs/protocol/peer-session.md` §3);
every project gets its own stream (`docs/protocol/peer-session.md` §1d),
carrying that project's bus traffic — session-bus frames, `preview:url`, and
so on — as bare records with per-record caps (§5). Terminal attachments, tunnel exchanges and remote file
uploads get their own streams in turn (§1b, §1c, §1e): the HTTP-proxy and
browser-WebSocket preview traffic rides its own per-exchange QUIC stream — one
stream per HTTP request/response and one per WebSocket's lifetime — with a
request or response body carried as raw bytes rather than a bus frame (only a
WS frame is still a tagged record, since one stream multiplexes many of them).
A remote file upload rides its own stream the same way: the app writes the
file's raw bytes directly, with no bus frame and no app-layer chunking, and
the bridge answers with one result record. The desktop app's own local
upload writes the bytes to a temp file on the shared filesystem instead —
it crosses the loopback socket as one `file:upload-local` message
(`bridge/src/protocol.ts`) naming that path, and gets back one
`file:upload-result`.

### Native peer payloads

The authenticated central WebSocket retains inventory, presence and policy
invalidation. The Apache Dart `PeerLink` interface separates that control
connection from payload lifecycle. `MachineSession` and the session-hello driver
consume the native link; feature services retain their existing interfaces.
Native implementation and authoritative lease handling live in the ELv2
`packages/antgrid_peer_transport` package, shared with its standalone CLI smoke.

The bridge's `PeerSessionOwner` owns session establishment over Iroh, not
liveness; each stream writes bare length-prefixed records with its own
per-record caps (`docs/protocol/peer-session.md` §5). `CentralControlClient` owns central
authentication, presence, policy invalidation and push delivery; it has no
binary payload API. `NativeHostConnection` composes those independent owners
with endpoint lifecycle recovery for authenticated native connections. Native
requests keep remote command authorization, project catalog checks and
checkout routing. Host-assigned stream readiness is independent of central
stream admission, allowing native project use during a leased central outage.

Each enrollment has a distinct protected endpoint seed. Device-bound OAuth
credentials authorize challenge, dual-signature registration and snapshot APIs
under `/account/devices/me/`. Registrations retain history and decimal-string
generations. Snapshots supply entitlement, peer signing keys, endpoint identities
and approved relay origins. Active leases refresh every 20 seconds and expire no
later than 60 seconds from monotonic request start. Dispatch and queued writes
recheck authorization; revocation closes affected sessions. Transactional policy
outbox delivery informs connected clients and configured private relay targets.

An app-initiated Iroh connection is reused across projects. ALPN
`antgrid/peer/2` admits multiple native bidirectional streams. Every stream opens
with one `[u32 BE len][UTF-8 JSON StreamOpen]` record; the first stream on a
connection must declare `{kind:"session"}` and then carries the existing route
frames (peer frames with a four-byte big-endian length prefix) unchanged — an
invalid or non-session first open closes the connection, since there is no
session yet to keep alive. Every later stream is admitted in its own task by
`PeerStreamAcceptor` (`bridge/src/peer/stream-dispatch.ts`), enforcing a
pending-open cap and a 5s open-frame deadline before dispatching by `kind`; a
refusal is in-band (`stream:refused` then FIN), a missed deadline resets that
stream, and neither costs the connection. See `docs/protocol/peer-session.md` §1a
for the admission order and refusal codes. Transport selection precedes the
session hello and is fenced by attempt generation; the app's
`ConnectionSupervisor` remains the retry authority. Central outages do
not close a healthy authorized native payload connection.

Approved relay maps disable implicit public discovery. Native connections relay
through the stock upstream `iroh-relay` binary, configured with `access.http`:
on each new connection the relay POSTs the endpoint ID and a `relay=<origin>`
query to web's `/internal/iroh-access`, which re-runs the registration, device,
entitlement and generation checks and answers `true` or `false` — the relay
itself holds no per-account registry and performs no further check afterward.
Mid-connection revocation is not enforced by the relay: a revoked endpoint keeps
its relay connection, and the bridge closes its own peer connection instead,
immediately on the central `peer-policy-changed` push or at the latest when its
lease expires (60 seconds; see [operations](iroh-operations.md)). Native error classification and key erasure
also require qualification. Nothing in this branch authorizes enabling
production preference before those gates pass.

### The session bus

Agent-to-agent frames (`session-bus:*`) never cross machines by themselves. The
sending bridge hands every outbound bus frame to its loopback owner socket and
nowhere else (`ProjectCore.sendToOwner`), and only to an owner that declared
`capabilities.sessionBusCarrier` on its hello: the initiating machine's desktop
app is the only carrier, and it forwards the frame verbatim onto the target
machine's own relay connection. The receiving bridge answers on the one app
session that carried the exchange in (`ProjectCore.sendToAppSession`), never by
broadcast, so the traffic is invisible to the human's phone by design. The spec
is `docs/session-messaging.md`; the host-side invariants are in
`bridge/CLAUDE.md`.

## Checkout-scoped routing

A session can run in a managed git worktree instead of the project root, so everything
filesystem-variable — files, tree, search, git, commands, preview, terminals — resolves
from that session's checkout rather than from the project path.

`CHECKOUT_VARIABLE_MESSAGE_TYPES` (`bridge/src/protocol.ts`) is the authoritative set of
message types that carry a `checkoutId`; the app mirrors it **by hand** as
`kCheckoutVariableMessageTypes`
(`app/lib/project/project_message_classification.dart`), so the two drifting apart is
silent.

Checkout lifecycle and storage live in `bridge/src/worktrees/`, and the checkout path
itself never crosses the wire. `WORKTREE_SESSIONS_SUPPORTED`
(`bridge/src/worktree-capability.ts`) is the kill switch.

Tree state flows pull-first.
`FileService.setTreeInterest` registers one tree hydrator while Files is visible
or a feature needs tree data, such as file mention suggestions. Checkout
activation alone does not request a tree. Multiple consumers share the hydrator
and the last release removes automatic refresh. The cached tree survives, with
sequence-based unchanged responses on renewed demand. A gap invalidates the
cached base; recovery waits for demand if no consumer is present. Incremental
broadcasts still arrive, and Git status, badges, selected-file reads, and
notifications remain independent. A re-sync never pushes `tree:full`: pushing
every checkout's full tree at each reconnect is a multi-megabyte flood that
stalls the session before the app has asked for anything, so every client pulls
it per checkout, on demand, with `file:tree:snapshot:request`.

## Terminal frames and history

Local and relay viewers use the same demand policy. A visible terminal pane
registers a display lease with its checkout's `TerminalService`; multiple panes
share one attachment. Layout visibility, including mobile pages and hidden
`IndexedStack` children, determines demand independently of keyboard focus.
Discovery and checkout activation retain terminal metadata without subscribing
to hidden screens. Only displayed terminals participate in screen readiness.

After visible screens arrive and settle for 500 ms, the focused checkout may
prefetch uncached user terminals from its terminal list. Agent terminals,
services, and setup transcripts are excluded. One speculative attachment may
exist across the app. Its first independent frame is acknowledged and cached,
then the attachment is retired and unsubscribed; late frames are discarded.
A five-second deadline covers acceptance and the first frame. Failure stops
prefetch for that focus visit without failing the checkout. Visible demand
preempts speculation, or promotes the same terminal's existing attachment.

Hidden screens share a global LRU with screen-count and retained-string-memory
bounds in `app/lib/services/terminal_screen_cache.dart`. Prefetch does not create
native engines. Hidden panes release their engines and preserve immutable frame
payloads and the separately bounded history model. Reopening applies cached
content through the frame application path and shows refresh progress, while
pane keystrokes are refused until the new attachment delivers a frame.
Confirmed send-to-agent handoffs can send to a running hidden agent before
revealing it; they still refuse unavailable PTYs and disconnected transports
and never buffer input for later delivery.
Keystrokes are never buffered. Run changes, terminal/checkout deletion, and
service disposal invalidate the corresponding cache. Visible history readers
retain their live attachments; reopening reattaches before paging history.

The bridge owns one authoritative headless VT per PTY run. Output, resize,
terminal queries, and exit drain in parser order. Apps subscribe using terminal
protocol version 2 and receive independent screens at a maximum of 20 FPS;
`terminal:output` and attach snapshots are not app delivery paths. Unsupported
peers require an upgrade. An attachment failure preserves the last valid screen
and offers recovery through a fresh attachment, never raw-stream fallback.

Each authenticated app connection owns its terminal attachments, acknowledgments,
pause state, and delivery budget. Relay replies name the subscribing peer before
they are sent; another connected app receives neither its frames nor its history
pages. Project streams on the same connection share the terminal byte budget.
A disconnect retires that peer's attachments while other viewers stay
attached. Cancellation resets that attachment's own stream, discarding whatever
it still had queued.

Terminal size ownership is explicit. Passive live viewers show **Take control**;
activating it sends an immediate `terminal:resize` with `intent: takeover` using
the viewer's available viewport. Typing, clicking, paste, focus restoration, and
history browsing never transfer ownership. An unowned terminal adopts its first
visible viewer; otherwise only its owner may send debounced `intent: resize`
updates. The bridge processes takeovers in arrival order and rejects routine
resizes from other clients, returning its current size and owner. Disconnecting
an owner preserves the last grid. All viewers continue receiving independent
frames and painting each frame at its own dimensions, centered and scaled down
when necessary; ownership is about size, not exclusive input permission.
The control shows a pending state until ownership is announced, with a five-second
timeout and retry. It is hidden in history and after exit, and disabled offline.

The authoritative parser emits bare BEL as a separate, ephemeral
`terminal:bell` event scoped to the checkout, terminal, and run. The bridge
throttles it to one event per run per 500 ms; the app rings only for its focused
terminal's current run, with the existing window-wide audible throttle. Bells
are never cached or included in screens, so restoring a frame does not repeat
an alert. OSC notification and title terminators do not ring the bell.

An absent terminal is different from a display failure: after attempting archived
restoration, the bridge answers its subscribe request with a correlated
`UNKNOWN_TERMINAL` status. The app drops an empty obsolete tab or retains its
screen/history as unavailable, without live input or automatic retries. Only a
new authoritative `terminal:started` event revives attachment for that ID.

Session-list replies publish reconciliation events even when the list is
unchanged. Compatible default-list requests share a reply within the same
connection establishment; archived-list requests remain exactly correlated.
The 15-second request bound clears loading, and a late valid reply clears the
active project's session timeout notice. Deleted checkout bundles are released
on the second listing excluding them, including identical listings, or on an
explicit unknown-checkout refusal when the latest list also excludes them.

Subscription identity includes the authenticated connection, project stream,
checkout, terminal, run, and attachment. A replacement PTY gets a new run ID;
reconnect gets a new attachment ID. Consumption acknowledgments retire at most
four frames / 1 MiB per viewer, bounded by 2 MiB across terminal attachments on
the connection. Terminal payloads are coalesced before being written as a
record on the terminal's own stream (`docs/protocol/peer-session.md` §1b); QUIC/TLS
is the confidentiality layer and authorization checks still apply per record.
Acknowledgment is consumption, not evidence that the Flutter engine painted.

Normal-buffer rows are archived at the parser's scroll boundary in indexed
SQLite storage. Frames carry the matching epoch and row boundary. Archived rows
keep their original width, soft-wrap metadata, styles, and hyperlink targets;
bridge resize reflows only live rows. The reader wraps presentation to its local
grid without rewriting archived rows. Growing the PTY viewport adds blank space rather than
unscrolling archived rows. App scrolling requests pages of at most 200 rows /
256 KiB and keeps at most 2,000 rows / 16 MiB cached. Retention defaults to
256 MiB per run and 2 GiB per machine; committed history survives restarts until
eviction or session deletion. Explicit history clear starts a new epoch. Disk
failure disables further recording with visible status while valid live frames
continue. Fullscreen replay and time navigation are outside this history model.

The terminal uses one external scrollbar over the retained archive range. Its
thumb is independent of the bounded native history cache; indexed seeks reuse
`beforeRowId` and replace the loaded window. A drag coalesces intermediate targets
while one request is in flight. Ordinary scrolling enters history, while an
application owning mouse input retains its wheel events; the external track and
Shift+wheel remain terminal-history controls.

Browsing captures an immutable normal-buffer screen at its archive boundary.
Later frames update the live engine without moving the reader. Alternate-buffer
screens remain a separate live endpoint, never archived redraws. Reaching the
bottom, End, or the Live shortcut returns to the current frame. Typing, paste,
quick actions, and attachments return live and use the existing authorized input
path. Copy and selection stay in history. The history toolbar and modal close
control are absent; loading and errors belong to the scrolling surface.

Retention counts encoded rows, saved final screens, and archive ownership
metadata. SQLite page and journal overhead is additional. Host environment
variables `ANTGRID_TERMINAL_HISTORY_RUN_BYTES` and
`ANTGRID_TERMINAL_HISTORY_MACHINE_BYTES` override the positive integer byte limits.
Committed rows remain readable when recording stops. Final screen capture drains
before emulator disposal; its immutable frame remains until acknowledgment or
attachment expiry, and the app keeps the completed viewport available.

The terminal protocol uses the existing authenticated transports: relay traffic
runs over the authenticated QUIC/TLS native connection; the current loopback
listener uses a local bearer token.
Terminal qualification commands live in `bridge/package.json` and `evals/package.json`.

## Shared packages (`packages/`)

- **`antgrid-agents`** - ELv2 Bun workspace for agent contracts, built-in adapters,
  shared chat runtime, and integration assets. Bridge consumes public exports;
  this package never imports bridge. Terminal preparation accepts conversation
  intent and returns a complete invocation, while bridge retains checkout and
  process ownership. Agent payload schemas are composed into bridge wire envelopes.
  Host services are bound in `bridge/src/agent-host.ts`. Assets are embedded as text
  and materialized into content-addressed directories for external runtimes.
  Built-in registration remains static; dynamic plugin loading is not implemented.

- **`antgrid_relay_client`** — pure Dart relay/crypto client, no Flutter.
- **`antgrid_eval_client`** — E2E eval fixtures.
- **`antgrid-wire`** — TS Bun workspace holding the session-stream frame type
  names (`SESSION_FRAME_TYPES`) **and** the relay control-envelope Zod schemas
  (`hello`/`welcome`/`stream-*`/`error`, the `ClientMessage`/`ServerMessage`
  unions, `ErrorCode`), plus the spoof-safe client-IP/XFF resolver
  (`client-ip.ts`) used by relay and web. Shared by bridge/relay/web/evals.

  A session-stream record carries no header, version byte or kind byte: it is
  one length-prefixed JSON record per session frame or control-plane message,
  discriminated on the JSON body's own `type` alone (`isSessionFrameType`). A
  `StreamOpen` record is what tags a stream's kind, and the authenticated
  native connection supplies peer identity — see `docs/protocol/peer-session.md`
  for the record layout, the stream catalogue, and the session hello it
  carries. `relay/src/protocol.ts` is a thin re-export shim of this package;
  the Dart clients mirror these schemas by hand, so drift is silent. Shared
  fixtures under `evals/fixtures/` pin both control envelopes and peer transport
  bytes and constants across TypeScript and Dart.

Other dirs: `docs/` (design notes), `scripts/dev.ts` (fallback dev runner),
`aspire/` (default dev launcher).

## Configuration (`antgrid.yaml`)

Flat file, no project wrapper, and the schema is **strict** — an unknown
top-level key fails the load rather than being ignored. `AbConfigSchema`
(`bridge/src/config.ts`) is the source of truth; the keys are `name`,
`relayUrl`, `agent`, `services` (long-running, started with the checkout unless
`autoStart: false`), `commands` (on-demand), `ports` (dev-port detection and
preview tunneling), and `worktree` (below).

The file is `./antgrid.yaml` or `<ANTGRID_DIR>/antgrid.yaml` (`findConfigFile`;
`resolveAbDir()` in `antgrid-dir.ts` — `~/.antgrid` by default,
`~/.antgrid-dev` for a local dev build; see `hostDir()` in
`host_discovery.dart`). The bridge's folder is the project root: `projectId` is
`computeProjectId(folder)` — a hash of the realpath'd path, case-folded on
Windows/macOS — while the display name is `name`, falling back to the folder's
basename (`projectName`). A session bound to a managed checkout resolves its
working directory from the checkout instead (see Checkout-scoped routing), and
`prepareCheckoutRuntime` (`bridge/src/agent-core.ts`) builds that checkout's own
FileWatcher / PortDetector / TunnelManager from the config found there.

`${env.VAR}` and `${project.path}` interpolate in `services` and `commands`,
eagerly at load time against `process.cwd()`.

### `worktree.setup`

Provisioning for a freshly cut managed worktree. `git worktree add` gives a tree
of tracked files at the base commit — no `node_modules`, no `.env`, no generated
client — so without this block the first isolated session lands in a broken
build, and the checkout's `services` would auto-start into it.

```yaml
worktree:
  setup:
    steps:
      - name: Copy env files
        copy: [".env", "web/.env"]
      - name: Install dependencies
        run: bun install
      - name: Generate Prisma client
        run: bun run --filter antgrid-web prisma:generate
        workingDir: .
        env:
          CI: "1"
    timeoutMs: 600000      # the whole run, not per step (default 10 min)
    onFailure: warn        # the only value v1 accepts
    startAgent: afterSetup # or `immediate` — default afterSetup
```

- A step carries **either** `copy` **or** `run`, never both, and `name` is
  required — that name is what the progress line renders, which is the entire
  point of a named list.
- `copy` sources are read from the **main project** and land at the same
  relative path inside the checkout: the point is pulling in the files the
  worktree does not have. Both sides must stay under their own root (`pathBelow`,
  `bridge/src/worktrees/path-guard.ts`) and an absolute entry is refused — a
  checkout's `antgrid.yaml` is branch-supplied content, so
  `copy: ["../../.ssh/id_ed25519"]` would otherwise read outside the project and
  write outside the worktree. An escape refuses the whole run rather than
  skipping the entry. A **missing source is a warning**, written into the
  transcript, and the step continues: not every developer has every env file.
- `run` is a shell line (`shell: true`) — the same trust class as `services` and
  `commands`, which already run branch-supplied commands on checkout prep.
- `onFailure: warn` is the only accepted value; the enum reserves `block` for a
  version whose UI has an escape hatch from a session wedged behind setup. A
  failed run never blocks the agent — it leaves a persistent banner.
- `startAgent` decides whether this session's agent WAITS for the run.
  `afterSetup` (the default) queues the `session:start` and fires it when the
  run settles; the entry reports `running: false` with `setup.pendingStart` for
  the whole run, which is what the app's provisioning pane and its auto-start
  guards read. `immediate` launches the agent alongside the first step.
  **Nothing orders the two PTYs**: the agent can beat a `copy:` step, so a
  project whose first step carries `.env` in should expect it to be absent for
  the agent's first seconds — which is why the wait is the default rather than
  something inferred from how fast a given project's steps happen to be. The
  `services:` deferral is a SEPARATE axis and is not lifted by `immediate`:
  `bun run dev` against an unprovisioned `node_modules` fails with nobody
  watching, unlike an agent. Per-run, the banner's `Start agent now` releases a
  waiting agent by hand (the `skip` verb), so `immediate` is that choice made
  once in config rather than a new capability.
- Like the rest of the block, `startAgent` is branch-supplied. It decides only
  whether the agent waits, never what it runs — the `agent:` block already
  supplied that, and `run:` steps are already the same trust class as
  `services` — so it crosses no boundary the block did not already cross.
- The block is honoured **only** from an `antgrid.yaml` that physically lives in
  the checkout. `findConfigFile` falls back to `<ANTGRID_DIR>/antgrid.yaml`, and
  a machine-global setup block would otherwise run for every project's
  worktrees with nobody having asked for it.
- `worktree` is excluded from the eager interpolation pass and resolved lazily
  per run by `CheckoutSetupRunner` (`bridge/src/worktrees/checkout-setup.ts`),
  because the eager context is `process.cwd()` — the MAIN root — which would
  bake main's paths into a checkout's own steps.

Variables, resolved against the checkout the run belongs to:

| Variable | Value |
|---|---|
| `${project.path}` | main project root |
| `${checkout.path}` | this managed worktree |
| `${checkout.branch}` | the `antgrid/*` branch Antgrid created |
| `${base.branch}` | what the worktree was cut from (`CheckoutRecord.baseRef`) |
| `${session.id}` | the owning session id |
| `${env.X}` | the bridge process's environment |

Every `run` step also gets `ANTGRID_PROJECT_PATH`, `ANTGRID_CHECKOUT_PATH`,
`ANTGRID_CHECKOUT_BRANCH`, `ANTGRID_BASE_BRANCH`, `ANTGRID_SESSION_ID` and
`ANTGRID_SETUP=1` in its environment — a branch or base that does not exist is
the empty string, never an absent key. A step's own `env:` wins over that
contract, which wins over the inherited environment.

Host-side lifecycle — the one PTY the run lives in, the deferred `services`, the
start gate and what survives a restart — is in `bridge/CLAUDE.md`.

Native endpoint recovery and central reconnect have separate owners. The bridge endpoint lifecycle serializes creation/retirement, retries transient listener failures with bounded backoff, and bounds concurrent admissions. Native project readiness uses host-local bindings; the central protocol has no stream registration or payload acknowledgements. On the app, `PeerRuntime` owns the enrollment endpoint and `ConnectionSupervisor` owns per-machine retry. Endpoint initialization and peer dialing have separate deadlines; neither central presence nor Iroh path transitions establishes a new session generation.
