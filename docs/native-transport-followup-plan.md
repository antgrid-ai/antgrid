# Complete Native-Transport Simplification and Reliability Pass

## Summary

Implement every audit finding as a sequence of green, reviewable commits. This includes the full native wire redesign: peer-bound frames, removal of relay-era addressing, `FRAME_VERSION` 3, coordinated TypeScript/Dart migration, and no compatibility adapter.

The work will preserve endpoint keys and registrations, central control functionality, E2E semantics, native flow control, fragmentation, project streams, and per-machine central connections.

This revision also makes shutdown, recovery, lease refresh, and interrupted command behavior explicit. A timeout is never treated as proof that an owned resource was released, and a transport write is never treated as proof that a remote mutation executed.

## Staged Implementation

### 1. Harden central relay admission and configuration

- Add a socket-admission registry that atomically reserves global and per-IP capacity before WebSocket upgrade, releases reservations exactly once on upgrade failure or close, and counts sockets awaiting authentication.
- Extend socket phases to `awaiting-hello`, `authenticating`, `ready`, and `closed`. Move to `authenticating` before awaiting license verification, reject concurrent frames, and recheck phase after every await before epoch arbitration or insertion.
- Ensure authentication timeout covers both hello receipt and asynchronous verification. Closed or superseded sockets must never enter connection, liveness, or presence indexes.
- Flatten authenticated connection state: store required `uid` directly and remove unused name, IP, tier, JTI, optional-claims, and duplicate socket metadata.
- Make presence asymmetric:
  - Agents becoming available/unavailable notify same-account app slots.
  - A newly authenticated app receives the currently online same-account agents.
  - Agents never receive app presence; app disconnects produce no presence fan-out.
- Replace manual environment parsing with a Zod schema. Validate ports, positive limits and intervals, log level, replay/skew relationship, trusted proxies, and all-or-none FCM/APNs credential groups.
- Split pre-upgrade errors (`MAX_CONNECTIONS`, `RATE_LIMITED`) from WebSocket control errors. Retain only emitted control/license codes and remove pairing-era or otherwise unreachable codes and the unused Dart `RelayErrorCode`.
- Preserve binary and retired-stream rejection with `PROTOCOL_VIOLATION`/1008, generic unknown-message handling, epoch freshness, replay protection, push, policy, revocation, and heartbeat.

### 2. Separate app native lifecycle from central control

- Rename the app's composite `RelayConnection`/manager to `MachineConnection`/manager and `relay_mechanisms.dart` to the peer-oriented equivalent. Keep `RelayService` naming only for the genuine central WebSocket.
- Split policy into:
  - `NativeConnectionSupervisor`, owning `wanted -> coords -> payload -> established`, native backoff, cancellation fencing, and the sole awaited native release.
  - `CentralControlSupervisor`, owning central reconnect backoff, sticky supersession conflict, token refresh, and explicit Retry.
  - `MachineConnection`, coordinating shared resolved coordinates and account authorization verdicts without coupling either supervisor's retry state to the other.
- Make `PeerConnectionMechanisms` native-only. Move token minting and `RelayService.connect` into a separate central dialer; remove `_centralPending`, central URL state, and central disconnect from native release.
- Replace nullable mutable callbacks with a required typed peer-event stream covering session loss, takeover, peer rejection, and session replacement. Tests use interface-based fakes rather than subclassing production mechanisms.
- Give the native supervisor one `stop()` operation that fences late dials/handshakes, waits for the active attempt to settle, releases once, and then closes status streams. Reapers and managers must not call release independently.
- Make `stop()` synchronously fence generations, disable dispatch, cancel timers and queued work, and request cancellation/closure. Allow five seconds for graceful teardown, force carrier closure, then allow five seconds for confirmation. Return typed `cleanupIncomplete` when ownership is still unresolved; repeated stops share one completion and late results are disposed without publishing readiness. Unresolved attempts remain in bounded ownership accounting until they finish or endpoint destruction is confirmed.
- Make presence wake-up edge-triggered and bounded: only a false-to-true transition while disconnected may accelerate one retry per machine per 30 seconds. Presence never resets the failure counter, starts a concurrent attempt, closes a session, or rekeys it. Preserve jittered exponential backoff from one second to a 30-second cap.
- Keep central supersession sticky until explicit Retry. A central outage or conflict does not tear down a healthy native session while its authorization lease remains valid.
- Remove unused supervisor methods and parameters, including unused payload/coordinate notifications and `retryable` arguments.
- Replace duplicated controller-plus-`Stream.multi` replay implementations with one gap-free seeded broadcast primitive.
- Derive remote boot UI exclusively from native supervisor status and checkout readiness. Reading UI status must not instantiate a central connection, and a healthy native session must remain shown as usable during central outage.
- Centralize `BlockReason` labels/actions so drawer, workspace, and status helpers cannot drift.

