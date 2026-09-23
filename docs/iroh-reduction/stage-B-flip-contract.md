# Stage B W1 flip: frozen implementer contract

This is the contract for the five W1 implementers of `stage-B-waves.md`. It fixes
every name and shape they share. Anything it does not name is the owning
implementer's choice, provided it stays inside that implementer's files (§9).

Where this file and `stage-B-waves.md` disagree, this file wins. Where either
disagrees with the code as it stands at `ce336965`, the code describes the
starting point, and this file describes the end state.

After the flip, the peer layer's confidentiality is QUIC/TLS between endpoints
the lease authorizes. The payload bytes inside a peer frame are the plaintext
that the old layer used to seal: a UTF-8 JSON bare session object, or a
`{s, m}` envelope, or a frag part, exactly as they were before the seal.

**Out of scope for W1.** None of the following may be edited:

- `bridge/src/e2e/`, `bridge/tests/e2e/`, `bridge/scripts/gen-e2e-vectors.ts`
- `packages/antgrid_relay_client/lib/src/e2e/`, `e2e_vectors_test.dart`, `e2e_transport_algorithm_test.dart`
- `app/lib/config/native_crypto.dart`, `cng_aes_gcm.dart`, and their tests and benches
- `bridge/src/trusted-peers.ts`
- `evals/fixtures/e2e-handshake-vectors.json`

All of these still compile, and each is deleted in W2.

Four things stay exactly as they are:

- Push encryption: `bridge/src/push/seal.ts`, `bridge/src/key-exchange.ts`, `push_open.dart`.
- Central hello signing: `relay-epoch.ts` and relay-auth.
- The per-device X25519 key.
- The central-auth `0x03` literals (`relay-auth.ts:11`, `relay_auth.dart:12`). Never grep-replace `0x03`.

---

## 1. Wire (W1-wire)

### Frame version

| | TS (`packages/antgrid-wire/src/peer-frame.ts`) | Dart (`packages/antgrid_relay_client/lib/src/frame.dart`) |
|---|---|---|
| Version | `FRAME_VERSION = 0x04` | `peerFrameVersion = 0x04` |

### FrameKind

TS: `export const FrameKind = { message: 0x00 } as const;`

Dart: `enum FrameKind { message(0x00) }`, with `fromWire` kept.

The byte stays in the frame. `0x01` now decodes as a bad kind, and any value other than `0x00` is rejected.

### Header layout

The layout is unchanged: `[version:u8][kind:u8][hdrlen:u16 BE][header JSON][payload]`, with `FIXED_PREFIX = 4` and `MAX_HEADER_LEN = 1024`. The header is `{type:"message", channel}`.

### Codec functions

The codec loses its kind parameter.

- TS: `encodePeerFrame(header, payload)` always writes `FrameKind.message`.
- TS: `decodePeerFrame(buf)` returns `{ header, payload }`. It still validates the kind byte.
- The Dart functions have the same two shapes. `decodePeerFrame` returns the record `(header, payload)`.

### Seal overhead

Delete `SEAL_OVERHEAD_BYTES` (`flow.ts`) and `kSealOverheadBytes` (`flow.dart`) in the same commit. Also remove the TS export from `src/index.ts`.

- A sender charges `plaintextBytes`, which is the frame payload length.
- A receiver counts the frame payload length.

Both sides must change in the same commit (trap 3). Fix the stale comment in `flow.ts:1-9`.

### Vectors

Update `scripts/gen-peer-transport-vectors.ts`:

1. Samples become `"message-control"` and `"message-preview"`, both `FrameKind.message`.
2. Set `kinds: { message: 0 }`.
3. Drop `flowControl.sealOverheadBytes`.
4. Change the comment to "Peer transport v4".

Then run `bun run --filter antgrid-wire gen:peer-vectors`. The W1-wire implementer commits the regenerated `evals/fixtures/peer-transport-vectors.json` and hands it to the others before the gate (trap 6).

`gate-vectors` fails if the fixture is not git-clean.

## 2. The hello

### TS schemas (`bridge/src/protocol.ts`, W1-bridge-src)

Place these where `HandshakeClientHelloMessage` / `AgentHello` / `AgentReady` / `AppReadyMessage` are now (`:146-181`):

