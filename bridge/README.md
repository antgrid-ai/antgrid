# Antgrid Bridge

The headless bridge process of [Antgrid](https://antgrid.ai). It runs on the
dev machine as a child process of the Antgrid desktop app and does the local
work the app builds on: agent terminals (PTY), file watching and tree/search,
git status, dev-port scanning, and localhost HTTP tunneling for preview. All
traffic between the bridge and a remote app is end-to-end encrypted (X25519
ECDH + AES-256-GCM); the relay only ever sees opaque ciphertext.

## You don't install this

There is no user-facing install of the bridge. Install the **Antgrid desktop
app** — it spawns the bridge itself and hands it a bootstrap payload over
stdin at launch. Running the binary by hand just waits a few seconds for that
payload and then exits.

## Development (this repo)

The bridge is part of the Bun workspace at the repo root — one `bun install`
from the root covers it.

- Run the full local stack from the repo root: `npm run aspire` (default) or
  `npm run dev`.
- Tests: `bun run --filter antgrid-bridge test` (from the repo root).
- Entry point: `src/index.ts`. The default action boots the host from the
  stdin bootstrap payload; the real subcommands are `hook` (internal agent
  hook runner), `init` (regenerate `antgrid.yaml` for the current workspace),
  and `phones` (inspect/drop local phone records).
- Requires Bun — the minimum version is checked at startup in `src/index.ts`.

Deep reference for agents and contributors: `bridge/CLAUDE.md` and
`docs/architecture.md` at the repo root.
