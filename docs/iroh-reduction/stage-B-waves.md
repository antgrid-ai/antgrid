# Stage B (remove the app E2E layer): adjudication, corrections and wave plan

**Verdict.** Stage B is feasible and safe, but not as the plan describes it. Three of its premises are wrong or missing:

1. **"Nothing is dispatched before establishment" is enforced today only by the crypto.** Once frames are plaintext, a connected peer that has not sent its hello yet gets dispatched unless an explicit check is added.
2. **The lease re-check cannot stay "unchanged".** It hangs off a frame kind that B deletes.
3. **Test setup has no single choke point** on either side.

The flip itself (wire, bridge, Dart and evals) cannot be split across commits and still gate green. My plan therefore adds prep waves that shrink the flip, then one coordinated flip commit, then deletion waves that can run in parallel.

Labels: **READ(me)** means I read the code at that line in this session. **READ(reader)** means one of the two reader passes reported it and I did not re-open it. **EXECUTED** means I ran a read-only grep, sed or ls. **INFERRED** means reasoning only. I ran no tests and no analyzer.

---

## 1. Adjudication: attacks on the stage's core premises

### 1.1 Confidentiality and identity: the premise holds
- **The bridge authenticates the peer at the QUIC layer.** `acceptPeer` looks up the device by `connection.remoteId()` in the lease and builds `peerId` from it (READ(me) `bridge/src/peer/native-host-connection.ts:205-208`). It re-checks after `acceptBi` (`:229-232`). `authorized()` re-checks per write (`:270-278`).
- **The app authenticates the bridge the same way.** It rejects a peer whose `remoteId` is not the expected endpoint (READ(me) `packages/antgrid_peer_transport/lib/src/iroh_peer_link.dart:85-93`). The expected endpoint and Ed25519 key come from the web snapshot (READ(me) `app/lib/connection/peer_runtime.dart:259-289`).
- **Key custody does not get weaker.** An attacker holding only the endpoint secret could impersonate after B, where today the transcript signature would stop them. I checked whether the endpoint secret is stored less carefully than the Ed25519 key:
  - Bridge: `endpointSecret` sits in the same credentials schema as the other auth secrets (READ(me) `bridge/src/auth/credentials.ts:7`).
  - App: it sits in the same identity record as `ed25519Priv` (READ(me) `app/lib/providers/connection_identity.dart:53,106`).
  - So they share custody, and B loses nothing here (INFERRED).
- **The dev insecure relay does not weaken endpoint TLS.** INFERRED: QUIC between endpoints is always TLS, and the flag affects relay transport only. I did not read `dev-insecure-relay.ts`.

### 1.2 Pre-establishment dispatch: a real hole, and the plan misses it
READ(me):
- `onSealedPlaintext` sends any `{m}` envelope to `routeAppEnvelope` with `session` possibly null (`bridge/src/peer-session-owner.ts:571-616`).
- `routeAppEnvelope` never checks `this.sessions.has(peerId)` (`:659-687`).
- The control-plane bus gate is `client.hasEstablishedSession()`, which means *any* peer, not this one (`bridge/src/host-server.ts:891`, `peer-session-owner.ts:240-242`).
- Project streams admit a `null` peer when the project has no isolated sessions (`bridge/src/project-core.ts:571-574`, `stream-mux.ts:347`).

Today the only barrier is that a peer without keys cannot produce a frame that opens. After B, a lease-authorized endpoint that has not said hello can:
- drive verbs with capabilities defaulted to false;
- skip the second lease refresh that `handleHandshakeFrame` does (`native-host-connection.ts:356-378`);
- send `stream-unbound` to mute any stream (`peer-session-owner.ts:746-748`).

**Required:** receive must drop every non-hello frame from a `peerId` that is not in `sessions`, and the check must fail closed. Also change `host-server.ts:891` to `client.peerSession(peerId) != null`. Both compile clean if forgotten, and no current test would fail.

### 1.3 Trial decrypt is also cross-peer sender resolution
READ(me) `peer-session-owner.ts:501-525`: `handleSealedFrame` tries the hinted session first, then **every other session and pending attempt**. After B the frame must be attributed only to the QUIC-authenticated `from`. Delete the loop; do not turn it into "first session that parses".