```ts
export const SessionHelloCapabilities = z.object({
  checkoutRouting: z.literal(true).optional(),
  pullsTree: z.literal(true).optional(),
  terminalFramesV1: z.literal(true).optional(),
});
export const SessionHelloFrame = z.object({
  type: z.literal("session:hello"),
  attemptId: z.string().min(1).max(256),
  capabilities: SessionHelloCapabilities.optional(),
});
export const SessionEstablishedFrame = z.object({
  type: z.literal("established"),
  attemptId: z.string().min(1).max(256),
});
```

Export the types beside the old handshake types (`~:2849`):

- `export type SessionHello = z.infer<typeof SessionHelloFrame>;`
- `export type SessionEstablished = z.infer<typeof SessionEstablishedFrame>;`

**Capability keys.** The keys and their `z.literal(true).optional()` types are byte-identical to today's `AppReadyMessage.capabilities`.

- The object is non-strict. It strips unknown keys, so a newer app capability never fails an older bridge.
- `sessionBusCarrier` is **not** declared and is **not** sent in the native hello (trap 9). It stays a loopback-hello key only (`local-listener.ts`).

**Why these are not in the message tables.** They are bare session frames, like `ping` / `pong` / `credit`: no `id`, no `timestamp`, and no envelope. So they are **not** added to `AbMessageSchema`, **not** in `KNOWN_TYPES`, and have **no** `handleAbMessage` case. An enveloped `session:hello` therefore fails `parseMessageFast` and is dropped as an unknown message.

**Removed from `protocol.ts`:**

- The `handshake:client-hello`, `handshake:agent-hello` and `handshake:agent-ready` schemas.
- `AppReadyMessage` and its `app:ready` type.
- Their `AbMessageSchema` members (`~:2676-2704`), their exported types (`~:2849-2851`, `:2874`), and their `KNOWN_TYPES` entries (`:3189-3196`).

`agent-core.ts` has no `app:ready` case, and it is not edited. Its `onHandshakeComplete` is an unrelated name.

### Dart mirror

In `connection_handshake.dart`, W1-dart adds:

```dart
const Map<String, bool> kSessionHelloCapabilities = {
  'checkoutRouting': true,
  'pullsTree': true,
  'terminalFramesV1': true,
};
```

The app's hello literal is exactly this map. The default for `LocalTransport.capabilities` (`local_transport.dart:87-91`) becomes `kSessionHelloCapabilities`. Callers that add `sessionBusCarrier` for the loopback hello keep doing so on the loopback path only (trap 8).

### Semantics

- **Channel.** The hello is accepted only on the `control` channel.
- **Establishment is per peer and per connection.** A native connection carries at most one session.
- **Same attemptId while established.** The bridge re-acks with `established {attemptId}` and changes nothing else.
- **Different attemptId while established.** Call `refusePeer(peerId, "protocol-violation")`, which closes with code 2.
- **A second hello while the lease re-check is pending.**
  - Same attemptId: ignored.
  - Different attemptId: `refusePeer(peerId, "protocol-violation")`.
- **Malformed hello.** A control-channel payload whose JSON `type` is `"session:hello"` but which fails `SessionHelloFrame.safeParse` gets `refusePeer(peerId, "protocol-violation")`.
- **Lease refusal.** If the re-check answers not-allowed, or `authorized()` is false after it, call `refusePeer(peerId, "unauthorized")`, which closes with **code 3**. If the refresh rejects (a network failure), call `refusePeer(peerId, "connection-lost")`, which is code 1.
- **No retransmit.** The app sends one hello per connection. A hello that times out makes the app close the link (§5).
- **Flow control.** The hello is outside flow control: the app does not charge it, and the bridge does not count it, because no bridge session exists yet.
  - Every frame the bridge sends after `sessions.set`, including `established` and any re-ack, is a charged session frame.
  - The app counts every frame it receives after it sent the hello (§5).

## 3. Bridge (W1-bridge-src)

### `peer-session-owner.ts` (base)

**New and changed members** (exact signatures):

```ts
protected admitPeer(peerId: string, ed25519Pub: string): void
protected handleHello(hello: SessionHello, peerId: string, frameId?: string, bytes?: number): void
protected refusePeer(peerId: string, reason: PeerRecordFailure): void   // base: this.dropSession(peerId)
protected receivePeerFrame(payload: Uint8Array, from: string, channel: Channel): void   // `kind` removed
protected sendSessionFrame(obj: object, to: string): void                // transport param removed
protected onPeerPlaintext(...)                                           // renamed from onSealedPlaintext; params minus transport/keys
resetSessions(): void                                                    // renamed from resetE2eState
```

