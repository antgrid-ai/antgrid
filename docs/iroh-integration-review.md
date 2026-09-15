# Independent Iroh integration security review

Reviewed 2026-09-14 against the working implementation. This is a bounded code
review and backend HTTP qualification, not approval to enable Iroh in production.
The evolving upstream relay evidence and qualification limits are recorded in
`iroh-relay-upstream-audit.md` and `iroh-relay/HANDOFF.md`.

## Findings and disposition

| Finding | Evidence and disposition |
| --- | --- |
| Real OAuth metadata rejected by strict enrollment authentication | Actual Better Auth HTTP token/enrollment evaluation found Prisma metadata stored as a JSON string, while unit fixtures used objects. Fixed with `parseDeviceOAuthMetadata` in `web/src/models/device-oauth.ts`, shared by bearer middleware and transactional authorization. Malformed JSON and mismatched identities remain denied. Real HTTP evaluation now passes. |
| Wrong native handshake literal | Native admission had used `client-hello`; the protocol uses `handshake:client-hello`. Corrected in `bridge/src/peer/iroh-relay-client.ts`; real native E2E coverage is owned by the bridge gate. |
| App key rotation across selection awaits | Initial identity verification could use the old machine key while the selected lease wrapper captured a new key. The Dart implementer added captured machine key, endpoint ID/generation and approved-relay fingerprint checks before wrapper creation and subsequent dispatch. |
| Late handshake completion retained keys after cancellation | In-flight crypto could finish after cancellation and make the completed flag suppress erasure. The Dart implementer reports post-await cancellation/lease fences, explicit ownership transfer, late-result erasure and shared-secret cleanup in `connection_handshake.dart`. Parent owns serial Dart verification. |
| Approved relay configuration changed without replacing native endpoint | Cached endpoint configuration could continue using removed relay URLs. Both implementations now compare approved relay fingerprints and retire/recreate the endpoint. Existing link authorization must remain fenced by the captured fingerprint. |
| Project readiness depended on central stream acknowledgement | A locally attached stream predating native establishment could remain unadmitted during central outage. Bridge now retains `localAdmissions` and admits them from `onSessionEstablished`, while `centralStreams` independently gates WebSocket payload delivery. |
| Late native acceptance swallowed the selected WebSocket hello | An unconfirmed native carrier could occupy the peer map after the app selection timeout. Bridge now retires that empty carrier when the canonical WebSocket hello arrives, while retaining the single-writer guard for pending/established sessions. |
| Record size excluded route-header overhead | Bridge used a payload limit on an entire encoded route record. `records.ts` now uses shared `PEER_MAX_RECORD_BYTES`, with decoded payload validation separately retained. |
| Native write could remain pending indefinitely | `records.ts` now imposes a five-second write deadline, in addition to queue/byte limits. A timed-out write must retire its connection and cannot be replayed. |
| Unknown native failures treated as retryable network failures | Upstream Dart bindings provide untyped error/close strings. Dart implementer reports conservative terminal mapping for unknown connect/read/write/close errors; typed upstream cause support remains a qualification blocker. Bridge now emits distinct authorization/protocol application close codes, but the receiver still needs trustworthy typed cause handling. |
| Central dial serialized before native selection | Dart implementer reports central setup now starts alongside native selection; only the WebSocket factory awaits central readiness. This still requires actual outage/reconnect testing. |

## Remaining lifecycle checks

Endpoint IDs are permanently retained by the backend. Re-enrolling a revoked
endpoint with the same seed must fail; clients must surface the terminal stale
enrollment result or deliberately create a new protected key. Silent reuse or
automatic retry cannot bypass history. Dart maps registration conflict to a
terminal stale-enrollment result. Complete reseed/re-enrollment UX remains a
client lifecycle qualification item.

The review also flagged legacy credential records without `endpointSecret`:
`HostServer` has a legacy-client branch and the app runtime depends on that key.
The parent must ensure upgraded software provisions the protected key or fails
closed, so its own WebSocket sessions still obtain authoritative leases. Legacy
peer compatibility must not silently exempt an upgraded local process.

Reviewing guards is insufficient to prove every asynchronous interleaving.
Outstanding qualification includes queued dispatch expiry, credential/key
rotation during each native/E2E await, network-close causes, central outages,
blocked UDP, native late accepts and stream cancellation, background/resume,
and physical platform packaging. Authentication/protocol denial cannot justify
WebSocket fallback. Payloads and non-idempotent commands must never be replayed.

## Real HTTP authorization gate

`evals/support/iroh-authorization.ts` runs the actual web Hono/Better Auth stack
behind a loopback Bun HTTP server and an ephemeral PostgreSQL database. Test
fixtures bootstrap the signed-in account/subscription only. Device credentials,
OAuth tokens, endpoint challenges, signed registrations, snapshots, heartbeat
and device revocation use real HTTP routes. It does not install a fixture
authorization response or bypass the strict device bearer middleware.

`bun run --filter antgrid-evals test:evals:iroh-authorization`: **1 passed,
0 failed, 25 assertions**. It covers real device OAuth credential binding, sibling
and cross-account challenge rejection, invalid signature denial, single-use
challenge replay, eligible peer keys/endpoints, lease bounds, policy advancement,
endpoint rotation/history, globally retained endpoint IDs and device revocation
removing peer admission while queuing durable invalidation.

The authorization-only gate does not send native payloads. The separate bridge
native HostServer smoke uses controlled authorization/control fixtures.

## Combined backend-to-native gate

`bun run --filter antgrid-evals test:evals:iroh-host-authorization` runs actual
HTTP OAuth/device/endpoint enrollment and authorization against PostgreSQL,
production HostServer endpoint registration/lease management, native Iroh and
signed E2E handshakes. The app driver checks the remote endpoint and agent
transcript signature against its real authorization snapshot. The central
WebSocket welcome/control service is controlled and deliberately omits stream
registration acknowledgements; the native address is obtained from the local
host endpoint for a direct loopback connection. No authorization snapshot is
fabricated. Token maintenance is supplied an actual HTTP-issued OAuth token.

The gate reads distinct file contents from two real HostServer projects on the
same native connection while central control is offline. It then deletes the app
device through the actual account route, verifies stale bearer denial and peer
removal, and waits for the production periodic bridge refresh to close the native
pair. The final gate passed (1 test, 0 failures) in 24.93 seconds; native closure
occurred 19.95 seconds after revocation,
within the 60-second authorization maximum. The test explicitly distinguishes
revocation closure from its own watchdog cleanup.

This adds combined backend/native authorization evidence, but does not qualify
public-network discovery, deployed relay admission/disconnect, Flutter packaging,
mobile lifecycle or performance. The hand-written app protocol driver is not a
Flutter UI test; a controlled central welcome is not central JWT verification.
