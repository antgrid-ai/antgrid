# Antgrid Agent — Development Specification

**Product:** Antgrid
**Company:** Radha AI
**Component:** Antgrid Agent (runs on developer's machine)
**Version:** 0.1.0

---

## Project Overview

Antgrid is a remote development companion for AI-assisted coding on the go. It lets developers monitor, control, and review AI coding agents (Claude Code, Codex, Aider, etc.) from their mobile phone or tablet — without SSH, open ports, or complex setup.

The Antgrid Agent is a lightweight CLI service that runs on the developer's machine. It connects outbound to a relay server via secure WebSocket, streams terminal output, file tree state, and port information to a paired Antgrid mobile app. All data is end-to-end encrypted — the relay server is zero-knowledge and cannot read any content.

The user experience is simple: install the agent, run `antgrid`, sign in to the Antgrid mobile app with the same account, and start working from anywhere.

---

## Architecture

```
┌─────────────────┐       ┌─────────────────┐       ┌─────────────────┐
│   ANTGRID APP      │       │  RELAY SERVER   │       │  ANTGRID AGENT     │
│   (Flutter)     │◄─WSS─►│  (lightweight)  │◄─WSS─►│  (Bun)          │
│                 │       │                 │       │                 │
│ • Code viewer   │       │ • Routes msgs   │       │ • Spawns PTYs   │
│ • Terminal view │       │ • Offline queue  │       │ • Watches files │
│ • Browser       │       │ • Zero-knowledge│       │ • Scans ports   │
│ • Send commands │       │ • Auth only     │       │ • Encrypts all  │
└─────────────────┘       └─────────────────┘       └─────────────────┘
       ▲                         ▲                         ▲
  E2E Encrypted            Can't read               E2E Encrypted
  (AES-256-GCM)            anything                 (AES-256-GCM)
```

**Key architectural decisions:**
- Agent makes OUTBOUND connections only — no ports opened on the dev machine
- No SSH required — communication goes through a WebSocket relay
- Zero-trust relay — all encryption/decryption happens only on Agent and mobile app
- Agent keeps AI coding tools running even if the mobile app disconnects
- Mobile app reconnects seamlessly and catches up on missed output

---

## Tech Stack

| Concern | Technology | Reason |
|---------|-----------|--------|
| **Runtime** | Bun 1.3.5+ | Native TypeScript, fast startup, built-in WebSocket, built-in test runner, single binary |
| **Language** | TypeScript (strict) | Type safety, shared types with relay server |
| **PTY** | `bun-pty` | Cross-platform PTY spawning for interactive terminal sessions |
| **WebSocket** | Bun built-in WebSocket client | No external dependency needed |
| **File Watching** | `chokidar` v5 | Mature, recursive project directory watching |
| **Gitignore** | `ignore` | Parse and apply .gitignore rules to file tree |
| **Config** | YAML (`yaml` package) | Human-readable config file |
| **Validation** | Zod v4 | Schema validation for config and messages |
| **Encryption** | Node.js `crypto` (Bun compatible) | AES-256-GCM, HKDF key derivation, X25519 ECDH |
| **CLI** | `commander` | Argument parsing |

**Why Bun over Node.js:**
- Native TypeScript execution — no transpilation step
- 2-5x faster startup time — agent feels instant
- Built-in test runner — no Jest/Vitest setup needed
- Single binary — simpler installation story
- Built-in WebSocket — no `ws` package needed

---

## Key Dependencies

```json
{
  "bun-pty": "Cross-platform PTY spawning for terminal sessions",
  "chokidar": "Recursive file system watcher",
  "commander": "CLI argument and command parsing",
  "ignore": "Parse .gitignore files for file tree filtering",
  "yaml": "Parse antgrid.yaml configuration files",
  "zod": "Schema validation for config and protocol messages"
}
```

Dev dependencies:
```json
{
  "@types/bun": "Bun runtime type definitions",
  "typescript": "TypeScript compiler for type checking"
}
```

Notably NOT needed due to Bun built-ins:
- ~~`ws`~~ → Bun native WebSocket
- ~~`tsx`/`ts-node`~~ → Bun runs TypeScript directly
- ~~`jest`/`vitest`~~ → `bun test`
- ~~`esbuild`/`tsup`~~ → `bun build`

---

## Configuration File (antgrid.yaml)

The agent reads a YAML configuration file. Users create this in their project root or home directory.

> Note: This is draft, antgrid.yaml might change in future

```yaml
# antgrid.yaml

# ── Agent Settings (global, per-machine) ────
agent:
  relay: "wss://relay.antgrid.radhaai.dev"
  name: "My MacBook Pro"
  logLevel: "info"

# ── Projects ────────────────────────────────
projects:
  - id: "blazor-app"
    name: "Blazor Dashboard"
    path: "/home/user/projects/blazor-app"
    default: true
    exclude: ["node_modules", ".git", "bin", "obj", "dist"]

    terminals:
      - name: "Claude Code"
        command: "claude"
        workingDir: "${project.path}"
        autoStart: true
        env:
          ANTHROPIC_API_KEY: "${env.ANTHROPIC_API_KEY}"
      - name: "Dev Server"
        command: "dotnet"
        args: ["watch", "run"]
        workingDir: "${project.path}"
        autoStart: true
      - name: "Shell"
        command: "${env.SHELL}"
        workingDir: "${project.path}"
        autoStart: true

    preview:
      autoDetectPorts: true
      ports:
        - remote: 5000
          label: "Blazor App"

  - id: "nextjs-site"
    name: "Marketing Site"
    path: "/home/user/projects/marketing-site"
    exclude: ["node_modules", ".git", ".next", "dist"]

    terminals:
      - name: "Claude Code"
        command: "claude"
        workingDir: "${project.path}"
        autoStart: true
      - name: "Dev Server"
        command: "npm"
        args: ["run", "dev"]
        workingDir: "${project.path}"
        autoStart: false
      - name: "Shell"
        command: "${env.SHELL}"
        workingDir: "${project.path}"
        autoStart: true

    preview:
      ports:
        - remote: 3000
          label: "Next.js"
```

### Variable Interpolation

The config parser resolves these patterns:
- `${project.path}` — references other config values
- `${env.VARIABLE_NAME}` — reads from OS environment variables

> Note: `${secrets.key_name}` (OS keychain integration) is not yet implemented.

---

## Implemented Features

### 1. Terminal Management ✅
**Purpose:** Enable the Antgrid app to view and interact with multiple terminal sessions running AI coding tools, dev servers, and shells on the developer's machine.

- Spawn multiple independent PTY sessions using `bun-pty`
- Stream terminal output in real-time to the paired Antgrid app via relay
- Output batching — aggregates data in 16ms windows or 4KB chunks to prevent flooding
- Accept input from the Antgrid app and write to the PTY
- Support terminal resize when the Antgrid app reports its display dimensions
- Maintain a scrollback buffer (~10,000 characters) per terminal for reconnecting clients
- Detect terminal process exit and notify the Antgrid app
- Start/stop terminals on demand from the Antgrid app or based on autoStart config
- Graceful terminal shutdown: SIGTERM with 5s timeout, then SIGKILL

### 2. File Tree & Code Viewer ✅
**Purpose:** Let the Antgrid app browse the project file structure and read source files for code review — without SFTP or SSH.

- Watch the project directory recursively for file system changes using chokidar
- On initial connection, send the complete file tree structure
- On file changes, send incremental updates (debounced at 100ms)
- Serve file contents on demand when the Antgrid app requests a specific file
- Respect exclude patterns from config and .gitignore files (via `ignore` package)
- Binary file detection (checks first 8KB for null bytes)
- Path traversal protection — validates requested paths don't escape project root
- Limit tree depth (10 levels) and file read size (1MB)
- File metadata: size, extension, type (file/directory)

### 3. Browser Preview Support ✅
**Purpose:** Allow the Antgrid app to preview running web applications by detecting active dev servers.

- Periodically scan for listening TCP ports on localhost (every 3 seconds)
- Platform-specific scanning: `ss -tlnp` (Linux), `lsof -iTCP -sTCP:LISTEN -nP` (macOS), PowerShell `Get-NetTCPConnection` (Windows)
- Filter common dev port ranges (3000-3999, 4000-4999, 5000-5999, 8000-8999, 9000-9999)
- Detect new/removed ports, identify associated process names and PIDs
- Match detected ports against configured labels in antgrid.yaml
- Diff and send `ports:update` only on changes

### 4. End-to-End Encryption ✅
**Purpose:** Ensure all transmitted data is encrypted such that the relay server has zero knowledge of content.

- X25519 ECDH ephemeral key exchange — new keypair per connection
- AES-256-GCM encryption with HKDF-SHA256 key derivation
- Per-message nonce (96-bit random) to prevent replay attacks
- Session binding — both agent & client public keys incorporated into HKDF salt
- Key zeroization — shared secrets and private keys zeroed after use
- GCM authentication tags for tamper detection
- Challenge-response handshake prevents relay spoofing

### 5. Account-Trust Admission ✅
**Purpose:** Frictionless setup — sign in on both ends and the machines are there, with no ceremony to carry between them.

- No pairing step and no scan: `GET /account/agents` hands the app every mobile-enabled machine on the account, with its relay URL and Ed25519 identity key
- A phone is admitted iff it is account-trusted AND the machine's remote-access switch is on AND the project is in the host's catalog
- Device identity persisted in `~/.antgrid/device.json` (UUID, hostname, creation timestamp)
- E2E ephemeral keypair is per-connection and in-memory only (regenerated on each handshake; never persisted)

### 6. Relay Connection Management ✅
**Purpose:** Maintain a reliable outbound WebSocket connection that survives network interruptions.

- Auto-reconnect with exponential backoff (1s → 2s → 4s → 8s → max 30s)
- Heartbeat ping every 30 seconds
- Challenge-response handshake with nonce validation
- Fast-path message parser for trusted (decrypted) messages — skips full Zod validation on hot path
- Full Zod validation for untrusted messages
- Seamless encrypt/decrypt integration for all payloads

### 7. Notification Detection ⏭️ SKIPPED
**Status:** Not implemented. Phase 6 was intentionally skipped.

Future work:
- Monitor terminal output for configurable regex patterns
- Send typed notifications: action_required, warning, info
- Debounce duplicate notifications per terminal (5 second window)

### 8. Configuration & CLI ✅
**Purpose:** Easy setup with sensible defaults. Config adds power but isn't required.

- CLI commands: `antgrid` (start), `antgrid init` (generate default antgrid.yaml)
- CLI flags: `--config`, `--relay`, `--verbose`, `--log-level`, `--timeout`
- Config auto-discovery: `./antgrid.yaml` → `~/.antgrid/antgrid.yaml` → sensible defaults

---

## Message Protocol

All messages share a base schema: `{ id: UUID, timestamp: number, type: string }`.

### Handshake Messages
Authoritative flow, field types and sealing rules: `docs/protocol/e2e-handshake.md`.

| Type | Direction | Purpose |
|------|-----------|---------|
| `handshake:client-hello` | Client → Agent | Client ephemeral pubkey + nonce |
| `handshake:agent-ready` | Agent → Client | Confirms shared secret derived |

### Terminal Messages
| Type | Direction | Purpose |
|------|-----------|---------|
| `terminal:output` | Agent → App | PTY output data (batched 4KB/16ms) |
| `terminal:input` | App → Agent | Input to send to PTY |
| `terminal:started` | Agent → App | PTY spawned notification (shell, cols, rows) |
| `terminal:exited` | Agent → App | PTY process exited (exit code) |
| `terminal:start` | App → Agent | Start a new terminal session |
| `terminal:stop` | App → Agent | Kill a terminal session |
| `terminal:resize` | App → Agent | Change terminal dimensions (cols, rows) |

### Agent Status Messages
| Type | Direction | Purpose |
|------|-----------|---------|
| `agent:status` | Agent → App | Terminal list + agent metadata |
| `agent:disconnecting` | Agent → App | Graceful shutdown notice |
| `ping` / `pong` | Bidirectional | Heartbeat (30s interval) |

### File Tree Messages
| Type | Direction | Purpose |
|------|-----------|---------|
| `tree:full` | Agent → App | Complete directory structure on pairing |
| `tree:update` | Agent → App | Incremental file changes (added, modified, removed) |
| `file:read` | App → Agent | Request file contents |
| `file:content` | Agent → App | File contents response (content, size, error) |

### Port Scanning & Preview Messages
| Type | Direction | Purpose |
|------|-----------|---------|
| `ports:update` | Agent → App | Detected listening ports + metadata |
| `preview:url` | Agent → App | Proxy URL for a detected port |

### Tunnel Messages (separate protocol)
| Type | Direction | Purpose |
|------|-----------|---------|
| `tunnel:http-request` | Relay → Agent | HTTP request forwarded through relay |
| `tunnel:http-response` | Agent → Relay | HTTP response from localhost |

---

## Project Structure

```
bridge/
├── src/
│   ├── index.ts                  # CLI entry point & main event loop
│   ├── protocol.ts               # Message definitions (Zod schemas, 21 types)
│   ├── tunnel-protocol.ts        # Tunnel message types (HTTP proxy via relay)
│   ├── config.ts                 # antgrid.yaml parsing & variable interpolation
│   ├── device.ts                 # Device identity management (~/.antgrid/device.json)
│   ├── banner.ts                 # Startup banner
│   ├── logger.ts                 # Structured logging (text/JSON modes)
│   ├── crypto.ts                 # AES-256-GCM encryption/decryption
│   ├── key-exchange.ts           # X25519 ECDH key negotiation
│   ├── terminal-manager.ts       # Multiple PTY session coordination
│   ├── terminal-session.ts       # Individual PTY lifecycle & I/O
│   ├── scrollback.ts             # Ring buffer for terminal history
│   ├── file-watcher.ts           # Chokidar-based file monitoring
│   ├── file-tree.ts              # File system scanning & reading
│   ├── port-scanner.ts           # Platform-specific port detection
│   ├── localhost-fetch.ts        # HTTP proxying to localhost services
│   ├── tunnel-manager.ts         # Preview URL & HTTP request routing
│   └── types/
├── tests/                        # 15 test files (bun test)
│   ├── crypto.test.ts
│   ├── key-exchange.test.ts
│   ├── config.test.ts
│   ├── device.test.ts
│   ├── banner.test.ts
│   ├── logger.test.ts
│   ├── port-scanner.test.ts
│   ├── localhost-fetch.test.ts
│   ├── file-tree.test.ts
│   ├── file-watcher.test.ts
│   ├── scrollback.test.ts
│   ├── terminal-manager.test.ts
│   ├── relay-server.test.ts
│   └── pairing.test.ts
├── package.json
├── tsconfig.json
├── requirements.md
└── README.md
```

---

## Development Phase Status

| Phase | Name | Status |
|-------|------|--------|
| Phase 1 | Project Setup & Core Loop | ✅ Complete |
| Phase 2 | Encryption & Pairing | ✅ Complete |
| Phase 3 | Multi-Terminal & Config | ✅ Complete |
| Phase 4 | File Tree & Code Viewer | ✅ Complete |
| Phase 5 | Port Scanning & Browser Preview | ✅ Complete |
| Phase 6 | Notifications | ⏭️ Skipped |
| Phase 7 | Polish & Testing | ✅ Complete |
| Phase 8 | Hardening & Distribution | ⏳ Not started |

---

## Startup Flow

```
 1. Check Bun version >= 1.3.5 (exit with upgrade instructions if outdated)
 2. Parse CLI arguments (commander)
 3. If "init" command → generate default antgrid.yaml in current directory → exit
 4. Load antgrid.yaml from specified path (default: ./antgrid.yaml → ~/.antgrid/antgrid.yaml)
 5. If no config found → use sensible defaults (current directory as project, default shell only)
 6. Validate config against Zod schema → show clear errors with context if invalid
 7. Resolve variable interpolation: ${env.*}, ${project.path}
 8. Load or generate device identity from ~/.antgrid/device.json (device ID, name, creation date)
 9. Generate ephemeral X25519 keypair for E2E encryption
10. Display startup banner with agent info
11. Connect to relay server via WebSocket
12. Perform challenge-response handshake with ECDH key exchange
13. On successful connection:
    a. Log connection success
    b. Start file watcher on project directory
    c. Send initial file tree snapshot
    d. Start all terminals marked autoStart: true
    e. Stream terminal output as it arrives
    f. Begin port scanning loop (3s interval)
    g. Send agent:status message (terminal list, agent info)
14. Enter main event loop — process messages bidirectionally until shutdown
```

---

## Graceful Shutdown

Handle SIGINT (Ctrl+C), SIGTERM, and SIGHUP signals:

```
1. Log "Shutting down Antgrid Agent..."
2. Send "agent:disconnecting" status to Antgrid app (with 2s timeout)
3. Stop accepting new messages from Antgrid app
4. Stop file watcher and port scanner
5. For each running terminal:
   a. Send SIGTERM to the process
   b. Wait up to 5 seconds for graceful exit
   c. If still running after 5s, send SIGKILL
6. Close WebSocket connection to relay
7. Log summary: "Antgrid Agent stopped. X terminals closed."
8. Exit process with code 0
```

On uncaught exceptions:
- Log the error with full stack trace
- Attempt graceful shutdown (steps above)
- Exit with code 1

---

## Error Handling

### Principle: Never crash. Recover gracefully. Inform the user.

| Scenario | Behavior |
|----------|----------|
| **Config file not found** | Fall back to defaults (current dir, default shell). Log warning. |
| **Config validation fails** | Show clear error with field name and expected format. Exit. |
| **Relay connection drops** | Keep all terminals running. Auto-reconnect with backoff. Buffer messages. |
| **Relay unreachable on startup** | Retry in background. Show status. Allow local testing. |
| **Terminal process crashes** | Notify Antgrid app. Keep other terminals running. Allow restart from app. |
| **Terminal spawn fails** | Log error with command details. Notify Antgrid app. Skip to next terminal. |
| **File watcher error** | Log warning. Continue without file watching. Allow manual retry. |
| **Port scan fails** | Log warning. Continue without port scanning. Not critical. |
| **Encryption/decryption fails** | Drop the message. Log warning. Request re-pair if persistent. |
| **Mobile app disconnects** | Keep everything running. Agent continues. App reconnects later. |
| **Disk full / file read fails** | Return error to Antgrid app for that file. Continue operating. |

---

## Important Constraints

1. **No inbound connections:** The agent ONLY makes outbound WebSocket connections. Zero ports opened on the dev machine.

2. **No SSH:** All communication flows through the relay via WebSocket.

3. **Zero-trust relay:** The relay never sees decrypted data. Encryption/decryption happens only on agent and Antgrid app.

4. **Minimal footprint:** < 50MB memory at idle. Cap scrollback buffer memory.

5. **Cross-platform:** macOS, Linux, and Windows (via PowerShell for port scanning). PTY support via `bun-pty`.

6. **AI-tool agnostic:** No hardcoded AI tools. Claude Code, Codex, Aider, Cline — anything in a terminal works.

7. **Single client (v1):** One Antgrid app at a time. Multi-device is a future enhancement.

8. **Foreground mode (v1):** Runs in foreground terminal. Daemon mode is future.

9. **Config optional:** Works without antgrid.yaml using defaults. Config adds power but isn't required.

10. **No telemetry:** Zero usage data, analytics, or metrics collected.

11. **Bun version gating:** Require >= 1.3.5. Show upgrade instructions if outdated.

---

## Not Yet Implemented

The following features from the original spec are not yet implemented:

- **Notifications (Phase 6):** Terminal output pattern matching, notification messages, debouncing — intentionally skipped
- **Secrets management:** `${secrets.key_name}` keychain integration — deferred
- **Project shutdown commands:** `shutdown` section in project config — not implemented
- **Binary compilation:** `bun build --compile` standalone binary — Phase 8
- **npm publishing:** `bunx antgrid-bridge` one-command install — Phase 8

---

*Antgrid — Remote development, powered by AI, built by Radha AI.*