- **`admitPeer`.** Sets the Ed25519 identity used today by `handleClientHello`: `phoneEd25519ByDeviceId`, keyed exactly as `handleClientHello` keyed it: by the route slot `peerId` itself, which is what `peerPubkeyFor` and `viewOf` read. It also performs the `pairedPhones` upsert/`touchLastSeen` that `handleClientHello` does today, and that row IS keyed by `baseSlotDeviceId(peerId)`. After it runs, `peerPubkeyFor(peerId)` returns `ed25519Pub`. It performs no establishment.
- **`receivePeerFrame(payload, from, channel)`** is **the per-peer pre-establishment drop point** (trap 1).
  - When `this.sessions.get(from)` is undefined, only a control-channel payload that parses as JSON with `type === "session:hello"` goes on to `handleHello`.
  - Anything else is dropped with a netwatch `kind:"drop"`, `reason:"pre-establishment"`. It never reaches `onPeerPlaintext`, frag reassembly, `routeAppEnvelope`, `dispatchControlPlane`, `bus.dispatchInbound` or a stream.
  - Nothing is counted for a dropped frame.
- **Strict attribution.** A frame is attributed only to `this.sessions.get(from)`. Do not loop over sessions and do not try other sessions. That session alone gets `noteConsumed` and its `lastRecvAt` updated.
- **`handleHello` (base).**
  - If a session exists: apply §2's same/different attemptId rule.
  - Otherwise, if `peerPubkeyFor(peerId)` is absent, fail closed: drop with netwatch reason `"not-admitted"` and establish nothing.
  - Otherwise, build the `PeerSession` (fresh `scheduler` and `rxFlow`) in this order:
    1. `this.sessions.set(peerId, session)`
    2. `onSessionEstablished(peerId)`
    3. `sendSessionFrame({ type: "established", attemptId }, peerId)`
    4. `onHandshakeComplete({ checkoutRouting, pullsTree, terminalFramesV1, peerId })`, each value being `capabilities?.x === true`
    5. `mux.notifyPeerOnline`, then drain — the existing tail of `handleAppReady`.
  - `sessions.set` must happen before anything is sent, because the hello timer (§3 native) reads `sessions` (trap 10).
  - `onHandshakeComplete` keeps its name and signature.
- **`handleSessionFrame`** gains the `session:hello` case (the re-ack or violation rule) and loses `app:ready`. It keeps `ping`, `pong` and `credit`.
- **`PeerSession`** drops `transport` and `sessionKeys`. `lastSealedRecvAt` becomes `lastRecvAt`. `attemptId` stays.
- **Deleted:**
  - `handleClientHello`
  - the confirm path of `handleAppReady`; the method goes, and its tail moves into `handleHello`
  - `pending`, `PendingAttempt`, `tearDownPending`
  - the half-open timer and the `halfOpenMs` option
  - `handleSealedFrame`, `tryOpenSession`, `tryOpenPending`
  - `handleHandshakeFrame`
  - `resolvePhoneEd25519PubB64`
  - the `generateKeypair` option
  - every zeroize call
  - `newSendScheduler`'s seal step: it now sends the encoded payload via `sendNativeScheduled(payload, peerId, frame)`.
- **Kept until W2b:** the `trustedPeers` option (declared, unused), and `backfillPeerPubkey` / `markPeerOnline`. `evictForCapacity` and the `session-takeover` send may be deleted now or left for W2b. Either way, the Dart `session-takeover` case stays (D5).

### `bridge/src/peer/records.ts`

Add `"superseded"` to `PeerRecordFailure`.

Close codes in `retirePeer`:

| Reason | Code |
|---|---|
| `unauthorized` | `3n` |
| `protocol-violation` | `2n` |
| everything else (`connection-lost`, `queue-full`, `superseded`) | `1n` |

### `bridge/src/peer/native-host-connection.ts`

- **`acceptConnections`:** remove the `this.nativePeers.size >= MAX_APP_SESSIONS` refusal. Capacity is judged in `acceptPeer`, once the device is known.
- **Newest-wins in `acceptPeer`.** This replaces the refusal at `sessions.has || pending.has || nativePeers.has`.
  - If `this.nativePeers.has(peerId)`, call `this.retirePeer(peerId, "superseded")`. That closes the old connection with code 1, drops its session and records `peer:native-retired` with `reason:"superseded"`.
  - Otherwise, if `this.nativePeers.size >= MAX_APP_SESSIONS`, call `connection.close(1n, [])` and return.
  - Only a device the lease has authenticated reaches this point.
