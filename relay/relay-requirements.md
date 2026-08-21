# Antgrid Relay Server — Requirements Specification

**Product:** Antgrid
**Company:** Radha AI
**Component:** Relay Server

> **Archived.** This spec describes the original v1/v2 relay protocol —
> `register`/`challenge-response` device auth and the `pair-request`/
> `pair-connected` pairing ceremony below. Both are gone: the relay now
> authenticates a single signed `hello` and routing is account-derived
> (`mayRoute`), with no pairing step at all. See `relay/CLAUDE.md` for the
> current protocol.

---

## What It Is

A zero-knowledge WebSocket router that connects Antgrid Agents (on developer machines) with Antgrid Apps (on mobile/tablet). It routes encrypted blobs between paired devices. It never decrypts, inspects, or transforms message content.

---

## Architecture Position

```
Antgrid App (Flutter) ◄──WSS──► Relay Server ◄──WSS──► Antgrid Agent (Bun)
                              YOU ARE HERE
```

Both agent and app connect outbound to the relay. The relay never initiates connections.

---

## Key Architecture Decisions

1. **Zero-knowledge** — The relay handles only encrypted blobs. It cannot read terminal output, file contents, keystrokes, or any user data.
2. **Stateless** — No database, no disk writes. All state is in-memory and disposable. Relay restarts are non-destructive — clients auto-reconnect and rebuild state.
3. **Single pairing (v1)** — One agent pairs with one app at a time.
4. **Two channels per pair** — Each pair uses a single WebSocket connection with a `channel` field (`"control"` | `"preview"`) to distinguish command/control traffic from browser preview. The relay routes both identically as opaque encrypted blobs.
5. **Bun runtime** — Built with Bun's native `Bun.serve()` WebSocket server. Shared TypeScript types via monorepo.
6. **TLS termination at load balancer** — The relay itself serves plain WebSocket. TLS is terminated upstream at the load balancer on deploy.

---

## Functional Requirements

### 1. Device Registration & Authentication

- Agents and apps register with a device ID, device type (`"agent"` | `"app"`), display name, and Ed25519 public key (base64-encoded).
- Device IDs must match `^[a-zA-Z0-9_.-]+$` (max 128 chars).
- On registration, the relay issues a cryptographic challenge: a random 32-byte nonce with a unique challenge ID.
- The client signs the nonce with its Ed25519 private key and returns the signature.
- The relay verifies the signature using the Web Crypto API (`crypto.subtle`). Challenges expire after 30 seconds.
- Unauthenticated connections cannot send or receive routed messages, pair, or unpair.
- A device that fails authentication is removed and its socket is closed with code 1008.

### 2. Pairing

- Only apps can initiate pairing. Apps send a `pair-request` with the target agent's device ID.
- If the target agent is already online and authenticated, pairing completes immediately.
- If the target agent is not yet connected, the relay holds the request for up to 60 seconds (configurable) before timing out with `PAIR_TIMEOUT`.
- On successful pairing, both sides receive a `pair-connected` message containing the peer's device ID, name, and device type.
- Single pairing is enforced — a device already paired rejects new pair requests with `ALREADY_PAIRED`.
- Pair requests are rate-limited per IP: max 5 per minute (configurable).
- Duplicate pending requests to the same target are rejected with `ALREADY_PAIRED`.
- If either side disconnects during a pending pair request, the request is cancelled.

### 3. Message Routing

- Once paired, the relay forwards encrypted blobs bidirectionally between agent and app.
- The relay reads only the unencrypted envelope (sender, recipient, channel). The payload is opaque.
- The `channel` field (`"control"` | `"preview"`) distinguishes traffic type. Both are routed identically.
- Messages to unpaired or unregistered devices are dropped with a typed error to the sender.
- A device can only send to its paired counterpart — cross-pair routing returns `ROUTE_FAILED`.
- Per-pair message rate limiting: 100 messages/sec (configurable) using a 1-second fixed window.
- WebSocket max payload size is enforced at the transport layer (1.5MB) before JSON parsing.

### 4. Offline Message Queue

- If one side disconnects, the relay queues messages from the online side.
- Queue is bounded per pair: max 1000 messages or 10MB (configurable), whichever is hit first.
- When the queue is full, the oldest messages are dropped (FIFO eviction).
- On reconnect, queued messages are flushed in order to the reconnecting device.
- If only one peer reconnects, messages for the still-offline peer are re-enqueued.
- Queue is in-memory only — lost on relay restart is acceptable (agent resends state on reconnect).

