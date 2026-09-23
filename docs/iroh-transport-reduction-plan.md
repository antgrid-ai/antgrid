# Iroh transport reduction plan

Status: proposed, 2026-09-23. Follows the completed six-stage simplification in
[iroh-simplification-ledger.md](iroh-simplification-ledger.md). Where this plan
contradicts [iroh-migration-plan.md](iroh-migration-plan.md) or
[native-transport-followup-plan.md](native-transport-followup-plan.md)
("one bidirectional stream", "preserve E2E, fragmentation, credits"), this plan
supersedes them.

## Why

The migration moved payloads onto Iroh without deleting what Iroh makes
redundant. The single QUIC stream still carries the WebSocket-era stack: an
application E2E layer, fragmentation, per-channel credit windows, a stream mux,
and application-level chunking for tunnels and uploads. On top of that sits a
custom Rust relay. The branch is net +19.7K lines over its merge-base; about
11K of that is generated (two `Cargo.lock`s, a license inventory).

Iroh's own guidance for traffic like ours (`docs.iroh.computer`,
`protocols/using-quic.md`) is many cheap streams: one bidirectional stream per
request, as HTTP/3 does, with independent flow control, loss recovery,
cancellation and priority per stream. Its FAQ confirms relays cannot read
payloads: QUIC/TLS 1.3 end-to-end encryption between endpoint IDs, always on.

## Decisions (confirmed by the owner, 2026-09-23)

- **C.** Replace the custom relay with the stock upstream `iroh-relay` 1.2.0
  binary configured with `access.http`. Losing relay-side mid-connection
  revocation is accepted: revocation is enforced at the bridge (below).
- **B.** Remove the application E2E layer on the Iroh path. Accepted on the
  condition that no relay can read message content, which Iroh guarantees.
  Push-notification encryption is unaffected and stays.
- **A.** Replace the single stream with purpose-specific QUIC streams.

## Order: C, then B, then A

- **C first.** Independent of the other two, largest deletion, mostly removal.
- **B before A.** Two of the multi-stream hazards exist only because of the E2E
  layer: frames sealed under new keys arriving on another stream before
  `established` (rekey, hazard H), and no stream being allowed to carry traffic
  before key install (I). Removing E2E first deletes them instead of building
  trial-decrypt-per-stream.