- **Identity guard.** Never retire by `peerId` unless `this.nativePeers.get(peerId) === peer`. The `acceptBi` catch and the post-`acceptBi` recheck both go through `retireOwnAttempt(peerId, peer)`: `retirePeer(peerId, "connection-lost")` when the identity matches; otherwise, if the attempt was not already retired by someone else (a resume, a newer connection), `connection.close(1n, [])`. A superseded attempt must never retire its successor, and an attempt already retired is not closed twice.
  - The recheck condition becomes: `stopped || generation mismatch || !remoteAccessEnabled() || !lease.allows(...) || nativePeers.get(peerId) !== peer`. The `sessions.has` and `pending.has` terms go.
- **`admitPeer` call site.** Call `this.admitPeer(peerId, device.ed25519Pub)` immediately after the post-`acceptBi` recheck passes, before `new PeerRecords(...)`, so the identity exists before the first read.
- **Hello timer.** `NativePeerContext.handshakeTimer` becomes `helloTimer`. It stays 30 s and still targets `this.sessions`, with an identity guard: `if (this.nativePeers.get(peerId) === peer && !this.sessions.has(peerId)) records.close()`. Clear it in `onSessionEstablished` and in `retirePeer`.
- **`authorizedHello`** is replaced by `helloAttemptId?: string` on `NativePeerContext`.
- **The `handleHello` override performs the lease re-check.** It replaces the `handleHandshakeFrame` override, which is deleted (trap 2). Steps:
  1. Let `peer = nativePeers.get(from)`. If there is no peer or it is retired, return.
  2. If `this.sessions.has(from)`, call `super.handleHello`, which applies the re-ack or violation rule, and return.
  3. If `peer.helloAttemptId` is set:
     - Same attemptId: return.
     - Different attemptId: `refusePeer(from, "protocol-violation")`.
  4. Set `peer.helloAttemptId`.
  5. Call `lease.refresh()`, then:
     - If the peer changed or was retired, or the host is stopped: return.
     - If `!allowed || !authorized(from, peer.endpointId)`: `refusePeer(from, "unauthorized")`.
     - Otherwise: `super.handleHello(...)`.
     - If `refresh()` rejects: `refusePeer(from, "connection-lost")`.
- **`refusePeer` override:** `this.retirePeer(peerId, reason)`. The `dropSession` override stays: it calls `retirePeer(peerId)`, which is code 1 and covers liveness death.
- **`receivePeerFrame` override:** drop `kind` from the signature. Keep the `authorized()` → refresh-and-drop guard.
- **Read loop:** `this.receivePeerFrame(frame.payload, peerId, header.channel)`.
- **Sends.** `sendNativeScheduled(payload: Buffer, peerId, frame)` and `sendNativePayload(data, to, channel = "control", diagnosticType = "transport", streamId?)` both drop `kind`, and so does `recordNativeWrite`.
- **Leftover plumbing.** `recheckAuthorization` and `dropAllPeers` lose their `pending` terms. The `resolvePhoneEd25519PubB64` override goes.
- **`authorized()` still compares `peerPubkeyFor(peerId)` with the lease's `ed25519Pub`.** `admitPeer` is now what sets `peerPubkeyFor(peerId)`, so a key rotated in the lease still retires the peer.

### `bridge/src/host-server.ts`

- **`:891`:** replace `if (!client.hasEstablishedSession()) return;` with a per-peer gate: `if (!peerId || client.peerSession(peerId) == null) return;`. Add a public `peerSession(peerId): PeerSession | undefined` read accessor on the owner if none exists.
- **`:862`:** drop the `generateKeypair` option and the `generateEphemeralKeypair` import at `:30` if nothing else uses it.
- The `trustedPeers` wiring stays until W2b.

### Other bridge-src files

- **`send-scheduler.ts:318`:** set `need = f.plaintextBytes`.
- **`local-listener.ts`:** the loopback hello and ready netwatch records use `kind: "hello"`.
- **`bridge/src/cli/netwatch.ts`:** fix the nonce and decrypt comments at `:362,401,419`. The joiner logic from W0b is unchanged.
- **`bridge/scripts/iroh-host-smoke.ts`:** send a plaintext `session:hello` and await `established`.
- **`bridge/scripts/terminal-frame-bench.ts`:** drop the seal step.