### 3. Serialize enrollment, provisioning, and teardown

- Introduce a long-lived `PeerRuntimeOwner` with serialized `obtain`, `replace`, and `clear` operations. A different enrollment cannot be returned until the previous native endpoint, lease refresh, HTTP client, and keys are fully disposed.
- Key runtime identity by account, enrollment ID, and endpoint-secret identity. Re-reading the same identity returns the existing runtime; rotation awaits teardown before construction.
- Make machine connection `release` and `disposeAll` awaitable. Hard sign-out must await project eviction, machine/control teardown, and `PeerRuntimeOwner.clear()` before deleting credentials or invalidating identity providers.
- Sign-out blocks new work immediately. If cleanup cannot be confirmed, expose a locked cleanup-error state and prevent a different identity from starting.
- Decouple `PeerConnector.connect` from `RelayService`; pass a small peer-diagnostics sink instead.
- Replace dynamic/WidgetRef-based provisioning functions with a typed provisioning coordinator using injected dependencies. It owns provisioning, local-host UUID persistence, analytics, provider invalidation, and device-cap results without retaining UI refs across awaits.
- Route post-sign-in provisioning and device-cap retry through the same coordinator and success side effects.
- Preserve authoritative lease duration limits and request-start-based elapsed-time deadlines. Refresh after one third of the accepted duration with plus or minus 10% jitter. Bound each request by ten seconds or the remaining lease validity, whichever is shorter; keep one refresh in flight and fence late responses.
- Retry transient refresh failure with jittered exponential delay capped at five seconds only while the original lease remains valid. Network failure, central reconnect, and native success never extend validity. After expiry the native supervisor owns reconnection.
- Denial, revocation, rotation, and remote-access-off synchronously fence dispatch. Resume requires fresh authorization. Recheck authorization and generation when queued work leaves the queue and immediately before a protected handler runs.

### 4. Make the bridge payload owner natively typed

- Replace `PeerSessionOwner` with a native session owner whose carrier writes are required abstract methods or constructor-injected native carrier methods. Remove the optional mutable `payloadSink`, default `"relay"` transport, silent false/null fallback, and relay-named logger component.
- Delete uncalled routed-frame rate-limit/drop diagnostics, timers, counters, and summaries.
- Remove relay-presence retention from E2E sessions: no `reachable`, offline timestamp, offline TTL, presence-driven key retention, or test-only online/offline simulation. A live native connection/session is reachable; native loss immediately retires it.
- Remove deprecated single-peer getters and production-unused callbacks. Drive project availability from session establishment/removal.
- Consolidate native admission state:
  - A bounded admission registry owns anonymous incoming attempts.
  - After endpoint identity resolution, one `NativePeerContext` per peer owns the carrier, authorization generation, handshake candidate, established E2E session, timers, and records.
  - One `retirePeer` path handles authorization loss, protocol violation, cancellation, connection loss, and shutdown without recursive teardown.
- Split configuration into explicit `CentralControlOptions` and `NativePeerOptions`; `NativeHostOptions` contains these as separate nested values rather than intersecting payload and central callbacks.
- Rename stale bridge test suites and internal symbols from `relay-client` to either `central-control` or `native-session`. Inject clock, random, and scheduler seams instead of patching globals/private fields.
- Preserve record, queue, fragmentation, and credit bounds. Do not introduce disconnected mutation queues.

