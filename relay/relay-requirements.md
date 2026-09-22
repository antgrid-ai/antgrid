# Antgrid Central Relay Requirements

The relay is the authenticated central control plane for Antgrid. Remote
application payloads use native Iroh peer connections; they do not pass through
this service. The relay is stateless apart from bounded in-memory connection,
license-cache, replay and rate-limit state.

## Responsibilities

The relay:

- authenticates agent and app WebSockets with the signed v3 `hello` contract;
- arbitrates one live socket per relay device identity using epochs and signed-hello freshness;
- publishes account-scoped `peer-online` and `peer-offline` discovery hints;
- applies license revocation, account expiry and peer-policy notifications;
- forwards end-to-end encrypted mobile push blobs to FCM or APNs;
- maintains protocol and application heartbeat liveness;
- exposes health, control-plane metrics and authenticated internal operations.

The relay does not forward binary application frames, register project streams,
store offline messages, establish E2E payload sessions, or authorize native peer
traffic. Those responsibilities live at the endpoints and the native transport.

## WebSocket protocol

The first frame must be a text v3 `hello` matching the shared schemas in
`packages/antgrid-wire/src/relay-protocol.ts`. It is signed over the normalized
relay host and carries a required account token. Invalid, replayed or unexpected
first frames receive a typed terminal error and close code 1008.

After `welcome`, accepted client control messages are:

- `ping`;
- `push:deliver` from an authenticated agent;
- no second `hello`.

The server may send `welcome`, typed `error`, `peer-online`, `peer-offline`,
`pong`, `peer-policy-changed` and `push:result` frames. Every error includes a
`retryable` boolean.

Any post-auth binary frame is a `PROTOCOL_VIOLATION` and closes with 1008.
Retired `stream-open` and `stream-close` messages receive the same outcome.
Unknown future JSON control messages remain `INVALID_MESSAGE` errors so current
clients can ignore unsupported extensions without losing a healthy socket.

The checked-in cross-language samples are generated from
`packages/antgrid-wire/scripts/gen-envelope-vectors.ts` into
`evals/fixtures/relay-envelope-vectors.json`.

## Identity and presence

An agent connects under its bare machine device UUID. An app connects once per
machine under `<accountDeviceUuid>#<machineDeviceUuid>`. Account membership from
the verified token scopes presence and policy fan-out. Presence is discovery
information only and does not carry or authorize payload traffic.

A higher epoch replaces the current holder. An equal epoch with a fresh, non-older
signed hello admits a legitimate redial; captured/replayed hellos cannot evict the
live holder. A losing socket receives terminal `SUPERSEDED` and closes 1008.

## Security and limits

- No admission without signed-hello proof of possession and token verification.
- Agent tokens bind the machine UUID and public key; app tokens authenticate the
  account while the relay slot supplies machine scoping.
- Revocation and expiry close affected sockets immediately after a typed error.
- Replay records are retained for at least the complete accepted clock-skew window.
- Upgrade admission enforces global and resolved-client-IP connection limits.
- JSON controls and encrypted push delivery have independent bounded rate limits.
- Forwarded client-IP headers are honored only from configured trusted proxies.
- Logs and internal inventory never contain application payloads or project data.

## HTTP surface

- `GET /health` reports status, uptime, connection count and version.
- `GET /metrics` reports active control connections and uptime.
- `GET /ws` upgrades an admitted WebSocket.
- `POST /internal/revoke`, `/internal/expire`, `/internal/peer-policy` and
  `/internal/connections` require the internal HMAC contract.

Configuration and defaults are defined by `RelayConfig` and `loadConfig` in
`relay/src/config.ts`. The canonical protocol behavior is pinned by the relay
suite; run it with `bun run --filter antgrid-relay test`.