These two scripts run in no suite (trap 11). Run `bun run --filter antgrid-bridge qualify:iroh-host` and `qualify:iroh-interop` by hand.

## 4. Netwatch (both ends)

### Frame ID

The ID is the SHA-256 of the **frame payload bytes**: the bytes after the peer-frame header, exactly what is passed to `encodePeerFrame` or returned by `decodePeerFrame`. It is written as lowercase hex, and the ID is its first 24 characters.

- TS (`bridge/src/netwatch.ts`): `frameIdFor(payload: Uint8Array): string`. The `sealed` parameter is removed.
- Dart (`frame.dart`): `String frameIdOf(Uint8List payload)`. The `kind` parameter is removed.

The W0b joiner already pairs duplicate IDs by occurrence, direction and channel (trap 5).

### `NetwatchKind` (`bridge/src/netwatch.ts`)

`NetwatchKind` becomes `"frame" | "hello" | "control" | "json" | "drop" | "lifecycle"`.

| Old kind | New kind |
|---|---|
| `sealed` | `frame` |
| `handshake` | `hello` (loopback hello/ready only) |

Every native peer frame, the `session:hello` included, is recorded as `kind:"frame"`. `msgType` names it.

The Dart side records only `drop` and `annotate` events on the peer path. It needs one change: the doc comment at `app/lib/util/netwatch.dart:46` lists `frame|hello`.

### Drop reasons

- `no-e2e-session` is kept verbatim for a send with no session.
- `pre-establishment` and `not-admitted` are new.
- `decrypt-failed`, `keys-rotated` and `seal-failed` no longer occur.

## 5. Dart (W1-dart)

### `SessionHandshaker`

```dart
abstract interface class SessionHandshaker {
  Future<bool> perform();
  void abort();
}
```

### `ConnectionHandshake`

`ConnectionHandshake({required PeerLink relay, HandshakeLogger? logger, Duration attemptTimeout = defaultAttemptTimeout})` has `Future<bool> run()`. `AppSessionHandshaker` takes the same three parameters.

Removed: `crypto`, `machineDeviceId`, `phoneDeviceId`, `agentEd25519PubB64`, `phoneEd25519Seed` and `appReadyRetransmit`.

`run()`:

1. Subscribe to `relay.messageStream` first.
2. Generate `attemptId` with the existing `_secureNonceB64()`.
3. Send `utf8.encode(jsonEncode({'type': 'session:hello', 'attemptId': id, 'capabilities': kSessionHelloCapabilities}))` via `relay.sendFrame('control', bytes)`.
4. An outcome other than accepted returns `false`.
5. Resolve `true` on a control-channel frame that decodes to `{type: 'established', attemptId: id}`. Resolve `false` on timeout, `abort()`, or `!relay.isDispatchAllowed`.

`HandshakeLogger` and `HandshakeException` stay.

### `machine_session.dart`

- **Session generation.**
  - Replace `_keys` and `_sessionEpoch` with `_SessionGeneration? _generation`, where `class _SessionGeneration { _SessionGeneration(this.epoch); final int epoch; }` and `epoch` comes from a monotonic counter. The unknown-stream log keeps its `openedUnder` / `sessionEpoch` ints from it.
  - `_keysReady` / `_armKeysReady` become `_establishedReady` / `_armEstablishedReady`.
  - Every `identical(keys, _keys)` fence becomes `identical(gen, _generation)`, captured before and re-checked **after** the `sendFrame` await.
  - Do not use a bool (trap 4).
- **Attempt.** Before `perform()`, run `_scheduler.resetWindows()` and `_resetRxFlow()`. On `true`, install `_generation = _SessionGeneration(++_epochCounter)` and run the rest of today's install tail (liveness, ready completers, `_unboundNotifiedAt.clear()`, snapshot re-pull, `kick`). On `false`, run `_teardownSession()` **and** `relay.close()`. There is never a second hello on the same link.
- **Inbound dispatch.** `_onPeerFrame` is synchronous and in order:
  1. Return if disposed or `!relay.isDispatchAllowed`.
  2. `_noteConsumed(channel, payload.length)` if `_generation != null || _handshakeInFlight`.
  3. Return silently if `_generation == null`. Frames between `established` and install are counted and dropped, and the snapshot re-pull covers them.
  4. UTF-8 decode, reassemble, then `_dispatchDecoded`.

  Delete `_inboundTails`, `_dispatchGeneration` and `_decryptAndDispatch`.