### 5. Introduce peer-frame protocol v3

- Bump `FRAME_VERSION` from `0x02` to `0x03`; version 2 is rejected with `BAD_VERSION`. No dual decoder or feature flag is added.
- Move endpoint-only definitions out of `relay-protocol`:
  - `PeerFrameHeader { type: "message", channel }` in `peer-protocol`.
  - `StreamEnvelope` and the control stream identifier in `session-protocol`.
  - Rename route-frame encode/decode APIs to peer-frame terminology.
- Make `PeerLink` intrinsically peer-bound:
  - `sendFrame(channel, payload, {kind})`
  - `Stream<IncomingPeerFrame>` containing channel, kind, and payload only.
  - Remove destination/source fields and relay-shaped method names throughout the Dart session, handshake, leased link, Iroh transport, bridge, and eval clients.
- Bridge internals continue selecting a peer context before writing, but no destination is serialized inside that peer's authenticated connection.
- Generate a checked-in transport-contract vector from `antgrid-wire` containing frame bytes, version, kinds, ALPN, header/payload/record limits, flow-control constants, fragmentation limits, and authorization bounds. Consume it from TypeScript and Dart tests.
- Regenerate envelope, hello, endpoint-registration, and push fixtures. Expand the clean-fixture gate to cover every generated vector.
- Preserve E2E transcripts and keys, fragmentation, credits, stream envelopes, lease enforcement, and checkout routing unchanged.
- Classify pending remote requests with an explicit read-only allowlist; unclassified requests are mutating. Surface local outcomes as `notSent`, `confirmed`, or `outcomeUnknown`.
- A write acknowledgement is not execution confirmation. On disconnect, timeout, or generation replacement, a dispatched mutation without an application result becomes `outcomeUnknown` and is never automatically replayed, including terminal input, reconnect hydration, or host-restart recovery.
- Reconnect hydrates authoritative state through fresh reads. Unresolved mutations show 'Connection lost; execution could not be confirmed' and require a new user action. Do not add a durable operation journal or generic deduplication protocol.

### 6. Make evaluations production-equivalent and remove stale surfaces

- Split the TypeScript evaluation client into:
  - `CentralTestClient` for authentication, epoch, supersession, control errors, and forge tests.
  - `NativeEvalSession` for enrollment, Iroh records, E2E, flow control, fragmentation, streams, and scenario APIs.
  - A small scenario facade may compose both, but central binary frames are never fed to the native decoder.
- Validate every native peer header before dispatch. With v3 this means exact message type and channel; peer identity comes from the authenticated connection.
- Add a strict snapshot round trip that never reconnects or rekeys. Use it for central-outage tests and assert the native connection/E2E generation remains unchanged. Keep recovery helpers only for tests explicitly exercising recovery.
- Migrate or remove the stale reconnect test that handshakes without opening a native connection.
- Give both TS and Dart harness setup a LIFO cleanup stack so partial startup failures terminate subprocesses, close servers/endpoints, release ports, and remove temporary directories.
- Split Dart CLI commands into independent control-connect, peer-connect, handshake, and disconnect operations. Failed peer setup rolls back only peer state; central reconnect cannot recreate native state.
- Create the Dart endpoint only after the enrollment ID is known, use an enrollment-keyed endpoint store, construct an `AuthorizationLease`, and wrap the dialed link in `LeasedPeerLink`. Remove `authorized: () => true`.
- Rename handshake helpers around native session establishment and retain bounded retry only for a typed inventory/authorization race, not central presence.
- Delete unused eval aliases/helpers, the nonexistent pairing script, unused send methods, obsolete compatibility switches with no callers, and the permanently skipped relay-preview suite. Existing native preview/tunnel gates remain.
- Clean package descriptions and transport comments that still claim central relay payload ordering or drops.
- Record structured lifecycle diagnostics for attempt/session generation, retry reason, teardown outcome, and remaining lease time without credentials, keys, or payload contents.

## Public API and Type Changes

