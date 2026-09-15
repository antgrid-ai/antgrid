# Antgrid P2P transport research

Research checkpoint: 2026-09-14. This records source inspection and architectural recommendations, not a completed migration or measured transport benchmarks.

Implementation follow-up: [Iroh qualification checkpoint](iroh-qualification.md)
records the approved migration decisions and Windows Bun ↔ Dart encrypted-terminal
prototype results, including compiled packaging and rejection cases. The gate has not passed; no production transport
has changed. Historical recommendations below are superseded by that checkpoint
where they leave scope, self-hosted relays, central WebSocket retention, the
60-second lease, upstream-only bindings or Intel macOS retirement undecided.

## Objective and current decision

The user wants lower server bandwidth and lower latency for source-machine to native Flutter app communication. They prefer effort estimates in **T-shirt sizes**, not weeks.

- SSH is a poor default for automatic internet connectivity to customer machines behind NAT. WebRTC is a better fit for that workflow.
- **Decision confirmed by the user on 2026-09-14: proceed in the Iroh direction.** Iroh is the selected transport direction, not an unresolved shortlist candidate.
- Iroh is the closer architectural fit for native P2P with relay-to-direct path changes managed inside the transport.
- libdatachannel/WebRTC findings below are retained as comparison research, not the current implementation direction.
- Iroh now has Windows native/compiled encrypted-terminal prototype results using existing session drivers and fixture admission/project handlers. Mobile, forced-relay and production authorization qualification and performance benchmarks remain outstanding. Choosing Iroh does not establish release readiness.
- Estimated complete Iroh migration: **L**, potentially **XL** if native bindings/builds need substantial ownership. This is a transport-layer refactor, not a whole-product rewrite.

The bandwidth benefit comes from the fraction of **bytes** transferred directly, not from replacing one relay protocol with another. TURN or Iroh-relayed payloads still consume server ingress/egress. Measure direct bytes / total bytes, including startup and fallback traffic. Do not use vendor direct-connection percentages as Antgrid forecasts.

## Existing Antgrid behavior verified in source

- Persistent WebSockets already exist. App: one `RelayConnection` / `RelayService` per machine, shared by its project streams. Bridge: persistent relay socket with heartbeat and reconnect handling.
- `app/lib/providers/relay_connection.dart`: `RelayConnectionManager.connectionFor` reuses machine connections; resume reevaluates existing connections rather than unconditionally replacing them.
- `packages/antgrid_relay_client/lib/src/machine_session.dart`: one E2E session per machine, project envelopes, fragmentation, liveness, scheduling. Currently directly depends on `RelayService`; relay disconnection tears down the session.
- `packages/antgrid_relay_client/lib/src/agent_transport.dart`: higher-level service abstraction is already present.
- `bridge/src/relay-client.ts`: socket lifecycle, E2E sessions, routing and scheduling are intertwined and need separation.
- The control plane and projects share a machine socket in this checkout. Do not assume the reported control/data readiness timings describe separate physical connections. `control` and `preview` are logical traffic channels.
- The user reports control readiness around **5–6 seconds**, data readiness around **9–10 seconds**. Whether these are cumulative or separate intervals was not clarified. No runtime trace was collected.
- Handshake timeout (10 seconds) and `app:ready` retransmission interval (2 seconds) are recovery settings, not mandatory waits or a demonstrated cause of these timings.
- Trace: connect requested → socket open → relay authenticated → peer discovered → E2E established → project bound → first usable terminal frame.
- A previously suggested under-2-second healthy-network startup is an engineering target only, not a prediction or benchmark.

With Iroh, preserve one connection per app↔machine pair. Opening another project must reuse it, although authorization, project initialization and state hydration still take time.

Relevant existing boundaries:

- Account/device trust, the live machine remote-access switch, project catalog checks (`seenProjects`, `isSafeProjectId`) and checkout routing remain mandatory on direct paths.
- `bridge/src/message-bus.ts` currently identifies sources as `loopback` or `relay`. Direct remote traffic must retain remote authorization semantics.
- `remoteFrameAllowed` in `bridge/src/agent-core.ts` exempts loopback traffic. An SSH tunnel into the existing loopback endpoint must not silently become the supported remote admission path.
- Preserve application E2E encryption and signed device identity handshake initially, even though both candidates have transport encryption.
- Keep Flutter-specific adapters outside the Flutter-free relay-client core; the CLI eval client must exercise the real new transport too.
- Do not move ELv2-owned code into Apache packages while extracting abstractions.
- `packages/antgrid-wire/src/flow.ts` is tuned for current socket behavior and large fragments. New transports still need bounded queues, application consumption credits and appropriate framing.
- Never replay keystrokes or non-idempotent commands automatically after a path failure. Transport send completion is not execution confirmation.