Each stage bumps `FRAME_VERSION` where the wire changes, as a coordinated beta
upgrade with no dual decoder (the ledger's policy). If B and A ship in one
release, only the final version reaches users.

Expected reduction (line counts incl. tests, measured at `f01f2db8`): C ≈ −12.7K
(~2.7K hand-written), B ≈ −2.7K to −3.1K, A ≈ −4.8K to −5.4K; total ≈ −20K.

## Security model after all three stages

- **Confidentiality and integrity:** QUIC/TLS 1.3 between Iroh endpoints. A
  relay forwards ciphertext and sees endpoint IDs, IP addresses, timing and
  byte counts, until the path goes direct. The WebSocket relay sees comparable
  metadata today.
- **Identity:** both sides already reject a peer whose Iroh remote endpoint ID
  is not in the authorization snapshot. App: `iroh_peer_link.dart:85-93`
  (`AUTHENTICATED_ENDPOINT_MISMATCH`), `leased_peer_link.dart:59-70`,
  `authorization.dart:244-252`. Bridge: `native-host-connection.ts:205-207`,
  `:229`, `:267`, `:271`. Web binds each endpoint ID to its device key by
  dual-signed registration (`web/src/models/peer-authorization.ts:88-95`).
- **Trust anchor:** unchanged. Today the Ed25519 keys that verify the E2E
  handshake also come from the web snapshot (`native-host-connection.ts:384-387`;
  app `peer_runtime.dart:260-268`). A compromised backend defeats both designs
  equally.
- **Revocation:** unchanged at the bridge. Instant path: web policy outbox →
  central WebSocket `peer-policy-changed` (`central-control-client.ts:321`) →
  `AuthorizationLease.observePolicyGeneration` → `invalidate("revoked")`
  (`authorization-lease.ts:52-57`) → `retirePeer(…, "unauthorized")`.
  Fallback: lease refresh every 20s, expiry at most 60s from request start.
  New relay connections are refused by the access check.
- **Push:** unchanged. `bridge/src/push/seal.ts` depends only on
  `bridge/src/key-exchange.ts`; `push_open.dart` only on `package:cryptography`.

---

## Stage C: stock iroh-relay

### What the stock binary does (read at upstream tag `v1.2.0`, `iroh-relay/src/main.rs`)

- `access.http = { url, bearer_token }`, overridable with
  `IROH_RELAY_HTTP_BEARER_TOKEN` (`main.rs:199-228`).
- Request: `POST <url>`, **no body**, header `X-Iroh-NodeId: <64 hex>` (the
  doc comment says `X-Iroh-Endpoint-Id`; the code sends `X-Iroh-NodeId`,
  `main.rs:36,319`), plus `Authorization: Bearer` when configured.
- Allow **only** on HTTP 200 with body exactly `true`; everything else denies
  (`main.rs:299-336`).
- No client timeout on that request (`main.rs:221-224`); only the 30s
  handshake `ESTABLISH_TIMEOUT` bounds it.
- Checked **once per connection** (`server.rs:285-305`). No lease, no
  re-check, no admin/disconnect API. One global client registry.
- `--dev` serves plain HTTP on `[::]:3340`; no `[tls]` section also serves
  plain HTTP on `http_bind_addr`. No loopback enforcement.
- Metrics default to port 9090. Routes: `/relay`, `/ping`, `/generate_204`,
  `/healthz` (no `/readyz`).

### Accepted losses

- Mid-connection relay revocation. Enforced at the bridge instead (see above).
- Per-account client registries: an admitted endpoint can address any other
  admitted endpoint ID. This allows spam/DoS against a known endpoint ID, not
  reading traffic: the bridge and app complete a QUIC handshake only with
  endpoint IDs from their own snapshot. Mitigate with `[limits]`.
- Per-account/per-endpoint connection caps and the accounts cap. Only
  `accept_conn_*` and per-client rx byte limits remain.
- Loopback enforcement for the insecure dev mode. Move it to Aspire config.

### Steps

C1. **Web access route.** Add `POST /internal/iroh-access`:
- Constant-time bearer check against a new `IROH_RELAY_ACCESS_TOKEN` (not
  `RELAY_INTERNAL_SECRET`).
- Endpoint ID from `X-Iroh-NodeId`, validated with the existing 64-hex
  `EndpointIdSchema` (`packages/antgrid-wire/src/peer-authorization.ts:18`).
- Run `peerRelayAdmission` (`web/src/models/peer-authorization.ts:177-205`),
  keeping registration, device, entitlement and generation checks.
- **Relay origin binding:** the stock relay sends no relay URL. Put it in the
  configured access URL as a query parameter
  (`…/internal/iroh-access?relay=<approved origin>`), and have web check it
  against `IROH_RELAY_URLS`. Verify reqwest keeps the query on the POST before
  relying on it; if not, use one bearer token per relay.
- Enforce a 2s deadline **inside the handler** and answer `false` on timeout,
  because the relay has no client timeout. Keep the 32-in-flight 503 bound.
- Reply `200 true` or `200 false`.

C2. **Policy outbox.** Remove the relay `/internal/disconnect` target from
`PEER_POLICY_TARGETS`. Keep `/internal/peer-policy`: delivery is skipped
entirely without it (`web/src/relay/peer-policy-outbox.ts:17-19`).

C3. **Aspire.**
- Run the stock binary (`cargo install iroh-relay --version 1.2.0 --locked
  --features server`, or the pinned upstream image) with a generated TOML.
- Set `http_bind_addr` and `metrics_bind_addr` explicitly (the 9090 default
  collides).
- Dev mode: no `[tls]`, bind to loopback or a private address, and do the
  loopback/private check in `aspire/peer-stack.ts`.
- Update `aspire/apphost.ts:153-159,209-213` env and launch, and
  `aspire/scripts/relay-gateway.mjs` + its test.
- `ANTGRID_DEV_INSECURE_RELAY` (bridge) and `kDevInsecureRelay` (Dart) are
  independent of the binary and stay.

C4. **Deploy.**
- `deploy/iroh/compose.yaml`: upstream image pinned by digest, TOML config,
  `cert_mode = "Manual"` or `"Reloading"`, publish 443 (and 7842/udp only if
  QUIC address discovery is enabled; it defaults off).
- Drop the nginx `administration` sidecar's `/internal/disconnect` and `/readyz`.
- Rewrite `monitoring/alerts.yml` onto upstream metric names; health via
  `/healthz`.

C5. **Delete.** `iroh-relay/` entirely, `.github/workflows/iroh-relay.yml`,
`web/src/routes/peer-admission.ts`, the wire schemas
`PeerRelayAdmissionRequest/ResponseSchema`, and the relay's entries in
`THIRD-PARTY.md`/`LICENSING.md`.

C6. **Evals.** Rewrite `evals/tests/gate-iroh-relay-authorization.test.ts`.
It currently asserts `bothConnectionsClosed` at the relay, which the stock
relay cannot do. New assertions:
- After a device DELETE, the bridge retires the peer within 60s.
- A new relay connection from the revoked endpoint is denied.

C7. **Docs.** `docs/architecture.md` relay paragraph, `docs/iroh-operations.md`,
root and scoped `CLAUDE.md` mentions of `iroh-relay/`.

**Gate:** web, relay and bridge suites; the rewritten relay gate; Aspire stack
brought up once with a real app ↔ bridge connection forced through the relay.

---

## Stage B: remove the application E2E layer

The loopback desktop path (`local_transport.dart`, `bridge/src/local-listener.ts`)
never used E2E and already runs a plaintext capability hello. It is the model
for the new native hello.

### What must survive the removal

| Kept behavior | Today | After |
|---|---|---|
| Peer Ed25519 pubkey per `peerId` (feeds `viewOf`, `push:register` at `agent-core.ts:2440-2468`, push suppression at `project-core.ts:659-662`, drift check at `native-host-connection.ts:272-273`) | set from the verified hello (`peer-session-owner.ts:899`) | set at accept from `lease.current.peers[*].ed25519Pub` |
| pairedPhones row create/touch (push row, `antgrid phones list`) | on handshake (`peer-session-owner.ts:912-927`) | on admission |
| Capabilities (`checkoutRouting`, `pullsTree`, `terminalFramesV1`) | `app:ready` (`connection_handshake.dart:326-335`, read at `peer-session-owner.ts:1051,1064-1065`) | plaintext hello; literals stay hand-mirrored with `protocol.ts` (root CLAUDE.md rule) |
| Nothing dispatched before establishment; `onHandshakeComplete` re-advertisement (`host-server.ts:871-875`) | `established` | hello → `established`, idempotent retransmit kept |
| Lease re-check before admitting a hello | `native-host-connection.ts:371-376` | unchanged |
| Liveness ping/pong, `session-takeover`, half-open/hello timeout | sealed session frames | plaintext session frames |
| Session generation | Dart `_sessionEpoch` | kept as a generation (credits go in A) |

### What goes

- Transcript, signatures, key schedule, confirm, AES-GCM transport, rekey and
  make-before-break. Rekey triggers (3 RPC timeouts, missed pongs;
  `machine_session.dart:652-664,878-915`) become **close the QUIC connection
  and let `ConnectionSupervisor` redial**.
- **Not E2E, keep:** `bridge/src/relay-epoch.ts` (central hello epoch),
  `bridge/src/key-exchange.ts` (push), Ed25519 signing in `crypto_service.dart`
  (central hello, eval client).

### Steps

B1. **Wire.**
- `FRAME_VERSION` 3 → 4. `FrameKind` `sealed`/`handshake` collapse to one
  plaintext kind.
- Drop `SEAL_OVERHEAD_BYTES` (`flow.ts:32-33`, `flow.dart:40`).
- Regenerate peer-transport vectors (`scripts/gen-peer-transport-vectors.ts`).
  Mirror `frame.dart` by hand.
- Netwatch frame IDs are the GCM nonce today (`bridge/src/netwatch.ts:71-76`,
  `frame.dart:65-74`, `docs/commands.md:83-84`). Replace with a per-link
  counter or a short hash of the frame bytes.

B2. **Bridge.**
- Move `rawSeedToPkcs8` out of `e2e/handshake-sig.ts`. It is used by
  `central-control-client.ts:47` and `peer/enrollment.ts:33`.
- Rewrite `PeerSessionOwner`'s hello handling (`handleClientHello`
  `:837-977`, `handleAppReady` `:1015-1092`) as the plaintext hello per the
  table above. Remove sealing at `:369` and `:1323-1335`, and trial decrypt
  at `:501-568`.
