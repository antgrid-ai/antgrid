# Antgrid App — Requirements Specification

**Product:** Antgrid
**Company:** Radha AI
**Component:** Mobile/Desktop App

---

## What It Is

A cross-platform app for monitoring and controlling AI coding agents running on a developer's machine. Not a mobile IDE — it's mission control for AI coding agents. Developers use it to watch terminal output, approve AI actions, browse project files, preview running web apps, and receive push notifications — all from their phone or tablet.

---

## Architecture Position

```
Antgrid App (Flutter) ◄──WSS──► Relay Server ◄──WSS──► Antgrid Agent (Bun)
YOU ARE HERE
```

The app connects outbound to the relay server. It never communicates directly with the agent. All app↔agent data is end-to-end encrypted — the relay cannot read any content.

---

## Key Architecture Decisions

1. **Flutter** — Single codebase for iOS, Android, macOS, Windows, Linux.
2. **Two WebSocket channels** — One for command/control (terminals, files, notifications), one for browser preview traffic. Both carry E2E encrypted payloads.
3. **Offline-resilient** — The app can disconnect and reconnect at any time. On reconnect, it catches up via the relay's offline queue and the agent's scrollback buffers.
4. **E2E encryption** — Session keys are derived per connection (X25519 ECDH), never persisted. All encryption/decryption happens on-device. Nothing is sent in plaintext.
5. **Multi-project aware** — The agent serves multiple projects. The app must support project switching.

---

## Platforms

- iOS (primary)
- Android (primary)
- macOS (secondary)
- Windows, Linux (tertiary — Flutter desktop)

---

## Functional Requirements

### 1. Admission

- Signing in to the same account on both ends is the whole admission step — there is no pairing ceremony, QR code, or short code.
- The app must resolve a machine's dial coordinates and Ed25519 key from the account inventory, and cache them on-device for offline reconnects.
- The app must support several machines on one account (e.g., work laptop, home desktop) and switching between them.

### 2. Terminal Viewer

- The app must display terminal output from multiple concurrent sessions (tabs).
- Terminal rendering must support ANSI escape codes, colors, cursor positioning — full terminal emulation.
- The user must be able to send keystrokes and text input to any active terminal.
- The user must be able to resize the terminal (the agent adjusts the PTY accordingly).
- On reconnect, the app must display the agent's scrollback buffer so the user sees recent history.
- The app must indicate terminal state: running, exited, or errored.
- The user must be able to start and stop terminals defined in the agent's config.

### 3. File Explorer

- The app must display the project's file tree in a navigable tree view.
- On initial connection, the app receives the full tree. Subsequently, it receives incremental updates.
- The user must be able to tap a file to view its contents with syntax highlighting.
- File content is fetched on-demand from the agent — the app does not cache entire projects.
- The tree must respect the agent's exclude patterns (node_modules, .git, etc.).

### 4. Browser Preview

- The app must list detected dev server ports reported by the agent.
- The user must be able to open a preview of a running web app.
- Preview traffic flows through the dedicated preview WebSocket channel via the relay.
- The app runs a local HTTP proxy that the embedded browser points to. The proxy tunnels requests to the agent, which fetches from the local dev server and returns responses.
- Each proxied request must carry a unique ID. Multiple concurrent requests must be supported (a single page load triggers 20-50+ requests).
- HMR/hot-reload WebSocket connections from dev servers must be tunneled through the preview channel.

### 5. Notifications

- The app must receive push notifications from the agent via the relay for:
  - **Permission requests** — AI tool needs user approval
  - **Errors** — command failures, crashes
  - **Task completion** — AI tool finished its work
  - **Idle** — agent has been idle (optional, configurable on agent)
- Permission request notifications must allow the user to tap and go directly to the relevant terminal.
- Notifications must work even when the app is in the background or closed (platform push notifications).
- The user must be able to mute/unmute notification categories.

### 6. Project Switching

- The app must display a list of projects configured on the connected agent.
- The user must be able to switch the active project.
- On switch, the app must:
  - Update the terminal tabs to reflect the new project's terminals.
  - Update the file explorer to the new project's tree.
  - Update the browser preview to the new project's ports.
- The previous project's UI state can be discarded on switch.

### 7. Connection Management

