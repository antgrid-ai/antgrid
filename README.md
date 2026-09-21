# Antgrid

**Your machines. Your agents. One control plane.**

Every CLI coding agent you run, on every machine you own, in one place — end-to-end
encrypted, on hardware you control.

[![CI](https://github.com/antgrid-ai/antgrid/actions/workflows/ci.yml/badge.svg)](https://github.com/antgrid-ai/antgrid/actions/workflows/ci.yml)
[![License: MPL 2.0](https://img.shields.io/badge/license-MPL%202.0-orange?style=flat)](LICENSE.md)
[![Latest release](https://img.shields.io/github/v/release/antgrid-ai/antgrid?style=flat&logo=github&label=release)](https://github.com/antgrid-ai/antgrid/releases/latest)
[![Stars](https://img.shields.io/github/stars/antgrid-ai/antgrid?style=flat&logo=github)](https://github.com/antgrid-ai/antgrid/stargazers)

Antgrid runs the coding agents you already use — Claude Code, Codex, Cursor and others —
in real terminals on your own hardware, and puts one screen over all of them: every
session on every machine you have signed in, grouped by the machine it is on. Around each
agent it puts the context you need to check the work yourself — multi-session terminals, a
file tree, git review with diffs, and a live browser preview. The same workspace opens on
a phone, over a relay that is end-to-end encrypted and cannot read a byte of what passes
through it.

Antgrid's Handler feature takes on the follow-ups for long-running coding tasks.
Start with your agent and do as much as you want together. When you're ready to
step away, tell Handler what's left, how to proceed and when to ask you.
It checks the agent's responses against your
instructions and asks for evidence before moving on. It notifies you when it needs
your input or your instructions say to
check with you. Its judgement can be wrong; review its decisions and cited evidence.

Handler is opt-in on a running session and included free during the beta. It is a Pro
feature once paid plans are live. See [pricing](https://antgrid.ai/pricing) for current
terms; your agent provider's usage charges still apply.

Antgrid does not replace your agent and ships no model of its own.

> [!NOTE]
> **Pre-release, working towards v1.**
>
> **Licence** — first-party distributed code is open source under
> [MPL-2.0](#licence), except the relay and web services, which remain ELv2.
>
> **Contributing** — bug reports are welcome; pull requests are not open yet
> ([CONTRIBUTING.md](CONTRIBUTING.md)).

## Features

- **Handler.** Hand over the follow-ups on long-running tasks. Tell it what's left,
  how to proceed and when to ask you. Handler
  asks for evidence before moving on and brings questions to you when needed or
  instructed. It doesn't start new sessions or jobs.
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

And two things the list above is not. It is not an audit: there has been no external
penetration test and no certification. And it does not empty the trust boundary — it moves
the relay out of it, not our account service. Your phone learns a machine's Ed25519
identity from your account's device inventory, which `app.antgrid.ai` serves, so that
service is trusted to hand you the right key even though the relay never is.

None of this needs taking on trust. The handshake specification, both implementations and
the relay itself are linked above and in this repo; [SECURITY.md](SECURITY.md) is the
reporting policy if you find something wrong with them.

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

**Bug reports are welcome; pull requests are not open yet.** This is a project
governance decision while the pre-v1 architecture is moving quickly, not a restriction
of MPL-2.0. [CONTRIBUTING.md](CONTRIBUTING.md) explains what does help in the meantime.
Security vulnerabilities go through [SECURITY.md](SECURITY.md), never the public issue
tracker.

## Licence

Antgrid's first-party source and documentation are licensed under the standard
[Mozilla Public License 2.0](LICENSE.md), except `relay/` and `web/`, which remain
under their scoped Elastic License 2.0 files. MPL is file-level copyleft: distributing
changes to MPL-covered files requires making those files' source available under MPL,
but it does not license or impose terms on your projects, prompts, separately written
plugins, or independent larger works.

[LICENSING.md](LICENSING.md) is the path-by-path map. Product-identifying artwork and
application identifiers are reserved under [BRAND-ASSETS-LICENSE.md](BRAND-ASSETS-LICENSE.md)
and [TRADEMARK.md](TRADEMARK.md); third-party code and assets retain the licences in
[THIRD-PARTY.md](THIRD-PARTY.md). Every official build links to its exact source commit
and includes the notices described in [SOURCE_OFFER.md](SOURCE_OFFER.md).