- Remove the "never send cleartext" drop (`:1179-1191`) and key zeroizing.
- Override point: `resolvePhoneEd25519PubB64` becomes an accept-time lookup.
- Delete `bridge/src/e2e/`.

B3. **Dart relay client.**
- `connection_handshake.dart` becomes a plaintext hello. Keep the capabilities
  literal.
- `machine_session.dart`: remove `_keys`, seal/open and `_rekey`; the rekey
  triggers call link close.
- Remove `PairedAgent.keys` (`models/device_identity.dart:42`).
- Move `push_open.dart` out of `src/e2e/`, keep its export, delete the rest of
  `src/e2e/`. Trim `crypto_service.dart` to Ed25519.

B4. **App.**
- Remove `installNativeE2eCipher` (`main.dart:117`), `config/native_crypto.dart`,
  `config/cng_aes_gcm.dart`, and the key-retirement calls in
  `connection/peer_connection.dart`.
- Drop `cryptography_flutter` from `pubspec.yaml` if nothing else uses it;
  `push_open` uses plain `package:cryptography`.
- Drop the CNG step in `.github/workflows/build-desktop.yml:682-690`.

B5. **Evals and eval client.**
- `packages/antgrid_eval_client` `handshake` action.
- `evals/helpers/relay-client.ts` phone-side handshake (`:729-1000`) and its
  ~15 importers.