### 5. Heartbeat & Liveness

- The relay pings all connected devices every 30 seconds (configurable).
- If no pong is received within 10 seconds (configurable) after a ping, the connection is closed with code 1001.
- Dead connections are detected within 40 seconds (ping interval + pong timeout).
- On detected disconnect: notify the paired device with `peer-offline`, begin queuing.

### 6. Connection Lifecycle

- Connection states: `CHALLENGED → AUTHENTICATED → PAIRED → DISCONNECTED`.
- On disconnect of a paired device: preserve pair state, notify peer with `peer-offline`, start queuing.
- On disconnect of an unpaired device: remove from registry entirely.
- On reconnect of a paired device: re-authenticate via challenge-response, restore pair state to `PAIRED`, flush queued messages, notify peer with `peer-online`.
- If both peers are offline and reconnect at different times, the first to reconnect receives its queued messages immediately; the second triggers a full flush and mutual `peer-online` notification.
- If a peer was removed (e.g., by stale cleanup) before reconnect, the reconnecting device's `pairedWith` is cleared and it stays `AUTHENTICATED`.
- Stale pairs (both sides offline for 24+ hours, configurable) are cleaned up hourly — both devices and their queue/rate-limiter state are removed.

---

## Protocol — Message Types

All messages are JSON over WebSocket.

### Client → Relay

| Type | Fields | Description |
|------|--------|-------------|
| `register` | `deviceId`, `deviceType`, `name`, `publicKey` | Register device and begin auth |
| `challenge-response` | `challengeId`, `signature` | Ed25519 signature of challenge nonce |
| `pair-request` | `targetDeviceId` | App requests pairing with an agent |
| `unpair` | *(none)* | Disconnect from paired device |
| `message` | `to`, `channel`, `payload` | Route encrypted blob to paired device |

### Relay → Client

| Type | Fields | Description |
|------|--------|-------------|
| `challenge` | `challengeId`, `nonce` | Auth challenge (base64 nonce) |
| `authenticated` | `deviceId` | Auth succeeded |
| `pair-connected` | `peerId`, `peerName`, `peerType` | Pairing established |
| `pair-disconnected` | `peerId` | Peer unpaired |
| `peer-online` | `peerId` | Paired peer reconnected |
| `peer-offline` | `peerId` | Paired peer disconnected |
| `message` | `from`, `to`, `channel`, `payload`, `ts` | Forwarded encrypted blob |
| `error` | `code`, `message` | Typed error (see Error Codes) |

### Error Codes

`AUTH_FAILED`, `ALREADY_REGISTERED`, `MAX_CONNECTIONS`, `RATE_LIMITED`, `INVALID_MESSAGE`, `NOT_AUTHENTICATED`, `ALREADY_PAIRED`, `PAIR_TIMEOUT`, `PAIR_RATE_LIMITED`, `WRONG_DEVICE_TYPE`, `NOT_PAIRED`, `ROUTE_FAILED`, `MESSAGE_RATE_LIMITED`

---

## Message Envelope

The relay reads only the envelope. The payload is an opaque encrypted blob.

```
envelope {
  from:    device ID (sender — added by relay on forward)
  to:      device ID (recipient)
  channel: "control" | "preview"
  payload: encrypted blob (relay never reads this, max ~1.4MB)
  ts:      timestamp (relay adds on forward)
}
```

---

## Security

- No routing without successful Ed25519 challenge-response authentication.
- Rate limiting: per-IP connection limits, per-pair message rate limits, per-IP pair request rate limits.
- Pair isolation — a device can only communicate with its paired counterpart.
- Device IDs restricted to `[a-zA-Z0-9_.-]` to prevent injection in internal key formats.
- WebSocket payload size capped at 1.5MB at the transport layer.
- No payload logging — logs contain only device IDs, connection events, and error codes.
- TLS termination is handled at the load balancer (not in the relay process).

---

## Operational Endpoints

### `GET /health`
```json
{
  "status": "ok",
  "uptime": 3600,
  "connections": 42,
  "version": "0.1.0"
}
```

### `GET /metrics`
```json
{
  "activeConnections": 42,
  "pairedSessions": 20,
  "queueDepth": 150,
  "messagesPerSec": 85.5,
  "uptime": 3600
}
```

Messages/sec is computed over a 10-second sliding window.