## Iroh migration scope and effort

Source-based estimate: **L overall**, escalating to **XL** if Antgrid must maintain substantial custom native bindings or platform builds. Sizes below overlap and are not additive. No migration prototype has validated these estimates yet.

| Area | Required change | Size |
|---|---|---|
| Bridge networking | Separate WebSocket lifecycle/routing from E2E sessions and project dispatch; add Iroh endpoint and per-peer connections | L |
| Dart networking | Decouple `MachineSession` from `RelayService`; adapt handshake, connection state, reconnect and framing | L |
| App UI and feature services | Mostly retain; update connection providers, status and lifecycle handling | S–M |
| Identity and authorization | Bind Iroh endpoint IDs to account/device identities; enforce authorization and revocation on direct connections | M–L |
| Relay infrastructure | Deploy Iroh relay and integrate admission, active disconnect, abuse controls and monitoring; hosted versus self-hosted remains undecided | M–L |
| Packaging and qualification | Verify Bun compiled binaries, Flutter native libraries, pure-Dart eval client and mobile/network recovery | L |

### Reuse versus refactor

Preserve existing application messages, project-stream envelopes, terminal/file/Git/preview handlers, most UI, application E2E encryption, signed-device verification, remote-access policy and checkout routing. Retain bounded queues and application-level backpressure; QUIC does not replace application consumption limits.

`AgentTransport` in `packages/antgrid_relay_client/lib/src/agent_transport.dart` is the existing feature-service boundary that can limit downstream churn. It is not a complete low-level transport abstraction: `MachineSession` still directly owns a `RelayService`, and relay disconnection currently tears down the session. Separate peer-session health from central control connectivity and Iroh path status. A direct/relayed path change alone must not reset projects or replay commands; actual connection failure still requires recovery, and authorization loss must remain enforceable.

`RelayClient` in `bridge/src/relay-client.ts` combines socket management, peer discovery, encryption, project streams and scheduling. Extract reusable session/project responsibilities from relay-specific control messages and socket lifecycle. Iroh replaces network traversal and payload transport, not account membership, project catalog authorization, state hydration or command semantics.

### Recommended rollout, not yet an approved implementation plan

1. **M-sized vertical prototype:** packaged Bun bridge ↔ physical Flutter device, carrying the existing encrypted terminal/project protocol over Iroh. Exercise direct and forced-relay paths, project reuse and pure-Dart client compatibility before expanding the migration.
2. **L-sized production migration:** integrate identity/admission/revocation, connection lifecycle, all supported release platforms, observability and regression coverage. Keep WebSocket payload fallback during rollout; do not automatically replay non-idempotent actions when switching transports.
3. **Retire legacy payload routing after qualification.** Initially retain a small authenticated WebSocket control connection for inventory, presence and revocation. This is a recommendation, not a user decision to retain WebSockets permanently. Eliminating that connection too requires replacing its control-service responsibilities and expands scope. This central control connection is distinct from the app↔machine logical control stream, which can travel over Iroh alongside project traffic.

The selected Iroh direction does not yet decide relay hosting or authorize deployment/implementation. Native packaging and direct-path authorization/revocation are the main uncertainties, rather than sending terminal bytes. Bandwidth savings depend on direct payload traffic; retaining a small central control connection does not defeat that objective. Startup and interactive latency improvements remain unmeasured.

## Iroh fit

Iroh combines QUIC, endpoint-public-key identity, NAT traversal and encrypted relay fallback. It can establish via a relay and transition traffic to a direct path without making the application replace its logical connection.