- `PeerLink.sendFrame(String channel, Uint8List payload, {FrameKind kind})`
- `IncomingRouteMessage` becomes `IncomingPeerFrame`, without `from`.
- `RouteHeader` becomes `PeerFrameHeader`, without `to`.
- `encodeRouteFrame`/`decodeRouteFrame` become peer-frame equivalents.
- `FRAME_VERSION = 0x03`.
- App-facing `MachineConnection`, `NativeConnectionSupervisor`, `CentralControlSupervisor`, typed peer events, and awaitable release APIs replace relay-named composite APIs.
- Bridge options become explicitly nested central/native configurations.
- Retired names and APIs are removed outright; no deprecated aliases are retained.
- The package name `antgrid_relay_client` and existing `agent:enableRelay` application verbs remain unchanged; renaming those is a separate package/application-protocol migration.

## Test and Acceptance Plan

- Relay: concurrent hellos, close/timeout during delayed license verification, many delayed hellos across IPs, reservation release, epoch replacement, replay/skew, asymmetric account presence, revocation/policy/push, binary and retired-verb rejection, and invalid configuration boundaries.
- App: central outage while native stays connected, repeated-online backoff behavior, explicit supersession Retry, release exactly once, late dial/handshake fencing, enrollment replacement ordering, sign-out ordering, provisioning disposal, and UI status independent of central authentication.
- Deterministic lifecycle: concurrent hello, close during verification, delayed dial/handshake, never-settling close, duplicate stop, late completion, paused listeners, enrollment replacement, and sign-out. Assert bounded return times, no replacement before confirmed cleanup, and no stale-generation dispatch.
- Combined failures: rotation during reconnect; sign-out during handshake; expiry during queued work; central conflict during native recovery; repeated presence flapping; and resume while an old authorization request is pending.
- Command safety: disconnect before send, during write, and after execution but before reply. Assert `notSent`/`outcomeUnknown` classification, zero automatic mutation replays, and fresh-read hydration after reconnect.
- Authorization: transient backend failure retains access only to the original deadline; denial revokes immediately; wall-clock changes cannot extend validity; late refreshes cannot revive invalidated generations.
- Bridge: bounded admissions, authorization rotation/revocation/lease expiry, one-path peer teardown, multiple peers/projects, switching without redial, remote-access-off, restart/resume, terminal/files/Git/preview/session bus, and no presence-retained sessions.
- Wire/Dart: v3 golden bytes, v2 rejection, no serialized peer address, constants parity, malformed headers, record bounds, E2E, credits, fragmentation, and lease fencing.
- Evals: strict central-outage survival without repair, native restart/rekey, reconnect, two-machine operation, cleanup after injected setup failure, Dart revocation/expiry/rotation, cross-language native interop, real-backend authorization, host authorization, and resume gates.
- Run workspace typechecks and suites per component; run Flutter/Dart analysis and tests serially, use `flutter test -j 2` when other sessions are active, run font-token checks, and never run bare root `bun test`.
- Record exact results and infrastructure limitations in the simplification/qualification ledger. Forced-relay QUIC, WAN/blocked UDP, physical-device, sleep/wake, and performance qualification remain unqualified unless actually exercised.
- Run reproducible seeded state-machine fault tests and an explicit 30-minute loopback soak. Track owned resources across cycles and require no stale sessions, leaked admissions, duplicate commands, or resource growth after cleanup settles.

## Assumptions

- Bridge, relay, app, Dart packages, and eval clients are upgraded together; breaking beta compatibility is accepted.
- Existing enrollment records and endpoint keys remain valid; the frame change requires software upgrade, not re-enrollment or database reset.
- Central sockets remain per machine; account-level central connection sharing is excluded.
- Production checkout authorization, local desktop transport, E2E cryptography, and host-owned project streams remain unchanged.
- Capability compatibility for `pullsTree`, `terminalFramesV1`, and checkout routing remains; only unused eval switches are removed.
- No deployment, Aspire restart, or push is included.
- Every staged commit must pass its affected gates before the next stage.
- Preserve the unrelated unstaged preview-picker edit and the already committed `.gitignore` change.
