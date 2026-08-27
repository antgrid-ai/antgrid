# Antgrid

**Your agent says it's done. Make it prove it.**

Evidence-gated supervision for the CLI coding agents you already run — on your own
hardware, end-to-end encrypted.

[![License: Elastic License 2.0](https://img.shields.io/badge/license-Elastic%20License%202.0-4b5563?style=flat)](LICENSE.md)
[![Latest release](https://img.shields.io/github/v/release/antgrid-ai/antgrid?style=flat&logo=github&label=release)](https://github.com/antgrid-ai/antgrid/releases/latest)
[![Stars](https://img.shields.io/github/stars/antgrid-ai/antgrid?style=flat&logo=github)](https://github.com/antgrid-ai/antgrid/stargazers)

Antgrid runs the coding agents you already use — Claude Code, Codex, Cursor and others —
in real terminals on your own hardware. Arm its supervisor on a session and it watches the
agent's attention signals, answers what it can, escalates what it can't, and calls a task
done only on concrete evidence — test output, exit codes, a diff — rather than the agent's
own report.

Around each agent it puts the context you need to check that work yourself: multi-session
terminals, a file tree, git review with diffs, and a live browser preview. The same
workspace opens on a phone, over a relay that is end-to-end encrypted and cannot read a
byte of what passes through it.

Antgrid does not replace your agent and ships no model of its own.

> Status: pre-release, working towards v1.

## Features

- **Supervisor.** Arm it on a session and it watches the agent's attention signals,
  answers what it can, escalates what it can't, and calls a task done only on concrete
  evidence — test output, exit codes — rather than the agent's own report. You can also
  give it follow-up steps to carry out once the task is done; it works through them in
  order and stays armed until each one is satisfied.
- **Bring your own agent.** Claude Code, Codex, opencode, Cursor, GitHub Copilot,
  Antigravity, Kilo, Kimi and Mistral Vibe are wired for notifications and session naming
  — the current set is `AGENTS` in [`bridge/src/agents/registry.ts`](bridge/src/agents/registry.ts).
  Any other terminal program still runs; it just gets no integration.
- **Terminal-first.** The agent's terminal is the primary view — real PTYs with
  scrollback, ANSI colour and input. Many sessions per project, so a build watcher or a
  REPL runs beside the agent.
- **Isolated sessions.** A session can run in its own managed git worktree, so two agents
  on one project don't fight over the working tree. Files, search, git, commands, preview
  and terminals all resolve from that session's checkout, not from the project root.
- **Files, git and preview.** A live, `.gitignore`-aware file tree with viewers for code,
  images, Markdown and PDFs; git status, side-by-side diffs, stage, commit, discard and
  branch switching; regex find-in-files; and dev-server ports auto-detected and tunnelled
  into an in-app browser.
- **Project commands and config.** Project-defined build, test, lint and deploy commands
  as one-tap buttons, plus an in-app editor for the project's `antgrid.yaml`.
- **Remote control.** Sign in and your machines are listed — no pairing ceremony. Read the
  terminal, answer a prompt, review a diff and commit from a phone. Push notifications
  reach you over APNs and FCM when an agent finishes or needs a decision.
- **Fleet view.** One account supervises projects across every machine you sign in on —
  laptop, workstation, a server — with each machine deciding for itself whether it is
  reachable from mobile at all.

## Security model

Antgrid exists to let you control an agent over the internet without handing your code,
prompts or terminal to a server in the middle. That is a design constraint, not a
feature flag.

- **Encryption is never optional.** Every app↔agent message after the handshake is
  encrypted. There is no plaintext mode to fall back to and no setting that disables it.
- **X25519 ECDH + AES-256-GCM**, with ephemeral keys generated per connection. Session
  keys are never persisted, and a connection rekeys on receive-silence or repeated
  failure rather than running indefinitely on one set.
- **Authenticated handshake.** Both sides pin the peer's Ed25519 identity in advance and
  sign a transcript that binds both ephemeral keys; HMAC key-confirmation tags must
  verify before either side sends traffic. Specification:
  [`docs/protocol/e2e-handshake.md`](docs/protocol/e2e-handshake.md); implementation in
  [`bridge/src/e2e/`](bridge/src/e2e/) and `packages/antgrid_relay_client/lib/src/e2e/`.
- **The relay is zero-knowledge.** It authenticates devices from a single signed `hello`
  frame and then routes opaque blobs. It holds no decryption keys, so terminal output,
  prompts, file contents and diffs are unreadable to it — and to anyone who compromises
  it. The relay source is in this repo, and the app accepts a custom relay URL.
- **Remote execution is off until you turn it on.** A machine is unreachable from mobile
  until you flip one per-machine switch; off is machine-wide and immediate — the machine
  stops advertising projects and rejects every remote verb. Note what the switch is *not*:
  a phone with access gets a real shell on that machine. It controls reachability, not
  containment.

Encryption protects the transport. It does not sandbox the agent, and it cannot make an
untrusted agent safe to run on your machine.

## Architecture

| Component | Path | Stack | Role |
|---|---|---|---|
| **Bridge** | `bridge/` | TypeScript / Bun | Runs on your machine: agent terminals (PTY), file watching, git, port scanning, HTTP tunnelling. Ships inside the desktop app. |
| **Relay** | `relay/` | TypeScript / Bun | Zero-knowledge WebSocket router. Forwards encrypted frames; never reads payloads. |
| **App** | `app/` | Flutter / Dart + Riverpod | Desktop and mobile UI: terminal viewer, file explorer, git review, browser preview. |
| **Web** | `web/` | TypeScript / Bun + Hono + Postgres | Accounts and sign-in, subscriptions, OAuth device flow, Ed25519 JWT minting for the relay's gate. |

Shared code lives in `packages/`: `antgrid_relay_client` (pure Dart relay and crypto
client), `antgrid-wire` (the TypeScript frame codec and relay control-envelope schemas),
and `antgrid_eval_client` (end-to-end test fixtures).

Message flow, the shared-package breakdown and the `antgrid.yaml` schema:
[`docs/architecture.md`](docs/architecture.md).

## Getting started

### Install

The desktop app bundles the bridge that runs your agents — there is nothing else to
install on the machine.

- **Windows** — [Microsoft Store](https://get.microsoft.com/installer/download/9N0P7ZRL4D9W?referrer=appbadge&cid=site)
- **macOS** — [`antgrid-macos.dmg`](https://github.com/antgrid-ai/antgrid/releases/latest/download/antgrid-macos.dmg)
- **Linux** — [`antgrid-linux.AppImage`](https://github.com/antgrid-ai/antgrid/releases/latest/download/antgrid-linux.AppImage)

Every build, with release notes:
[github.com/antgrid-ai/antgrid/releases](https://github.com/antgrid-ai/antgrid/releases).
iOS and Android builds currently ship to TestFlight and Google Play's internal track;
public store listings are not live yet.

### First run

1. Sign in with GitHub, Google or a passwordless magic link. The app provisions itself as
   a device on your account.
2. Add a project — a folder on your machine. An `antgrid.yaml` in the project (or in
   `~/.antgrid/`) declares long-running terminals, on-demand commands, port proxies and
   layout; the schema is in [`docs/architecture.md`](docs/architecture.md).
3. Start a session with whichever agent CLI you already have installed.
4. To drive it from a phone, install the mobile app, sign in with the same account, and
   turn on that machine's remote-access switch from the desktop title bar.

### Build from source

The repo is one Bun workspace (bridge, relay, web, evals and the shared packages)
alongside a Flutter app. Prerequisites, the setup script, and the per-workspace test and
analysis commands are in [DEVELOPMENT.md](DEVELOPMENT.md).

### Contributing

**Bug reports are welcome; pull requests are not open yet.** Antgrid's licence grant is
non-sublicensable, so accepting outside patches needs a contributor licence agreement
that does not exist yet — [CONTRIBUTING.md](CONTRIBUTING.md) explains the position and
what does help in the meantime. Forking, modifying and self-hosting are unaffected and
need no permission. Security vulnerabilities go through [SECURITY.md](SECURITY.md),
never the public issue tracker.

## Licence

Antgrid is **source-available** under the [Elastic License 2.0](LICENSE.md). That is not
an OSI-approved open-source licence, and the difference matters. In short:

- You may read, fork, modify, self-host and use the software for free — including inside
  a company, for commercial work.
- You may **not** provide it to third parties as a hosted or managed service that gives
  them a substantial set of its features or functionality.
- You may **not** move, change, disable or circumvent the licence-key functionality, or
  remove the notices attached to it.

Two packages are deliberate exceptions, licensed under **Apache-2.0**:
[`packages/antgrid-wire`](packages/antgrid-wire) (the wire protocol) and
[`packages/antgrid_relay_client`](packages/antgrid_relay_client) (the client-side
end-to-end encryption). They are permissive so anyone can build an Antgrid client, and
so the cryptography can be audited and reused without asking. Antgrid's own code
elsewhere — the bridge included — is ELv2; vendored third-party code keeps its own
licence. [LICENSING.md](LICENSING.md) maps every path to the licence that covers it.

[LICENSE.md](LICENSE.md) is the authority; the bullets above are a summary, not legal
advice. The Antgrid name and logo are not covered by that grant — see
[TRADEMARK.md](TRADEMARK.md) if you intend to distribute a fork. Licences for the
third-party code and assets Antgrid bundles are recorded in
[THIRD-PARTY.md](THIRD-PARTY.md). Product, pricing and account management live at
[antgrid.ai](https://antgrid.ai).