- Delete `gate-rekey.test.ts`; edit `gate-vectors.test.ts`; delete
  `evals/fixtures/e2e-handshake-vectors.json` and `bridge/scripts/gen-e2e-vectors.ts`.

B6. **Tests.**
- Delete: `bridge/tests/e2e/*`; Dart `e2e_vectors_test`,
  `e2e_transport_algorithm_test`, `connection_handshake_test`,
  `machine_session_rekey_test`; app `cng_aes_gcm_test`, `cipher_bench`,
  `frame_batch_bench`, `peer_connection_key_retirement_test`,
  `peer_connection_pin_test`.
- Keep: `bridge/tests/push/seal.test.ts`, `push_open_test.dart`,
  `fixtures/push_vector.json`.
- Rewrite session setup in the `test-peer-session-owner.ts` harness and
  `support/fake_live_relay.dart` first; most other suites set up sessions
  through them.

B7. **Docs and rules.**
- Root `CLAUDE.md:32` and `:119`: replace "NEVER make encryption optional" with
  "payloads travel only over authenticated Iroh connections to an endpoint ID
  from the authorization snapshot; never add a plaintext payload path".
- Update `bridge/CLAUDE.md`, `app/CLAUDE.md`,
  `packages/antgrid_relay_client/CLAUDE.md`, `docs/architecture.md`,
  `SECURITY.md:46-101`, `site/src/pages/security.astro:82-83`,
  `site/src/config.ts:90-91`.
- Retire `docs/protocol/e2e-handshake.md`. Move §8.1 (envelopes) and §8.5
  (liveness) into a new `docs/protocol/peer-session.md`; §8.8 (credits) moves
  there too and is deleted in A.

**Gate:** all suites. Eval sweep incl. `gate-iroh-host-authorization`,
`gate-two-devices-one-bridge`, `gate-app-socket-drop`, and the push suites.
Grep proof that no `e2e/` import remains except the moved `push_open`.

---

## Stage A: purpose-specific QUIC streams

### Target stream layout

Every stream begins with one length-prefixed **open frame** naming its purpose.
Records inside keep the `[u32 len][frame]` framing.