- Relay connections themselves use HTTPS/WebSocket over TCP 443. This is compatible with the bandwidth objective; eliminating WebSockets as a technology is not the objective.
- Use one endpoint per process and one connection per app↔machine pair; initially carry existing project envelopes over a small number of reliable QUIC streams. Add bounded length framing because QUIC streams are byte streams.
- Official native JavaScript binding: `@number0/iroh`, implemented with Node-API. Bun compatibility and compiled executable loading remain unverified.
- Official JS package configuration inspected did not list Intel macOS, while Antgrid builds Intel and Apple Silicon bridge binaries. Check the selected published release; a custom Intel build may be required.
- Community Dart repository `snowpinelabs/iroh_dart` now exposes `iroh_quic` (Flutter-free API with native Rust library for CLI/desktop) and `iroh_flutter` (platform packaging). Earlier references to a single `iroh_dart` package were superseded by this discovery.
- The package split is a good fit for Antgrid's Flutter app plus pure Dart eval harness, but advertised support is not release qualification. Audit callback lifecycle, teardown, memory, mobile resume and supported ABI builds.
- Current Iroh browser/WASM support is relay-only. If browser-based remote control becomes a priority, WebRTC has a major advantage for server-bandwidth reduction.

Sources:

- <https://github.com/n0-computer/iroh>
- <https://docs.iroh.computer/concepts/relays>
- <https://docs.iroh.computer/configuring-networks>
- <https://docs.iroh.computer/languages/wasm-browser>
- <https://github.com/n0-computer/iroh-ffi>
- <https://github.com/n0-computer/iroh-ffi/blob/main/iroh-js/package.json>
- <https://github.com/snowpinelabs/iroh_dart>
- <https://pub.dev/packages/iroh_quic>
- <https://pub.dev/packages/iroh_flutter>

## libdatachannel fit and TURN caveat

Likely integration: Bun → `node-datachannel` ↔ WebRTC ↔ `flutter_webrtc` → Flutter. libdatachannel is not required on both ends. Using Flutter WebRTC does not give the app libdatachannel's smaller native footprint.

- Native WebRTC DataChannels support reliable ordered delivery. Start with that for commands/files and existing terminal protocols.
- Separate control and bulk channels, but they still share network capacity/congestion control. Bound bulk queues and respect negotiated maximum message sizes.
- Media support can be disabled in libdatachannel builds.
- `node-datachannel` offers desktop native binaries including Intel macOS; actual Bun release packaging remains untested.
- Bun documents embedding `.node` addons; dynamic loaders may require explicit native-addon imports. Test `bun build --compile`, not just `bun run`.
- **TURN over TCP/TLS requires libnice according to libdatachannel's C API documentation. The default build uses libjuice.** A `turns:` URL alone does not prove the shipped bridge can operate when UDP is blocked.
- The inspected node binding references libdatachannel v0.24.5; its `USE_NICE` default is OFF. Verify selected release artifacts rather than assuming their backend.
- Test UDP blocked on the bridge, on the app, and on both. TURN TCP/TLS governs the client-to-TURN leg; the TURN-to-peer allocation uses UDP.
- Signaling, ICE integration, and network-change recovery remain application work. Keep a lightweight authenticated signaling service.
- For migration, retain WebSocket payload fallback until qualification. Final payload architecture may be WebRTC direct/TURN only; signaling WebSocket bandwidth is small.

Sources:

- <https://github.com/paullouisageneau/libdatachannel>
- <https://github.com/paullouisageneau/libdatachannel/blob/master/DOC.md>
- <https://github.com/paullouisageneau/libdatachannel/blob/v0.24.5/CMakeLists.txt>
- <https://github.com/murat-dogan/node-datachannel>
- <https://github.com/flutter-webrtc/flutter-webrtc>
- <https://bun.com/docs/bundler/executables#embed-n-api-addons>

## Latest investigation: customer-device relay credentials

### Correction to the earlier conclusion

The managed-services documentation says a turnkey backend-issued per-endpoint credential flow is not implemented. **It is too strong to conclude backend issuance is impossible:** the checked-out SDK already exposes the signing and token-attachment primitives. Actual acceptance and lifecycle behavior on a managed relay are unverified.

Distinguish:

| Credential | Location | Purpose |
|---|---|---|
| Endpoint private key | Customer device | Prove ownership of that endpoint identity |
| Iroh Services project signing secret | Antgrid-controlled backend only | Issue relay capabilities |
| Endpoint-scoped relay token | Customer device | Limited relay use; cannot mint arbitrary tokens |

Never distribute the project-wide signing secret in an Antgrid app/bridge binary or customer configuration.

### Managed relay: source-supported issuance approach

In the local `iroh-services` checkout:

- `iroh-services/src/api_secret.rs`: `ApiSecret` exposes the issuer `secret` and services `remote` endpoint.
- `iroh-services/src/caps.rs`: public `create_api_token_from_secret_key(private_key, local_id, max_age, capability)` takes the **issuer private key and recipient public EndpointId**, not the recipient's private key. `Caps::relay_use()` restricts capabilities to relay use.
- `iroh-services/src/token.rs`: `ApiToken::encode()` serializes the RCAN; `expires_at()` exposes expiry.
- `iroh-services/src/preset.rs`: `PresetBuilder::build()` creates that token for the endpoint, encodes it as lowercase unpadded Base32, then calls `RelayMap::with_auth_token`.
- The normal preset keeps the project secret because it also configures services. A customer integration should attach a backend-issued token to an ordinary endpoint/relay configuration instead.
- In Iroh core, `iroh-relay/src/relay_map.rs` exposes `RelayConfig::with_auth_token`. Native relay clients send it as `Authorization: Bearer`; WASM uses a query parameter.
- Official FFI `src/relay.rs` exposes `RelayConfig.auth_token`; this does not establish equivalent functionality or live refresh behavior in every selected JS/Dart release.

Proposed flow: authenticated enrollment + endpoint proof of possession → backend verifies device/entitlement → backend Rust signer issues short-lived relay-only token for that endpoint → customer receives token and relay URLs → customer configures relay connection.

Use the upstream encoder behind Antgrid's backend rather than independently recreating RCAN serialization in TypeScript. Pin compatible versions. Test token renewal without rebuilding the whole peer session. Merely updating a token does not prove an already-open relay connection reauthenticates.

Managed-relay uncertainties:

- Actual acceptance of independently backend-minted tokens.
- Selected Node/Dart binding support for token injection and refresh.
- Per-device/token revocation versus the documented project-issuer/API-key revocation.
- Whether expiry is enforced on existing persistent relay connections, not only at admission.
- Managed service support/contract for this custom integration.

Sources:

- <https://docs.iroh.computer/iroh-services/access>
- <https://github.com/n0-computer/iroh-services/blob/1a483f3bdc14f3874126870e407c7f0160d43c54/iroh-services/src/caps.rs>
- <https://github.com/n0-computer/iroh-services/blob/1a483f3bdc14f3874126870e407c7f0160d43c54/iroh-services/src/preset.rs>
- <https://github.com/n0-computer/iroh-ffi/blob/main/src/relay.rs>

### Self-hosted relay: preferred initial Antgrid approach

**A separate customer relay token can be avoided.** Stock relay HTTP admission can check a device's authenticated endpoint identity against Antgrid's database.

Verified locally:

- `iroh-relay/src/server/http_server.rs`: `handshake::serverside` authenticates the endpoint before constructing `ClientRequest` and calling authorization.
- `iroh-relay/src/server.rs`: `ClientRequest.endpoint_id()` is proven by the relay handshake, not trusted client metadata. `AccessControl::on_connect` runs before registration.
- `iroh-relay/src/main.rs`: `AccessConfig::Http` and `http_access_check_inner` implement an external authorization callback.
- Configuration: `access.http.url` points at an Antgrid internal authorization endpoint; `access.http.bearer_token` or `IROH_RELAY_HTTP_BEARER_TOKEN` authenticates relay → backend. This secret remains server-side.
- Callback is an HTTP POST carrying `X-Iroh-Endpoint-Id`, generated from the proven endpoint ID.
- Admission requires HTTP **200** and body exactly **`true`**. All completed errors/other responses deny.
- Stock callback forwards the endpoint ID, **not the customer's bearer token**.
- No explicit callout timeout was configured in the inspected HTTP client construction/request; use a bounded implementation for production.
- Default relay access is `Everyone`; production must explicitly configure admission.
- Static `shared_token` mode is not the recommended customer model; it has no individual runtime revocation flow.

Antgrid enrollment/design work:

1. Generate/persist an endpoint key on each customer device.
2. Bind its public ID to an authenticated Antgrid account/device registration with proof of endpoint-key possession.
3. Prefer a separate endpoint key per account/device enrollment: Antgrid device rows are unique by `(userId, deviceId)`, not globally by deviceId.
4. Authorize relay admission by endpoint registration, active/revoked status and relay entitlement.
5. Authenticate the backend callback caller; never expose a client-callable bypass using only an endpoint header.