### 1.4 Rekey becomes "close the link": a reconnect-refusal race the plan does not mention
- READ(me) `native-host-connection.ts:209-211`: a new connection is closed when `sessions`, `pending` or `nativePeers` still holds that `peerId`.
- Today a rekey stays on the live connection, so this never triggers.
- After B, an app that closes after 3 RPC timeouts or 2 missed pongs redials at once. The trigger is usually a sick path. If the bridge has not yet seen the old `CONNECTION_CLOSE` because it was lost, the redial is refused until the old connection's `closed()` resolves. No idle timeout is configured (EXECUTED grep found no `idle`/`keepAlive` in `bridge/src/peer` or `antgrid_peer_transport/lib`), so that wait is up to the QUIC idle timeout (INFERRED).
- The in-connection rekey is also today's recovery for a credit wedge: it builds a fresh scheduler and `rxFlow` (READ(me) `peer-session-owner.ts:1039-1043`). Until Stage A deletes credits, every wedge becomes a full re-dial including the lease (INFERRED).

**Recommendation:** in `acceptPeer`, a new authenticated connection from the *same endpoint ID* retires the old one ("newest wins") instead of being refused. See decision D4.

### 1.5 `session-takeover` is already dead on the native path
READ(me):
- `acceptPeer` refuses once `nativePeers.size >= MAX_APP_SESSIONS` (`native-host-connection.ts:211`).
- `sessions` and `pending` are subsets of `nativePeers`, so `evictForCapacity` (`peer-session-owner.ts:980-1003`) can never find the table full on native (INFERRED from READ).

The plan's "session-takeover kept" keeps a dead path (decision D5).