- **Session frames.** `_sendSessionFrame` encodes UTF-8 and charges `bytes.length`. The `credit` epoch check becomes the generation-identity check. The `session-takeover` case stays.
- **Rekey.** `_rekey()` and both of its triggers (the `_kConsecutiveTimeoutsToRekey` RPC timeouts and the `kMaxMissedPongs` liveness miss) become `relay.close()`. The `_onState(closed)` teardown and the supervisor redial do the rest.

### `peer_link.dart` and `iroh_peer_link.dart`

- `Future<PeerSendOutcome> sendFrame(String channel, Uint8List payload)`: the `kind` parameter is removed.
- `IncomingPeerFrame{channel, payload}`: the `kind` field is removed.
- `iroh_peer_link.dart` `_read` still closes with error code 1 on a frame that fails to decode, including version `0x03` or kind `0x01`.

### Other Dart files

- **peer_transport:** remove `kind` from `leased_peer_link.dart`, `bin/native_smoke.dart` and the tests. `bin/interop_app.dart` builds `AppSessionHandshaker(relay: active, logger: ...)`.
- **`antgrid_eval_client/lib/src/commands.dart`:**
  - The `handshake` action keeps its name.
  - `machineDeviceId` stays required. `agentEd25519Pub` is accepted and ignored, and the action no longer requires it. `attemptTimeoutMs` stays.
  - It builds `AppSessionHandshaker(relay, logger → 'handshake-diagnostic', attemptTimeout)`, runs `ensureEstablished`, and emits `handshake-complete` exactly as today.
  - `_crypto` is removed: after the flip only the handshake read it, and `init` never did.

## 6. Test seams after the flip

### Bridge (W1-bridge-tests)

**`TestPeerSessionOwner.establish(peerId, { capabilities?, identity?, attemptId? })`** does four things:

1. `this.admitPeer(peerId, identity.pubB64)`, where the identity defaults to a fresh `ed25519Pair()`.
2. Inject a plaintext control-channel `session:hello {attemptId, capabilities}` through `injectPeerPayload`.
3. Assert `this.sessions.get(peerId)?.attemptId === attemptId`.
4. Clear the outbox.

It returns `{ attemptId, identity }`.

**Other seam changes:**

- `sendFromPeer(peerId, obj, channel)` injects plaintext JSON. The `handshake` option is gone.
- `readToPeer` / `sentTo` parse plaintext.
- `injectPeerPayload(payload, from, channel)` has no `kind`.
- `adoptPeerTransport` and `peerTransport` are deleted.
- `forTest` drops `generateKeypair` and `halfOpenMs`.
- `installFakeSession` drops `transport` and `sessionKeys`, and `lastSealedRecvAt` becomes `lastRecvAt`.

### Dart (W1-dart)

**`support/fake_live_relay.dart`:**

- `SentFrame(channel, payload)`.
- `FakeHandshaker({bool established = true})` and `FakeHandshaker.sequence(List<bool>)`, keeping `delayFor`.
- `fixedKeys`, `sealFromAgent` and `openFromPhone` are deleted, replaced by the synchronous `Uint8List encodeFromAgent(String json)` and `String decodeFromPhone(Uint8List payload)`.
- `establishSession(relay, {handshaker, ...})` keeps its shape.

**Suite rewrites:**

- `connection_handshake_test.dart` is rewritten for the hello driver: exact hello bytes, attemptId match, timeout returns false, and abort.
- `machine_session_rekey_test.dart` becomes "each trigger closes the link".
- `machine_session_rpc_health_test.dart` follows the same trigger change.

### New bridge tests (W1-bridge-tests, new file `bridge/tests/peer-session-hello.test.ts`)

- (a) A native peer's `{m}` envelope with no hello is dropped (`pre-establishment`). It never reaches `bus.dispatchInbound` or a stream.
- (b) A hello refused by the lease re-check is not established, and the connection closes with code 3.
- (c) A frame from peer A is never attributed to peer B.
- (d) Credit balances over N frames with no +28.
- The identical re-ack and the different-attemptId protocol violation (code 2).
- Newest-wins: a second connection for the same peer retires the first with `"superseded"`, and a superseded attempt never retires its successor.

## 7. Evals and app (W1-evals+app)

### TS `RelayClient` (`evals/helpers/relay-client.ts`)

- **`performE2EHandshake(agentDeviceId, timeoutMs = 10_000, opts: { omitPullsTree?: boolean; omitTerminalFramesV1?: boolean } = {})`** keeps its name.
  - It resets the rx counters.
  - It sends a plaintext `session:hello` on control via `encodePeerFrame`.
  - It resolves on `established` with the matching attemptId.