### Revocation and scope are mandatory follow-up work

Stock HTTP admission runs **once when opening the relay connection**. Revoking a database row blocks future admissions but does not automatically close existing connections.

- `iroh-relay/src/server/clients.rs`: public `Clients::disconnect(endpoint_id, connection_id)` can close one or all connections for an endpoint.
- `iroh-relay/src/server.rs`: `Server::relay_service()` exposes runtime relay service access; its client registry is reachable through `RelayService::clients()`.
- A small Rust relay wrapper can embed upstream Iroh, expose authenticated internal revoke operations and track connection lifecycle. No packet-protocol rewrite is indicated.
- Handle the race between an in-flight allow decision and a revocation; denying new connections and disconnecting old ones must not leave a newly admitted connection behind.
- Current Antgrid `relay/src/license/internal-routes.ts` closes the revoked account device's relay sockets. Direct connections will require revocation propagation to the bridge too.
- **Relay revocation stops relay usage; it does not stop an established direct peer session.** Bridge-side account/device authorization and the live remote-access switch must apply on every path.
- Define behavior when the bridge cannot receive central revocation. A bounded authorization lease can limit stale access; immediate revocation cannot be guaranteed while the revocation channel is unreachable.
- Token expiry checked only at admission does not bound the lifetime of a persistent connection. Explicit expiry enforcement/revalidation is required if that bound is desired.
- Admission is not per-account bandwidth quota enforcement or same-account peer routing. Preserve bridge peer authorization and separately design relay abuse/bandwidth controls.

Latency: HTTP authorization adds a backend call at relay admission, not per command/project. Co-locate services, index endpoint lookup, bound timeout, and define cache invalidation if caching decisions. Locally verified scoped tokens are a later option if admission latency/backend dependence warrants their lifecycle complexity.

Effort for credential/admission work only: basic enrollment + HTTP admission **M**; production revocation, quotas, outage behavior and integration **L**. This is part of, not an additional arithmetic estimate on top of, the overall migration scope.

## Local research checkouts

The user explicitly authorized checking out Iroh locally. Public shallow clones were created outside the Antgrid worktree:

```text
C:\Users\Admin\AppData\Local\Temp\antgrid-iroh-auth-a3d6e5dc94334df8b5a00eaf67b048b1\iroh
  commit: 2ed94c8a14e151d19ebec2946da2f61c93ca2dc8
  commit date: 2026-09-14
  inspected iroh-relay manifest: 1.2.0

C:\Users\Admin\AppData\Local\Temp\antgrid-iroh-auth-a3d6e5dc94334df8b5a00eaf67b048b1\iroh-services
  commit: 1a483f3bdc14f3874126870e407c7f0160d43c54
  commit date: 2026-09-03
  inspected iroh-services manifest: 1.0.0
```

These are source snapshots, not proof the same features exist in every published binary. GitHub/web cached paths sometimes differed from the checked-out layout; use the local source and exact revisions above for follow-up. The services repo is a workspace: sources are under `iroh-services/src/`, not root `src/`.

No source modifications or runtime tests were performed in either checkout. No accounts, managed relays or external deployments were created; no message was sent to Iroh maintainers.

## Suggested next verification

Iroh is the selected direction. Choose self-hosted admission or managed-token validation based on the user's hosting preference, then qualify the vertical prototype described above. Hosting remains undecided; do not begin a production migration solely from this research checkpoint.

- For self-hosting: test real endpoint authentication → HTTP callback allow/deny, unknown endpoint, revoked endpoint, backend timeout and active disconnect. Verify revocation races and reconnect denial.
- For managed service: test backend-only signing, correct endpoint accepted, wrong endpoint denied, expiry/renewal, least privilege and individual revocation. Requires actual managed-relay access; it has not been supplied or exercised.
- Then qualify packaged bridge ↔ physical Android/iOS, Windows/Linux/macOS builds, forced relay, UDP-blocked networks, network changes, background/resume, loaded project reuse and interactive terminal latency during preview transfer.
- Record time to first usable terminal (cold and warm), p50/p95 input-to-screen latency, direct/relay bytes, memory/CPU and recovery errors.

Workspace note when this checkpoint was written: `bun.lock` already had unrelated changes. Preserve them. This Markdown is the only Antgrid file created for this research request; no commit was requested.