### 1.6 The B-before-A ordering premise holds
Hazards H and I exist only through the key install and `pending` (READ(me) `peer-session-owner.ts:1015-1086`). Nothing I found refutes the ordering. The rekey-as-reconnect cost in §1.4 argues for B and A shipping together (the plan's Q3).

---

## 2. Plan corrections

| # | Plan text | Correction | Method |
|---|---|---|---|
| 1 | `bridge/src/peer/PeerSessionOwner` (implied) | It is `bridge/src/peer-session-owner.ts`. The subclass is `bridge/src/peer/native-host-connection.ts:60`. | READ(me) |
| 2 | Lease re-check at `native-host-connection.ts:371-376` "unchanged" | It is an override of `handleHandshakeFrame` (`:356-378`), reached only through `kind === FrameKind.handshake` (`peer-session-owner.ts:175-181`). Collapsing FrameKind makes it silently dead. Re-home it on the plaintext hello type. | READ(me) |
| 3 | "Nothing dispatched before establishment" works by `established` | Today it is enforced by the crypto alone. B must add an explicit per-peer drop and change `host-server.ts:891` to per-peer (§1.2). | READ(me) |
| 4 | Remove trial decrypt `:501-568` | It is also cross-peer sender resolution. Replace it with strict `from` attribution (§1.3). | READ(me) |
| 5 | `SEAL_OVERHEAD_BYTES` at `flow.ts:32-33` | `flow.ts:34`. Load-bearing uses the plan omits: `bridge/src/send-scheduler.ts:318` and `send_scheduler.dart:293` (window admission), plus 10 more files (EXECUTED grep: `send-scheduler.test.ts`, `tunnel-protocol.test.ts`, `gate-flow-control`, `gate-tunnel-streaming`, wire `flow.test.ts`, the vector generator, `peer_transport_vectors_test.dart`, `flow_test.dart`, `send_scheduler_test.dart`). Sender and receiver must drop the +28 in the **same commit as dropping sealing**. Otherwise the sender charges +28 while the receiver credits plaintext bytes, and the window drains 28 B per frame until the 40s resync. | READ(me) + EXECUTED |
| 6 | `scripts/gen-peer-transport-vectors.ts` | `packages/antgrid-wire/scripts/gen-peer-transport-vectors.ts`, run with `bun run --filter antgrid-wire gen:peer-vectors`. Its output `evals/fixtures/peer-transport-vectors.json` must be committed in the same wave (`gate-vectors.test.ts` requires a git-clean file). | READ(reader) + EXECUTED |
| 7 | Netwatch: "per-link counter or short hash" | A hash alone mis-joins: the joiner pairs with the *first* opposite-direction event that has the same ID (READ(me) `bridge/src/cli/netwatch.ts:401-427`), and every ping, pong and credit is byte-identical. A counter drifts across app-side drops before send. Fix: a payload hash, plus occurrence-order pairing in the joiner. Change the joiner first. | READ(me) + INFERRED |
| 8 | `rawSeedToPkcs8` users are `central-control-client.ts:47` and `enrollment.ts:33` | Also `bridge/tests/relay-client-hello.test.ts:10` and `evals/helpers/relay-client.ts:14`. | READ(reader) |
| 9 | "Delete `bridge/src/e2e/`" | CI-run importers the plan omits: `bridge/scripts/iroh-host-smoke.ts:6-7,43-52` (`qualify:iroh-host`, run in `build-desktop.yml` on 3 platforms) and `bridge/scripts/terminal-frame-bench.ts:31`. `gen-e2e-vectors.ts` is named. | READ(me) + READ(reader) |
| 10 | Rewrite `test-peer-session-owner.ts` first, as the choke point | Wrong. It establishes no session. Real choke points: `bridge/tests/fake-session.ts` `installFakeSession` (identity "seal", 4 importers, READ(me)); per-suite hand-rolled handshakes (`handshake-pull.test.ts:208`, `relay-client-credit-window`, `-frag-send`, `-no-pairing`, `-tunnel-send`, `stream-mux`, `account-trust-phone-registration`); `generateKeypair` options in `host-server.test.ts:601`, `remote-access-gate.test.ts:361`, `session-bus-remote-directory.test.ts:512`. | READ(me) + EXECUTED |
| 11 | Rewrite `fake_live_relay.dart` first, as the choke point | Partly right. 8 relay_client suites have private `_sealFromAgent`/`_openFromPhone` over `E2eTransportDart`. App real-session tests carry their own crypto (`relay_connection_open_test`, `agent_transport_identity_test`, `peer_transport_integration_test`). | READ(reader) |
| 12 | Rekey triggers are "3 RPC timeouts, missed pongs" | There is a third: `_onPeerRestart` (`machine_session.dart:688-695`). It is dead in production because every `peerRestartStream` is empty (`iroh_peer_link.dart:148`). Delete it rather than rewire it. | READ(me) :688-695; READ(reader) rest |
| 13 | Remove `_keys` from `machine_session.dart` | `_keys` is also the send/receive gate and the reconnect fence (`identical(keys,_keys)` at several sites). It needs a generation-token replacement; a plain bool leaks sends across a reconnect. | READ(reader) + INFERRED |
| 14 | `FrameKind` mirror in `frame.dart` only | `FrameKind kind = FrameKind.sealed` is a parameter on `PeerLink.sendFrame` (`peer_link.dart:56`) and on every implementer and fake: `iroh_peer_link.dart:218`, `leased_peer_link.dart:94`, `native_smoke.dart:74,90`, `fixed_peer_connector.dart`, `test_peer_runtime.dart`, 2 agent_transport tests, 2 peer_transport tests, `peer_link_test.dart`. | READ(reader) + EXECUTED |
| 15 | Delete `peer_connection_pin_test` | It covers live code (`peer_connection.dart:331-352`, `_sessionPin` and `PeerSessionReplaced`). Delete the code and its `sessionReplacements` consumer too, or keep the test. | READ(reader) |
| 16 | Delete the `retireNativeE2eCipherKeys` calls | Keep the `PeerSessionDown`/`PeerSessionTakenOver` emits in the same listeners (`peer_connection.dart:374-391`). | READ(reader) |
| 17 | B5 evals list | Missing: `evals/helpers/dart-app-client.ts:303-358`, `harness.ts:598-615,959`, `test-app.ts:89`, `evals/scenarios/handshake-mitm/`, `gate-iroh-host-authorization.test.ts:11-12,113-117`, `gate-inventory-miss.test.ts` (it depends on `TrustedPeersProvider.noteMiss`), `.rekey(` in `gate-two-devices-one-bridge`. | READ(reader) + EXECUTED |
| 18 | Dart/app interop | `packages/antgrid_peer_transport/bin/interop_app.dart` builds its own `AppSessionHandshaker` and is driven by `bridge/scripts/iroh-interop-smoke.ts:55`. | READ(reader) + READ(me) |
| 19 | `resolvePhoneEd25519PubB64` becomes accept-time | The native override already ignores `trustedPeers` (READ(me) `native-host-connection.ts:384-387`). `TrustedPeersProvider` is built and refreshed in production (`host-server.ts:820-826,861,2503`), but only the base-class path, which is test-only, reads it. After B the provider, `trusted-peers.json`, `bridge/tests/trusted-peers.test.ts` and `relay-client-trusted-peers.test.ts` are all dead. | READ(me) + EXECUTED |
| 20 | Capabilities rule text | Root `CLAUDE.md:116` names `AppReadyMessage.capabilities`. Rename it with the new schema. `sessionBusCarrier` is loopback-only (READ(me) `local-listener.ts:273`) and must not be copied into the native hello by accident. | READ(me) |
| 21 | B7 docs | Also: the `upgrade_screen.dart:27,251` copy ("E2E encrypted — zero-knowledge relay"), E2E doc comments in `app/lib` (reader list), comments in `push/seal.ts:16` and `push-protocol.ts:10` citing `src/e2e/push_open.dart`, `site/src/config.ts:91` linking the deleted fixture, and `app/CLAUDE.md:35` plus `packages/antgrid_relay_client/CLAUDE.md:14-15`, which describe v3 E2E in detail. | READ(me) + READ(reader) |
| 22 | Version bump 3 → 4 | Do not grep-replace `0x03`. `relay-auth.ts:11` and `relay_auth.dart:12` hold the *central* hello signature version. | READ(reader) |
| 23 | Dead plumbing not named | `PeerSessionOwnerOptions.generateKeypair` (`:25`), `halfOpenMs`, `PendingAttempt` + `pending` (`:192`, also read by `acceptPeer:210,231` and `recheckAuthorization:283`), `resetE2eState`, `_handshakeComplete`, `host-server.ts:862`. `backfillPeerPubkey` has no production caller (READ(me) `:279`; the only caller is `test-peer-session-owner.ts` `markPeerOnline`). | READ(me) |

---

## 3. Wave breakdown

**Principle.** The wire flip must be one commit spanning wire, bridge, Dart, evals and app fakes. Waves W0x move every call site onto shared helpers first, so the flip changes the helpers rather than 40 files. Deletion follows the flip.

### Prep waves (no wire change; W0a–W0e can run in parallel, disjoint files)

**W0a: move `rawSeedToPkcs8` (bridge)**
- Files: new `bridge/src/ed25519-pkcs8.ts`; `bridge/src/e2e/handshake-sig.ts` and `e2e/index.ts` re-export it for now; `central-control-client.ts:4`; `peer/enrollment.ts:5`; `bridge/tests/relay-client-hello.test.ts:10`; `evals/helpers/relay-client.ts:14` (import line only).
- Gate: `bun run --filter antgrid-bridge test`.
- Trap: `relay/tests/helpers/relay-harness.ts:9` has its own copy. Leave it.

**W0b: netwatch joiner handles duplicate IDs (bridge)**
- Files: `bridge/src/cli/netwatch.ts:401-430` (occurrence-ordered pairing per `frameId`, direction and channel), `bridge/tests/netwatch-join.test.ts` (add a duplicate-payload case).
- IDs are unchanged in this wave.
- Gate: bridge suite.
- Trap: the existing join tests use distinct payloads, so they stay green whether or not duplicates are handled. The new test must use byte-identical frames.

**W0c: one bridge test establish seam**
- Files: `bridge/tests/test-peer-session-owner.ts`, `bridge/tests/fake-session.ts`, and the suites that hand-roll a handshake or poke `sessions`: `handshake-pull`, `relay-client-credit-window`, `relay-client-frag-send`, `relay-client-no-pairing`, `relay-client-tunnel-send`, `stream-mux`, `account-trust-phone-registration`, `netwatch`, `netwatch-remote`, `native-session-send-scheduler`, `host-control-plane`.
- Add `TestPeerSessionOwner.establish(peerId, {capabilities, pubkey})` and `sendFromPeer(peerId, obj)` / `readToPeer()`. In this wave they run the real E2E handshake internally. Make `installFakeSession` the only way to fabricate a session.
- Suites that assert handshake *behaviour* (the `handshake-pull` establishment cases, `account-trust-phone-registration`) keep direct frames but go through `sendFromPeer`.
- Gate: bridge suite. The test count must not drop.
- Trap: `handshake-pull.test.ts` is 1003 lines. Convert only session setup, not the assertions.

**W0d: Dart dead code and a shared seal seam**
- Files, `packages/antgrid_relay_client`:
  - `lib/src/peer_link.dart` (delete `peerRestartStream`, `:42-44`);
  - `machine_session.dart` (delete `_onPeerRestart` `:688-695` and its subscription `:334`);
  - `models/device_identity.dart` (delete `PairedAgent.keys` `:42` and import `:3`);
  - `test/support/fake_live_relay.dart` (drop `presence`, add shared `sealFromAgent`/`openFromPhone`/`establish` helpers);
  - the 8 suites with private seal helpers (`machine_session_{envelope,establish,flow_control,snapshot_retry,stream_binding,unknown_stream_log}_test`, `netwatch_tap_test`, `flow_test`), switched to the shared helpers;
  - `machine_session_rekey_test` (drop the peer-restart cases).
- Files, `antgrid_peer_transport`: `iroh_peer_link.dart:148`, `leased_peer_link.dart:87`, test fakes (drop `peerRestartStream`).
- Files, `app/test`: `fixed_peer_connector.dart`, `test_peer_runtime.dart`, and any fake overriding `peerRestartStream`.
- Gates: `cd packages/antgrid_relay_client && dart test`; `cd packages/antgrid_peer_transport && dart test`; `cd app && flutter test -j 2`.
- Trap: `agent_transport.dart:206,223` never pass `keys`, so removing it is safe (READ(reader)). Grep for the symbol, not the import, because the app reaches it through the barrel.

**W0e: app pin path (decision D8)**
- Files: `app/lib/connection/peer_connection.dart` (`_sessionPin`, `PeerSessionReplaced` path `:95,331-352`) and its `sessionReplacements` consumer; delete `peer_connection_pin_test.dart`.
- `peer_runtime.dart:266` already refuses a changed key.
- Gate: `flutter test -j 2`.
- Only if D8 is "remove". It is independent of the flip.

### W1: the flip (one commit, serialized, five implementers with disjoint files)

All five parts are integrated and gated together, then committed once.

**W1-wire** (`packages/antgrid-wire`)
- `src/peer-frame.ts`: `FRAME_VERSION` 0x04, `FrameKind` → a single value (D2).
- `src/flow.ts`: delete `SEAL_OVERHEAD_BYTES` and fix the `:6` comment.
- `scripts/gen-peer-transport-vectors.ts:41,47,69,94`.
- `tests/peer-frame.test.ts`, `tests/flow.test.ts`, `tests/peer-transport-vectors.test.ts`.
- Regenerate `evals/fixtures/peer-transport-vectors.json`; this implementer owns it.

**W1-bridge-src**
- `peer-session-owner.ts`:
  - new `handleHello` (hello → per-peer lease re-check → `sessions.set` → `established`; idempotent on the same `attemptId`);
  - delete `handleClientHello`, `handleAppReady`'s confirm, `pending`, `PendingAttempt`, the half-open timer, `handleSealedFrame`/`tryOpen*`, the `sendSessionFrame` transport parameter, zeroize, `resetE2eState` → `resetSessions`, and `generateKeypair`;
  - set `phoneEd25519ByDeviceId` and the pairedPhones row from a new protected `admitPeer(peerId, ed25519Pub)` called by the subclass.
- **The per-peer pre-establishment drop** in the receive path (§1.2).
- `native-host-connection.ts`: call `admitPeer` in `acceptPeer` after `:229-232`; move the lease re-check from the `handleHandshakeFrame` override into the hello path; `sendNativeScheduled`/`sendNativePayload`/`recordNativeWrite` drop `kind`; the `resolvePhoneEd25519PubB64` override goes.
- `send-scheduler.ts:318` (drop the +overhead); `netwatch.ts:16,55,71-76` (hash IDs; `NetwatchKind` rename per D3); `protocol.ts:146-175,2676-2704,2849-2874,3192-3196` (new `session:hello` schema and exported type; remove `handshake:*`; `AppReadyMessage` → hello, keeping `capabilities` byte-identical); `host-server.ts:862` (drop `generateKeypair`) and `:891` (per-peer gate).
- `bridge/scripts/iroh-host-smoke.ts` (plaintext hello) and `terminal-frame-bench.ts` (drop the seal step).

**W1-bridge-tests**
- `test-peer-session-owner.ts` and `fake-session.ts`: helpers go plaintext.
- `protocol.test.ts` (hello schema); `native-host-connection.test.ts` (FrameKind ×4; the lease re-check now on hello); `netwatch.test.ts:65-72` (nonce assertions → hash); `send-scheduler.test.ts`, `tunnel-protocol.test.ts` (overhead).
- `relay-client-trusted-peers.test.ts` → delete (D6); `key-exchange.test.ts` (trim to push cases); `host-server.test.ts`, `remote-access-gate.test.ts`, `session-bus-remote-directory.test.ts` (drop the `generateKeypair` option).
- **New tests:**
  - (a) a `{m}` envelope from a native peer without a hello is dropped and never reaches `bus.dispatchInbound` or a stream;
  - (b) a hello refused by the lease re-check is not established;
  - (c) a frame from peer A is never attributed to peer B;
  - (d) credit accounting balances over N frames with no +28.

**W1-dart** (`antgrid_relay_client`, `antgrid_peer_transport`, `antgrid_eval_client`)
- `frame.dart:8,16-29,65-74`; `flow.dart:40`; `send_scheduler.dart:293`; `peer_link.dart:53-57`.
- `connection_handshake.dart` → a plaintext hello driver; `SessionHandshaker` returns `bool`/`void` instead of `SessionKeys?` (`machine_session.dart:53-70`).
- `machine_session.dart`: replace `_keys`/`_keysReady` with a `_SessionGeneration` object; `identical(gen,_gen)` fences replace `identical(keys,_keys)`; `_keysReady` → `_establishedReady`; drop the kind filter at `:977`; seal/open sites → encode/decode; `_rekey` and both triggers → `link.close()`.
- peer_transport: `iroh_peer_link.dart:218`, `leased_peer_link.dart:94`, `bin/native_smoke.dart:74,90`, `bin/interop_app.dart:128,153-186`, `test/peer_transport_vectors_test.dart:33-41,93`, fakes.
- eval_client: `commands.dart:95,118-119,401-491,694` (`handshake` action → hello; keep the action name so the TS driver changes least).
- relay_client tests: `support/fake_live_relay.dart` (FakeHandshaker plaintext); `netwatch_tap_test.dart:35-59`; `machine_session_rekey_test` → rewrite as "trigger closes the link"; delete `connection_handshake_test`, or rewrite it for the hello driver (recommended: rewrite).

**W1-evals+app**
- evals: `evals/helpers/relay-client.ts:729-1014` (hello; delete `rekey`, or turn it into reconnect); `dart-app-client.ts:303-358`; `harness.ts:598-615`; `test-app.ts:89`; `gate-iroh-host-authorization.test.ts:11-12,113-117`; `gate-two-devices-one-bridge` (rekey → reconnect); `gate-inventory-miss` (re-premise onto "endpoint absent from the lease is refused at accept, admitted after a refresh"); `scenarios/handshake-mitm` → delete, moving any "wrong endpoint refused" case into `gate-iroh-host-authorization`; delete `gate-rekey.test.ts`; `gate-flow-control.test.ts:4,121`; `gate-tunnel-streaming.test.ts:4,32`.
- app: `app/lib/connection/peer_connection.dart` `buildHandshaker` seam (it no longer takes `agentEd25519PubB64`; `CryptoService` param unused); `app/test/relay/relay_connection_open_test.dart`, `providers/agent_transport_identity_test.dart` (drop the transcript assertions), `connection/peer_transport_integration_test.dart`, and the FrameKind-default fakes.

**Gates for W1**, all of them:
- `bun run --filter antgrid-wire test`, `bun run --filter antgrid-bridge test`, `bun run --filter antgrid-relay test`;
- `cd packages/antgrid_relay_client && dart test`, `cd packages/antgrid_peer_transport && dart test`, `cd packages/antgrid_eval_client && dart test`;
- `cd app && flutter test -j 2`;
- `bun run --filter antgrid-evals test:evals`, plus `gate-iroh-host-authorization`, `gate-two-devices-one-bridge` and `gate-app-socket-drop` if they are not in the sweep;
- `bun run --filter antgrid-bridge qualify:iroh-host` and `qualify:iroh-interop` (interop needs the prebuilt DLL, per memory).

**Traps that compile clean:**
1. The pre-hello envelope dispatch (§1.2).
2. The lease re-check left on a dead override.
3. The +28 removed on one side only: a 40s stall, no test failure.
4. `_keys` replaced by a bool with no generation: sends leak across a reconnect.
5. Hash IDs with the old joiner (W0b must land first).
6. A vector fixture that is not regenerated and committed: `gate-vectors` goes red only in evals.
7. A grep-replace of `0x03` that hits central auth.
8. The capability literals drifting between `connection_handshake.dart`, `local_transport.dart:87-91` and `protocol.ts`.
9. `sessionBusCarrier` copied into the native hello.
10. The 30s `handshakeTimer` (`native-host-connection.ts:236-238`) needs the hello to reach `sessions`. If the hello lands in a new map, every native connection closes at 30s.
11. The `.github/workflows/build-desktop.yml` smoke steps are not in any suite, so run the qualify scripts by hand.

### W2: deletions (after W1; W2a and W2b in parallel, W2c after both)

**W2a: app native cipher (app)**
- Delete `app/lib/config/native_crypto.dart` and `cng_aes_gcm.dart`, the `main.dart:18,117` lines, and the `peer_connection.dart:6,312,343,375,379,388` retire calls (keep the emits).
- `pubspec.yaml:51-54` (drop `cryptography_flutter`; keep `ffi`), `pubspec.lock`, `build-desktop.yml:682-690`.
- Delete tests `test/config/cng_aes_gcm_test.dart`, `cipher_bench.dart`, `frame_batch_bench.dart` and `connection/peer_connection_key_retirement_test.dart`.
- Gate: `flutter pub get`, then `flutter test -j 2`.
- Trap: after the plugin-set change, delete `app/build/windows` before any Windows build (memory: plugin bumps poison it).

**W2b: bridge e2e deletion (bridge)**
- Delete `bridge/src/e2e/`, `bridge/tests/e2e/`, `bridge/scripts/gen-e2e-vectors.ts`, `bridge/src/trusted-peers.ts` + `tests/trusted-peers.test.ts` and its `host-server.ts:642,820-826,861,2503` wiring (D6).
- Dead base-class code: `backfillPeerPubkey`, `markPeerOnline`, and `evictForCapacity`/`session-takeover` per D5.
- Gate: bridge suite. Then EXECUTED-grep that nothing imports `/e2e` in bridge or evals.

**W2c: Dart e2e deletion and the shared fixture** (after W2a, because `native_crypto.dart` imports `E2eTransportDart` through the barrel)
- Move `lib/src/e2e/push_open.dart` → `lib/src/push/push_open.dart`; update the barrel (`antgrid_relay_client.dart:19-24`) and `test/push_open_test.dart:4`.
- Delete the rest of `src/e2e/`, `e2e_vectors_test`, `e2e_transport_algorithm_test`, and `evals/fixtures/e2e-handshake-vectors.json` together with the `gate-vectors.test.ts:28` pin.
- `crypto_service.dart` trim per D7.
- Gates: relay_client `dart test`, eval_client `dart test`, `flutter test -j 2`, `bun run --filter antgrid-evals test:evals -- gate-vectors` (or the full sweep).
- Grep proof (EXECUTED at the end), matching symbols, not paths: `SessionKeys|E2eTransportDart|AppSessionHandshaker|x25519SharedSecret|buildTranscript|E2eTransport|FrameKind\.(sealed|handshake)|SEAL_OVERHEAD|kSealOverhead`.

### W3: docs and rules (serial, last; one implementer)
- Root `CLAUDE.md:32,116,119`.
- `bridge/CLAUDE.md`, `app/CLAUDE.md:35`, `packages/antgrid_relay_client/CLAUDE.md:14-15`.
- `docs/architecture.md`, `docs/commands.md:83-86` (netwatch IDs), `SECURITY.md:46-101`, `site/src/pages/security.astro:82-83`, `site/src/config.ts:90-91`.
- Retire `docs/protocol/e2e-handshake.md` into a new `docs/protocol/peer-session.md` (§8.1, §8.5, §8.8).
- Comments at `push/seal.ts:16` and `push-protocol.ts:10`; the `app/lib` E2E doc comments (reader list); `upgrade_screen.dart:27,251` per D9.
- Gates: `npm run check:font-tokens` if app copy changes; `flutter test -j 2`.
- Then the controller runs `flutter analyze` once for the stage (never concurrently).

**Parallelism summary:**
- W0a–W0e run in parallel.
- W1 is serialized: one commit, five implementers partitioned as above. W1-wire must hand the regenerated fixture and constants to the others before the gate.
- W2a and W2b run in parallel; W2c follows W2a.
- W3 is last.

---

## 4. Decisions the owner must make before Stage B starts

| # | Decision | Recommendation |
|---|---|---|
| D1 | Hello protocol shape | `session:hello {attemptId, capabilities}` → `established {attemptId}`, once per connection. Bridge re-acks a duplicate `attemptId`. A different `attemptId` after establishment is a protocol violation and closes the connection. Drop the app's 2s retransmit, since the QUIC stream is reliable. A lease refusal closes the connection with a code instead of dropping silently. |
| D2 | FrameKind | Keep the kind byte and header layout with a single value until Stage A redesigns framing, so there is no layout churn twice. |
| D3 | Netwatch frame IDs | A payload hash plus occurrence-ordered joining (W0b first). Rename `NetwatchKind` `sealed`/`handshake` → `frame`/`hello` on both endpoints in W1. |
| D4 | Same-endpoint reconnect | "Newest authenticated connection wins" in `acceptPeer` instead of refusing (§1.4). Without it, rekey-as-reconnect can stall for up to the idle timeout. Alternatively, configure an explicit QUIC idle timeout. |
| D5 | `session-takeover` and capacity eviction | Delete from the bridge send path and base eviction, since `acceptPeer` caps capacity. Keep the Dart receive case until Stage A, which is harmless. |
| D6 | `TrustedPeersProvider`, `trusted-peers.json`, `gate-inventory-miss` | Delete in B (W2b) and re-premise the gate. The native path has not read the provider since the override. |
| D7 | Per-device X25519 in `DeviceIdentity` (registered with web, passed to the local bridge) | Keep it in B: it is a web contract and push uses its own key. Open a follow-up to drop it across web and app. Trim `crypto_service` only once the eval client no longer needs it. |
| D8 | App pin rebuild path (`peer_connection.dart:331-352`) | Remove it with its test (W0e). `peer_runtime.dart:266` already rejects a changed key. |
| D9 | User-facing "E2E encrypted" copy (`upgrade_screen.dart`, site, `SECURITY.md`) | Reword to "end-to-end encrypted between your devices (QUIC/TLS 1.3); relays cannot read content". The claim stays true, but the mechanism changes, and the published vector link breaks. |
| D10 | Plan Q3: release packaging | Ship B and A as one frame version. B alone turns every credit wedge and RPC-timeout recovery into a full re-dial (§1.4). Land B on the branch, gated, and do not release wire v4 by itself. |
| D11 | Rewrite `handshake-mitm` or delete it | Delete it. Move its surviving intent ("endpoint ID not in the snapshot is refused by both sides") into `gate-iroh-host-authorization`. |