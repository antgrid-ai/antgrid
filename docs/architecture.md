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

Flat file, no project wrapper. Top-level keys: `terminals` (long-running,
ordered startup), `commands` (on-demand), `proxies` (port tunneling, optional
`browser:` preview), `layout`, `exclude`.

The agent uses `process.cwd()` as the project path and derives `projectId` from
`agent.name`. That path is the project root; a session bound to a managed checkout
resolves its working directory from the checkout instead (see Checkout-scoped routing).
The file is located at `./antgrid.yaml` or
`<ANTGRID_DIR>/antgrid.yaml` (`resolveAbDir()` in `antgrid-dir.ts` — `~/.antgrid`
by default, `~/.antgrid-dev` for a local dev build; see `hostDir()` in
`host_discovery.dart`). `getProjectConfig()` synthesizes a `ProjectConfig` for
FileWatcher/PortScanner/TunnelManager.
