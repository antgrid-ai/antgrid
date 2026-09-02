# Architecture reference

Background detail pulled out of the root `CLAUDE.md`. The per-component
`CLAUDE.md` files are the authority for their own subsystems; this file holds
only the cross-cutting shape.

## Message flow

```
App (Flutter) <--E2E encrypted--> Relay (WS router) <--E2E encrypted--> Agent (Bun)
```

The relay authenticates devices via a single signed `hello` frame (Ed25519
proof-of-possession) but cannot decrypt payloads. Two WS channels: `control`
(terminal, files, status) and `preview` (HTTP tunnel).

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
itself never crosses the wire. An app must advertise the `checkoutRouting` capability on
`app:ready` (`docs/protocol/e2e-handshake.md`) or it is refused a project holding a
managed session, rather than shown main's workspace beside an isolated agent.
`WORKTREE_SESSIONS_SUPPORTED` (`bridge/src/worktree-capability.ts`) is the kill switch.

## Shared packages (`packages/`)

- **`antgrid_relay_client`** — pure Dart relay/crypto client, no Flutter.
- **`antgrid_eval_client`** — E2E eval fixtures.
- **`antgrid-wire`** — TS Bun workspace holding the binary route-frame codec
  **and** the relay control-envelope Zod schemas (`hello`/`welcome`/`stream-*`/
  `error`, the `ClientMessage`/`ServerMessage` unions, `ErrorCode`), plus the
  spoof-safe client-IP/XFF resolver (`client-ip.ts`) used by relay and web.
  Shared by bridge/relay/web/evals.

  Single source of truth for `FRAME_VERSION`, which is distinct from the relay
  message `protocolVersion`. `relay/src/protocol.ts` is a thin re-export shim of
  this package; the Dart `antgrid_relay_client` mirrors these schemas by hand,
  so the two drifting apart is silent.

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