- The app must auto-reconnect to the relay on network interruption with exponential backoff.
- The app must display connection status: connected, reconnecting, offline.
- On reconnect, the app must re-authenticate, restore the existing pair, and catch up on missed data.
- The app must handle agent offline/online transitions gracefully — show status, queue outgoing input until agent returns.

### 8. Settings

- Manage paired agents (add, remove, rename, switch).
- Notification preferences (per-category mute).
- Theme (light/dark/system).
- Terminal font size.
- Keep screen on while connected (optional toggle).

---

## Security Requirements

- Device credentials must be stored in platform-secure storage (iOS Keychain, Android Keystore); session keys are per-connection and never persisted.
- All data sent to the relay must be encrypted with AES-256-GCM under the handshake-derived session keys.
- No plaintext user data may leave the device (except the unencrypted envelope: device IDs and channel type).
- The app must validate the relay's TLS certificate.
- Biometric/PIN lock option before accessing the app (optional, user-configurable).

---

## UI/UX Requirements

### Navigation

- Bottom tab bar with four primary sections: **Terminals**, **Files**, **Preview**, **Settings**.
- Terminal section defaults to the most recently active terminal.
- A persistent connection status indicator must be visible at all times.

### Terminal UX

- Swipe or tab to switch between terminal sessions.
- Keyboard must not obscure terminal output — scroll to bottom on new output.
- Quick-action buttons above the keyboard for common keys: Tab, Ctrl+C, Ctrl+D, arrow keys, Esc.
- "Approve" button overlay when a permission request notification is active for the current terminal.

### File Explorer UX

- Expandable/collapsible directory tree.
- File icons by type/extension.
- Pull-to-refresh to request a fresh tree from the agent.
- Tap file → full-screen syntax-highlighted viewer (read-only).

### Preview UX

- List of detected ports with labels (from agent config).
- Tap to open embedded browser preview.
- Refresh button, URL bar showing current path.
- Indicator if the dev server is not yet running.

### Responsiveness

- Must feel responsive on phones (5-7" screens) and tablets (10-13").
- Terminal viewer must adapt to screen width and orientation changes.
- Landscape mode should maximize terminal real estate.

---

## Offline Behavior

- If the relay is unreachable, the app must show "Connecting..." state and retry.
- If the agent goes offline, the app must show "Agent offline" and retain the last-known terminal output, file tree, and port list.
- Outgoing keystrokes typed while disconnected should be queued briefly (5s) and sent on reconnect, or discarded with a visual indication if reconnect doesn't happen.

---

## Performance Targets

- App launch to paired-and-streaming: < 3 seconds on warm start.
- Terminal output rendering: no visible lag at 1000 lines/sec throughput.
- File tree load (1000 files): < 1 second to render.
- Memory: < 200MB during active use.

---

## Non-Goals (v1)

- No file editing — read-only viewer only.
- No built-in code intelligence (autocomplete, go-to-definition, etc.).
- No direct SSH or LAN connection to the agent — relay only.
- No multi-agent simultaneous connections — one active at a time.
- No telemetry or analytics.

---

## Development Phases

### Phase 1 — Shell & Admission
Flutter project setup, account sign-in, relay WebSocket connection, encryption layer, device registration. Verify: sign in → connect to relay → reach the account's agent.

### Phase 2 — Terminal Viewer
Terminal emulation widget, multi-tab support, keyboard input, send/receive terminal messages, scrollback on reconnect, quick-action keys. Verify: view and interact with agent terminals.

### Phase 3 — File Explorer
Tree view widget, incremental updates, on-demand file content fetch, syntax highlighting. Verify: browse project files and read source code.

### Phase 4 — Browser Preview
Local HTTP proxy, preview channel WebSocket, request multiplexing, embedded browser widget, port list display. Verify: preview a running web app through the relay.

### Phase 5 — Notifications
Push notification integration (FCM/APNs), notification categories, tap-to-terminal deep linking, background notification handling, mute controls.

### Phase 6 — Project Switching
Project list from agent, switch command, UI state reset on switch, terminal/file/preview update.

### Phase 7 — Polish & Platform Testing
Settings screen, theming, biometric lock, responsive layout testing (phone/tablet/desktop), reconnection edge cases, performance profiling.

---

*Antgrid App — Your AI coding agents, in your pocket.*