- Session frames (`ping`, `pong`, `credit`) are sent plaintext.
- **Deleted:**
  - the crypto options (`corruptAgentHelloPubkey`, `omitClientHelloSig`, `corruptAgentReadyConfirm`, `agentEd25519Pub`, `dropFirstAppReady`, `dropEstablished`, `noRetransmit`)
  - `pending`, `rekey()`, `enableLiveness`, `setSwallowPongs`, and the auto-rekey
- **Kept:** `reconnectNative`.

### Harness and Dart app client

- `harness.ts` `establishNativeSession(app, agentDeviceId, agentEd25519Pub, opts)` keeps its positional signature, and the third parameter is unused.
- `dart-app-client.ts` stops sending `agentEd25519Pub`.

### Eval suites

- **Deleted:** `evals/tests/gate-rekey.test.ts` and `evals/scenarios/handshake-mitm/`. Every case in handshake-mitm is premised on transcript crypto.
- **`gate-two-devices-one-bridge`:** step (5) becomes a same-device reconnect (`reconnectNative` + `performE2EHandshake`) that app2 must not notice.
- **`gate-iroh-host-authorization`:** raw `session:hello` → `established`.
- **`gate-inventory-miss`** is re-premised: an endpoint absent from the lease is refused at accept, and admitted after a refresh.
- **`local-terminal` and `multi-project-isolation`:** delete the `app:ready` nudge lines.
- **`gate-terminal-frames:4`:** comment only.
- **`gate-flow-control` and `gate-tunnel-streaming`:** no overhead.

### App

- `PeerConnectionMechanisms` drops `crypto`, `phoneDeviceId` and `phoneEd25519Seed`, and `buildHandshaker` becomes `SessionHandshaker Function()?`.
- `_ensureSession` builds `AppSessionHandshaker(relay:, logger:)`.
- The `retireNativeE2eCipherKeys` calls stay until W2a.
- Update `agent_transport.dart:339` and remove the locals left unused.

## 8. Gates

These are the W1 gates in `stage-B-waves.md`. They run once, after integration.

`antgrid_eval_client` has no `test/` directory and no `test` dependency, so its `dart test` gate cannot run; the evals that drive it (`dart-app-client.ts`) cover it. `gate-vectors` also fails on an uncommitted `peer-transport-vectors.json` by design, so it is green only once the flip commit lands.

Two rules for running them:

- Never run `flutter analyze` or `dart analyze` from an implementer. The controller runs it once, in W3.
- Run bun tests per workspace only.

These failures already exist and are not caused by W1:

- Six bridge failures in `index-hook-subcommand`, `plugin/antigravity-post-title` and `plugin/opencode-notify`.
- The two load-sensitive git tests: git-branches stash pop, and git-sync already-up-to-date.

## 9. File ownership (disjoint and complete)

Every file the spec's W1 lists name, plus every grep hit for `SessionKeys|E2eTransport|sealed|FrameKind|handshake:|app:ready|rekey|SEAL_OVERHEAD|kSealOverhead|generateKeypair` that W1 invalidates. A file listed nowhere is not edited in W1. The owner of a file makes every change this contract requires of it.

