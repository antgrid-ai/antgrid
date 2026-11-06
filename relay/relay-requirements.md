# Antgrid Central Relay Requirements

The relay is the authenticated central control plane for Antgrid. Remote
application payloads use native Iroh peer connections; they do not pass through
this service. The relay is stateless apart from bounded in-memory connection,
license-cache, replay, rate-limit and sealed bus-queue state. Nothing is
persisted: a restart drops every queued blob and senders resend.

## Responsibilities

The relay:

- authenticates agent and app WebSockets with the signed v3 `hello` contract;
- arbitrates one live socket per relay device identity using epochs and signed-hello freshness;
- publishes account-scoped `peer-online` and `peer-offline` discovery hints to apps and to agents;
- queues and forwards sealed session-bus blobs between an account's agents, until
  the recipient acks or the entry expires;
- applies license revocation, account expiry and peer-policy notifications;
- forwards end-to-end encrypted mobile push blobs to FCM or APNs;
- maintains protocol and application heartbeat liveness;
- exposes health, control-plane metrics and authenticated internal operations.

The relay does not forward binary application frames, register project streams,
store readable offline messages, establish E2E payload sessions, or authorize
native peer traffic. Those responsibilities live at the endpoints and the native
transport. The only payload it holds is a bus blob sealed to the recipient agent's
key, which it cannot open; it reads the envelope fields (ids, size, TTL) and
nothing inside the blob. Bus blobs go only between agents of one account and are
never delivered, forwarded or flushed to an app; an app that sends a bus frame
gets back only a `not-agent` refusal.

## WebSocket protocol

The first frame must be a text v3 `hello` matching the shared schemas in
`packages/antgrid-wire/src/relay-protocol.ts`. It is signed over the normalized
relay host and carries a required account token. Invalid, replayed or unexpected
first frames receive a typed terminal error and close code 1008.

After `welcome`, accepted client control messages are:

- `ping`;
- `push:deliver` from an authenticated agent;
- `bus:send`, `bus:ack` and `bus:drain` from an authenticated agent;
- no second `hello`.

The server may send `welcome`, typed `error`, `peer-online`, `peer-offline`,
`pong`, `peer-policy-changed` and `push:result` frames, `bus:deliver` only to
bus-capable agents, and `bus:receipt`, `bus:acked` and `bus:refused` to the
sender of a `bus:send`. Every error includes a `retryable` boolean.

An agent opts in to bus frames with `bus: 1` in its `hello` (outside the signed
body). `welcome` carries `bus: 1` to every agent, opted in or not, advertising
the relay. A recipient that did not opt in is never sent a bus frame: a send to
it is refused `recipient-outdated` and nothing is queued. A recipient the relay
has not seen is queued, because the relay has no account roster, and flushed on
its first hello within the same per-recipient redelivery budget as a drain.

Queued entries are keyed by account and device, bounded per recipient, per sender
and in total, and clamped to a maximum TTL. An entry stays until the recipient's
`bus:ack` (forwarded unverified to the sender's current socket), its expiry
(the sender is told `expired`), or a revoke or expire purge. An entry that stays
unacked is re-sent to its live recipient on a new connection, after a minute on
the same one, and on `bus:drain`, each charged to a per-recipient byte budget.

Any post-auth binary frame is a `PROTOCOL_VIOLATION` and closes with 1008.
Unknown future JSON control messages remain `INVALID_MESSAGE` errors so current
clients can ignore unsupported extensions without losing a healthy socket. A
text frame over `RELAY_MAX_CONTROL_FRAME_BYTES` drops the connection without a close
frame (the client sees 1006) before it reaches JSON parsing.

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
- JSON controls, encrypted push delivery and sealed bus bytes have independent bounded rate limits.
- Bus blobs are opaque to the relay and never logged; logs carry ids, sizes and outcomes only.
- Forwarded client-IP headers are honored only from configured trusted proxies.
- Logs and internal inventory never contain application payloads or project data.

## HTTP surface

- `GET /health` reports status, uptime, connection count and version.
- `GET /metrics` reports active control connections, uptime and the bus queue's message and byte gauges.
- `GET /ws` upgrades an admitted WebSocket.
- `POST /internal/revoke`, `/internal/expire`, `/internal/peer-policy` and
  `/internal/connections` require the internal HMAC contract.

Configuration and defaults are defined by `RelayConfig` and `loadConfig` in
`relay/src/config.ts`. The canonical protocol behavior is pinned by the relay
suite; run it with `bun run --filter antgrid-relay test`.