| Stream | Opened by | Lifetime | Carries | Priority (bridge `setPriority`) |
|---|---|---|---|---|
| **Session** | app, first | connection | hello/`established`, ping/pong, `session-takeover`, machine control plane (today's stream `"0"`), session-bus frames, RPCs without a project | highest |
| **Project** `{projectId, checkoutId?}` | app, per bind | while bound | today's project stream traffic: verbs, status/adverts, `tree:update`, `state.snapshot` response, `stream-invalid`/`control:result` refusals | high |
| **Terminal attachment** | app, per subscribe | while attached | `terminal:subscribe` → `subscribed`, frames, acks, `display:status` incl. `ENDED`, history pages, input, resize | high |
| **Request** | app, per request | one exchange, FIN | `file:read`→content, git diffs, search results + done, `file:tree:snapshot` pull, uploads, tunnel HTTP request/response | normal |
| **Tunnel WebSocket** | app, per socket | socket lifetime | `ws-open`, data both ways, close = FIN | normal |

The Dart binding (`iroh_quic` 1.0.3) exposes no stream priority. App→bridge
bulk is uploads only, so this is acceptable. Bridge→app priority, where the
bulk is, uses `@number0/iroh` `SendStream.setPriority`.

Set `max_concurrent_bidi_streams` explicitly on both endpoints, sized from
(projects + terminals + in-flight requests) per peer. Bound it per peer on the
bridge and reset excess streams. Iroh warns that transport-config changes can
affect hole-punching, so change only the stream limits.

### Ordering hazards and how this layout resolves them

From the ordering audit of the current code:

| # | Hazard | Resolution |
|---|---|---|
| A | `terminal:subscribed` (control) must precede the first `terminal:frame` (preview); otherwise frames are dropped unacked and the attachment stalls after 10s (`delivery.ts:315-323`, `terminal_service.dart:693-706`). Already racy today. | Same terminal stream. |
| B | `display:status ENDED` overtakes in-flight frames; the app discards them (`delivery.ts:562-580`, `terminal_service.dart:1212-1219`). Happens today. | Same terminal stream. |
| C | History page boundary regresses a newer frame boundary (`terminal_history_model.dart:233-235`). | Same terminal stream. |
| D | `file:tree:snapshot` applied unconditionally over a newer `tree:update` (`file_service.dart:223-227`). | Snapshot moves to a request stream, so **add a guard**: while a pull is outstanding, buffer `tree:update`s; on snapshot N, apply it, then replay buffered updates > N. `file:tree:unchanged` gets the same guard. |
| E | `state.snapshot` response overwrites newer live status (`machine_session.dart:1753-1774`). | Response **stays on the project stream**. |
| F | `stream-unbound` on stream `"0"` re-mutes a live stream X (`stream-mux.ts:352-390`). | Binding is the project stream's lifetime; unbind = FIN. The notice goes away. |
| G | Frames on stream X before the app learns X. | The app opens project streams, so the bridge cannot push before binding. |
| H | New-key frames before `established` on another stream. | Gone with Stage B. |
| I | Traffic before key install. | Gone with Stage B. All non-session streams open only after `established`. |

Within-flow ordering (tunnel HTTP start/chunk/end, WebSocket data-then-close,
upload, search results-then-done, fragments, RPC by `requestId`) holds because
each flow stays on one stream. The session bus is lossy by design and
correlated by message ID.

### Steps

A1. **Wire.**
- Open-frame schema (`kind: "session" | "project" | "terminal" | "request" |
  "tunnel-ws"` plus its fields), in `antgrid-wire` with a hand-mirrored Dart copy.
- Bump `FRAME_VERSION`; regenerate vectors.
- Remove the `{s, m}` envelope and `CONTROL_STREAM_ID`
  (`packages/antgrid-wire/src/peer-protocol.ts:12-20`).

A2. **Transport.**
- Remove the single-stream guards (`native-host-connection.ts:248-249`,
  `iroh_peer_link.dart:158-169`).
- Extend `PeerLink` with open/accept stream, per-stream close, reset and
  priority. Bridge: one accept loop per connection dispatching by open frame,
  per-peer stream caps, generation fencing on each stream.
- Replace the single record FIFO (`bridge/src/peer/records.ts`) and the app's
  `_tail` write chain with per-stream writers.

A3. **Project streams.** Replace stream-mux attach/detach, `stream-ready`,
`stream-unbound` and `stream-invalid` with open/FIN of the project stream. Keep
the `CHECKOUT_VARIABLE_MESSAGE_TYPES` resolution: checkout routing is decided
by the open frame's checkout, and per-message routing inside is unchanged.
Keep the `seenProjects` catalog lookup and `isSafeProjectId` on the open frame:
they remain the only bound on which project a phone may name.

A4. **Terminal streams.**
- Move `terminal-frames/delivery.ts` and `terminal_service.dart` onto the
  attachment stream.
- Keep latest-revision ack semantics and `TERMINAL_VIEWER_MAX_FRAMES`.
- Re-derive `TERMINAL_CONNECTION_MAX_BYTES`: it is sized as half of
  `CHANNEL_WINDOW_BYTES`, which goes away (`agent-core.ts:2539-2551`).

A5. **Request streams.**
- `file:read`, git diff content, search, tree snapshot pull (with hazard D's
  guard).
- Upload: the app streams bytes, FIN, and the bridge replies with the result.
  Delete `seq`/ack stop-and-wait (`file-upload.ts:148-186`,
  `upload_service.dart:93-99,244-264`).
- Tunnel HTTP: head then raw body bytes, FIN = end, reset = error/cancel.
  Delete `http-chunk.seq`, `http-end.chunks`, lost-head retry
  (`preview_service.dart:411-439`), the outbox
  (`tunnel-manager.ts:183-193,520-561`) and send pacing.
- Tunnel WebSocket: one stream per socket; delete the pre-open buffer
  (`tunnel-manager.ts:847-890`).

A6. **Delete.**
- `bridge/src/stream-mux.ts`, both send schedulers, `frag-reassembler.ts`,
  `antgrid-wire` `flow.ts`/`frag.ts`, Dart `flow.dart`/`frag.dart`/`send_scheduler.dart`.
- Credit frames and credit on liveness ticks
  (`peer-session-owner.ts:412-430,812-831,1426-1434`); per-channel decrypt
  chains; the `control`/`preview` channel split and its classification mirrors
  (`PREVIEW_CHANNEL_MESSAGE_TYPES`, `kPreviewChannelInboundTypes`).
- Tests listed in the reduction count: `stream-mux`, `send-scheduler`,
  `native-session-send-scheduler`, `frag-reassembler`,
  `relay-client-credit-window`, `relay-client-frag-send`, wire
  `flow`/`frag`, Dart `flow_test`/`frag_test`/`send_scheduler_test`/`machine_session_flow_control_test`.
- Delete §8.8 from `docs/protocol/peer-session.md`.

A7. **New tests** (each must fail against the pre-A code where the hazard
exists today):
- Hazards A, B and D: an interleaving test that delivers the later frame first.
- Concurrency: a bulk transfer does not delay terminal frames (terminal frame
  latency bounded while a 32 MiB `file:read` is in flight).
- Stream cap: exceeding the per-peer cap resets the extra stream and keeps the
  connection.
- Cancel: cancelling a tunnel request resets only its stream.

**Gate:** all suites; eval sweep; the native fault soak
(`evals/soak/native-fault-soak.test.ts`); the Iroh interop gate
(`qualify:iroh-interop`), since the app and bridge bind different Iroh
implementations; one forced-relay run.

---

## Open questions for the owner

1. **Relay origin binding (C1):** query-parameter binding, or accept any
   approved relay with one shared token? The first keeps today's
   `IROH_RELAY_URLS` check.
2. **Cross-account relay registry (C):** accept with `[limits]` tuned, as
   recommended, or keep a thin fork?
3. **Release packaging:** ship B and A together as one frame version, or
   separately?

## Standing rules for implementers

- Product worktrees need `bun install` and `flutter pub get` before gating.
- `flutter analyze` never concurrently; gate once per stage.
- Per-workspace tests only (`bun run --filter <name> test`), never bare
  `bun test`.
- Capability literals and `kCheckoutVariableMessageTypes` stay hand-mirrored
  across the licence boundary; `FRAME_VERSION` is mirrored by hand in Dart.
- One commit per step or wave; record status in a ledger next to this plan.