| Owner | Files |
|---|---|
| **W1-wire** | `packages/antgrid-wire/src/peer-frame.ts`, `src/flow.ts`, `src/index.ts`, `scripts/gen-peer-transport-vectors.ts`, `tests/peer-frame.test.ts`, `tests/flow.test.ts`, `tests/peer-transport-vectors.test.ts`; `evals/fixtures/peer-transport-vectors.json` |
| **W1-bridge-src** | `bridge/src/peer-session-owner.ts`, `bridge/src/peer/native-host-connection.ts`, `bridge/src/peer/records.ts`, `bridge/src/protocol.ts`, `bridge/src/send-scheduler.ts`, `bridge/src/netwatch.ts`, `bridge/src/cli/netwatch.ts`, `bridge/src/local-listener.ts`, `bridge/src/host-server.ts`, `bridge/scripts/iroh-host-smoke.ts`, `bridge/scripts/terminal-frame-bench.ts` |
| **W1-bridge-tests** | `bridge/tests/test-peer-session-owner.ts`, `fake-session.ts`, `handshake-pull.test.ts`, `relay-client-credit-window.test.ts`, `relay-client-frag-send.test.ts`, `relay-client-no-pairing.test.ts`, `relay-client-tunnel-send.test.ts`, `stream-mux.test.ts`, `native-host-connection.test.ts`, `native-session-send-scheduler.test.ts`, `netwatch.test.ts`, `netwatch-remote.test.ts`, `netwatch-local.test.ts`, `netwatch-join.test.ts`, `host-control-plane.test.ts`, `account-trust-phone-registration.test.ts`, `host-server.test.ts`, `remote-access-gate.test.ts`, `session-bus-remote-directory.test.ts`, `protocol.test.ts`, `send-scheduler.test.ts`, `tunnel-protocol.test.ts`, `key-exchange.test.ts` (edit only if it breaks; trimming it is W2b), `relay-client-trusted-peers.test.ts` (delete), new `peer-session-hello.test.ts` |
| **W1-dart** | `packages/antgrid_relay_client/lib/antgrid_relay_client.dart`, `lib/src/frame.dart`, `flow.dart`, `send_scheduler.dart`, `peer_link.dart`, `connection_handshake.dart`, `machine_session.dart`, `local_transport.dart`; `test/support/fake_live_relay.dart`, `frame_test.dart`, `flow_test.dart`, `send_scheduler_test.dart`, `peer_link_test.dart`, `connection_handshake_test.dart`, `netwatch_tap_test.dart`, `machine_session_{envelope,establish,flow_control,rekey,rpc_health,snapshot_retry,stream_binding,unknown_stream_log}_test.dart`. `packages/antgrid_peer_transport/lib/src/iroh_peer_link.dart`, `leased_peer_link.dart`, `bin/native_smoke.dart`, `bin/interop_app.dart`, `test/connection_attempt_test.dart`, `leased_peer_link_lifecycle_test.dart`, `peer_transport_vectors_test.dart`. `packages/antgrid_eval_client/lib/src/commands.dart` |
| **W1-evals+app** | `evals/helpers/relay-client.ts`, `harness.ts`, `test-app.ts`, `dart-app-client.ts`; `evals/soak/native-fault-soak.test.ts`; `evals/tests/gate-flow-control.test.ts`, `gate-tunnel-streaming.test.ts`, `gate-iroh-host-authorization.test.ts`, `gate-two-devices-one-bridge.test.ts`, `gate-inventory-miss.test.ts`, `gate-terminal-frames.test.ts`, `local-terminal.test.ts`, `multi-project-isolation.test.ts`, `gate-rekey.test.ts` (delete), `evals/scenarios/handshake-mitm/` (delete). `app/lib/connection/peer_connection.dart`, `app/lib/providers/agent_transport.dart`, `app/lib/util/netwatch.dart`; `app/test/helpers/fixed_peer_connector.dart`, `helpers/test_peer_runtime.dart`, `providers/agent_transport_coords_retry_test.dart`, `providers/agent_transport_identity_test.dart`, `providers/agent_transport_test.dart`, `providers/device_revocation_test.dart`, `providers/relay_connection_manager_test.dart`, `providers/superseded_not_license_test.dart`, `providers/supervisor_status_test.dart`, `relay/relay_connection_open_test.dart`, `connection/peer_transport_integration_test.dart`, `connection/peer_connection_key_retirement_test.dart` (compile fix only; W2a deletes it), `util/netwatch_test.dart`, `util/netwatch_uploader_test.dart` |

These grep hits need no W1 edit:

- **Unrelated names or prose:**
  - the `bridge/src/agent-core.ts:4511` log line (W3)
  - `bridge/src/tunnel-manager.ts` and `tunnel-manager-ws-*.test.ts` (WebSocket handshake)
  - `local_transport.dart:223`
  - `relay_service_dial_bound_test.dart`
  - `app/test/project/message_router_test.dart`
  - `app/lib/connection/connection_supervisor.dart` and its test (`establishSession` is the supervisor's own method)
  - the "rekey" comments in `paired-phones.ts`, `tunnel-manager.ts`, `frag.dart`, `relay_service.dart` and `projects.dart` (W3)
- **Deleted in W2, and they still compile in W1:**
  - `bridge/src/e2e/**`, `bridge/tests/e2e/**`, `bridge/scripts/gen-e2e-vectors.ts`
  - `antgrid_relay_client/lib/src/e2e/**`, `e2e_*_test.dart`
  - `app/lib/config/native_crypto.dart`, `cng_aes_gcm.dart`, `app/test/config/*`
