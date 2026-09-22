# Relay (`relay/src/`)

Deep reference for the relay. Root `CLAUDE.md` holds the repo-wide gotchas,
commands, and conventions — this file loads only when working under `relay/`.

What may be written in any `CLAUDE.md`, this one included, is governed by
*Maintaining these files* in the root `CLAUDE.md`.

The central relay is a control plane. Remote payloads use the native Iroh
transport and never transit this WebSocket. The socket carries signed admission,
presence, policy/revocation, heartbeat and encrypted push delivery only.

- `server.ts` — the first text frame MUST be a signed v3 `hello` (anything else → `PROTOCOL_VIOLATION` + close 1008; there is also a hello-or-die timer). The verification sequence is numbered in source and MUST NOT be reordered. `relayHost` binds the normalized upgrade `Host` header, so the reverse proxy must preserve it. Config enforces the replay-TTL/clock-skew relationship at load. After admission, any binary frame and the retired `stream-open`/`stream-close` verbs are protocol violations and close 1008; there is no central payload or project-stream fallback.
- **Error contract is law:** every relay error frame carries required `retryable`. Authentication and protocol failures close the socket; recoverable control-plane errors do not.
- `connections.ts` — live connections only: an entry exists iff the socket is open and past hello. Epoch arbitration and its freshness guard are pinned by `tests/epochs.test.ts`. An AGENT deviceId is its machine `deviceUuid`; an APP deviceId is a per-machine slot `<accountDeviceUuid>#<machineDeviceUuid>`. Never treat a slot as an account device id: revocation uses `getByAccountDevice` so it reaches the bare holder and every scoped slot. Disconnect has no cascade close; opposite-type peers in the same account receive presence updates and keep their sockets.
- `replay-cache.ts` — the capacity-bounded `(deviceId, nonce)` replay guard. The record is inserted only after signature verification.
- `license/` — both device types authenticate with account tokens. Agent admission binds the token device UUID and pubkey; app verification deliberately does not bind the per-machine relay slot. `licenseIssuerUrl` is the public token issuer and is distinct from the possibly internal `licenseApiUrl` used for JWKS. Better-Auth client-credentials tokens identify the credential with `azp`; the custom `deviceUuid` claim identifies the account device. The relay checks identity and validity, not entitlement quantities. `/internal/revoke` accepts the bare account device id plus `userId` so a same-shaped device in another account is not evicted. `LICENSE_UNAVAILABLE` is retryable infrastructure failure; license verdicts are terminal.
- `rate-limiter.ts` — connection admission is limited per resolved client IP, JSON control messages use a per-connection token bucket, and push delivery has an independent per-agent fixed-window budget. Do not merge push and general control budgets: provider fan-out needs a tighter boundary.
- `license/internal-routes.ts` — HMAC-authenticated revoke, expiry, peer-policy and connection-inventory handlers. The inventory is identity-light liveness data; it has no payload/session counters.
- Client-IP resolution is shared from antgrid-wire and pinned by `tests/config.test.ts`. `TRUSTED_PROXY_IPS` must be narrow: every host in a trusted range can supply the reported client IP. Unset means forwarded headers are ignored.

**Security invariant:** no connection is admitted without a verified signed hello and a verified account token. The relay never accepts application payload bytes, project stream registration, or a compatibility route around native authorization. Revocation, expiry and policy changes remain immediate control-plane actions.