### `GET /ws`
WebSocket upgrade endpoint. Returns 429 if per-IP limit exceeded, 503 if server at capacity.

---

## Configuration

All configuration via environment variables:

| Variable | Purpose | Default |
|----------|---------|---------|
| `PORT` | Listen port | 8080 |
| `MAX_CONNECTIONS` | Total concurrent WebSocket connections | 10000 |
| `RATE_LIMIT_CONN_PER_IP` | Per-IP connection limit | 10 |
| `PAIR_REQUEST_TIMEOUT_MS` | How long to hold a pending pair request | 60000 |
| `PAIR_RATE_LIMIT_PER_IP` | Max pair requests per IP per minute | 5 |
| `RATE_LIMIT_MSG_PER_SEC` | Routed-frame rate limit, per (pair, channel) | 1200 |
| `RATE_LIMIT_MSG_BURST` | Routed-frame burst allowance, per (pair, channel) | 2400 |
| `RATE_LIMIT_PUSH_PER_SEC` | Push-delivery rate limit, per (agent, token) | 100 |
| `MAX_QUEUE_MESSAGES` | Per-pair offline queue message limit | 1000 |
| `MAX_QUEUE_SIZE_BYTES` | Per-pair offline queue byte limit | 10485760 |
| `PING_INTERVAL_MS` | Heartbeat ping interval | 30000 |
| `PONG_TIMEOUT_MS` | Pong timeout before disconnect | 10000 |
| `STALE_PAIR_TIMEOUT_HOURS` | Hours before stale pair cleanup | 24 |
| `LOG_LEVEL` | Logging verbosity (`debug`, `info`, `warn`, `error`) | info |

---

## Error Handling

| Scenario | Behavior |
|----------|----------|
| Auth fails | Remove device, close socket (code 1008) |
| Pair target not connected | Hold up to 60s, then `PAIR_TIMEOUT` error |
| Pair target is not an agent | `WRONG_DEVICE_TYPE` error |
| Pair target already paired | `ALREADY_PAIRED` error |
| App disconnect during pending pair | Request cancelled silently |
| Agent disconnect during pending pair | Request cancelled silently |
| Message to unpaired device | `NOT_PAIRED` error |
| Message to non-paired recipient | `ROUTE_FAILED` error |
| Recipient offline | Message queued silently |
| Queue overflow | Oldest messages dropped, new messages accepted |
| Invalid JSON or schema | `INVALID_MESSAGE` error |
| Rate limit exceeded (messages) | `MESSAGE_RATE_LIMITED` error |
| Rate limit exceeded (connections) | 429 HTTP response on upgrade |
| Rate limit exceeded (pair requests) | `PAIR_RATE_LIMITED` error |
| Server at capacity | 503 HTTP response on upgrade |
| Relay restart | All state lost. Clients reconnect and re-register. |

---

## Performance Targets

- < 100MB memory for 1000 concurrent pairs
- < 5ms added latency per message (routing overhead only)
- 100 messages/sec per pair sustained

---

## Non-Goals (v1)

- No horizontal scaling (single instance)
- No multi-region deployment
- No persistent storage
- No multi-device pairing (one agent ↔ one app)
- No message transformation or inspection
- No analytics or telemetry

---

## Source Files

| File | Purpose |
|------|---------|
| `src/server.ts` | Main server — WebSocket handling, routing, reconnect, metrics |
| `src/protocol.ts` | Zod schemas for all client↔relay message types |
| `src/device-registry.ts` | Device connection state, pairing, IP tracking |
| `src/auth.ts` | Ed25519 challenge-response authentication |
| `src/pairing-manager.ts` | Async pair request handling with timeout and rate limiting |
| `src/rate-limiter.ts` | Per-pair message rate limiting (1s fixed window) |
| `src/offline-queue.ts` | Bounded per-pair message queue with FIFO eviction |
| `src/config.ts` | Environment variable loader |
| `src/logger.ts` | Structured JSON logger to stdout |
| `tests/relay.test.ts` | Integration test suite (38 tests, 100 assertions) |
| `tests/load.ts` | Load test script (`bun run tests/load.ts`) |

---

## Structured Logging

All logs are JSON to stdout via `src/logger.ts`. Fields: `time` (ISO 8601), `level`, `msg`, plus contextual metadata (device IDs, error info). No PII or payload content is ever logged.

---

*Antgrid Relay — Sees nothing. Routes everything.*
