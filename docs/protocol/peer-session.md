# Peer session protocol (native Iroh payload path)

**Frame version:** `FRAME_VERSION` in `packages/antgrid-wire/src/peer-frame.ts` (currently `0x04`; bumped
together with the app, never grep-replaced — `0x03` and other small values are reused by unrelated
protocols, notably the central hello signature version in `relay-auth.ts`/`relay_auth.dart`).

This supersedes the old `docs/protocol/e2e-handshake.md` (v2 handshake crypto, retired). There is no
app-layer handshake, transcript, key schedule or rekey to specify any more: **QUIC/TLS between two
Iroh endpoints the authorization snapshot names is the confidentiality layer**, and a native connection
carries exactly one plaintext session hello. What follows is the shape of that hello and the invariants
around it that no single test suite owns end to end.

---

## 1. Identity and admission

A native connection is accepted only from an endpoint ID present in the caller's authorization lease
(`acceptPeer`, `bridge/src/peer/native-host-connection.ts`); the peer's Ed25519 pubkey used for
identity/push targeting (`admitPeer`, `bridge/src/peer-session-owner.ts`) comes from that same lease
entry, never from anything the peer sends over the wire — there is no signature for the bridge to
verify because the QUIC handshake already proved which endpoint dialed in.

**Same-endpoint reconnect:** the newest authenticated connection from a given endpoint ID retires the
prior one in `acceptPeer` ("newest wins") rather than being refused. Sessions are keyed per device, so
a *different* endpoint for the same device cannot sit alongside it: while the lease still authorizes the
held endpoint, the newcomer is the one closed — a second endpoint never evicts a live, authorized one.
Only when the held endpoint has lost its authorization is it retired in the newcomer's favour.

## 2. The hello

One plaintext hello establishes a session per connection:

```
peer → host : session:hello   { attemptId, capabilities? }
host → peer : established     { attemptId }
```

Schema: `SessionHelloFrame` / `SessionHelloCapabilities` in `bridge/src/protocol.ts`. These are bare
`{ type, ... }` objects with no `id`/`timestamp` envelope — deliberately outside `AbMessageSchema` /
`KNOWN_TYPES` (see the comment above `PeerSessionOwner.handleHello`), because a hello precedes the
session that envelope is scoped to.

- A hello naming an `attemptId` that already matches the peer's established session is re-acked
  idempotently (the driver has no retransmit loop of its own, but a duplicate must not be treated as a
  protocol violation). A *different* `attemptId` while already established closes the connection.
- A peer with no session must already be admitted (`peerPubkeyFor`), or the hello is dropped as
  `not-admitted`.
- **Pre-establishment frames are dropped per peer, fail closed** — `receivePeerFrame`'s only way in for
  a session-less peer is a control-channel `session:hello`; everything else is dropped before it can
  reach dispatch, frag reassembly, the session bus or a stream. This is enforced independently of the
  transport, because nothing above the QUIC layer proves a connected peer has said hello.
- `capabilities` is byte-identical in shape to the old `AppReadyMessage.capabilities` (the app's hello
  literals in `connection_handshake.dart` and `local_transport.dart` must keep naming every key
  `SessionHelloCapabilities` declares, and vice versa — Zod strips an undeclared key, and no suite spans
  both sides). `sessionBusCarrier` is a loopback-only key (`local-listener.ts`) and must never be copied
  into this native hello.

The Dart driver (`ConnectionHandshake` / `AppSessionHandshaker`, `packages/antgrid_relay_client`) is
still called "handshake" in code — that name predates this doc and was kept rather than churned twice —
but it drives no cryptographic exchange: it sends one hello and waits for `established`, with the whole
attempt bounded by one timeout. A connection that never establishes is closed by the caller, not retried
on the same link.

## 3. Session lifetime — no in-place rekey

There is no live-session key material to rotate, so what used to be "rekey" is now "close the link":
a phone-side liveness failure (missed pongs, a run of consecutive RPC
timeouts while established) closes the `PeerLink` (`MachineSession.notifyRpcResult` /
the ping/pong path, `machine_session.dart`) and the connection supervisor redials, going through
admission (§1) and the hello (§2) again. Symmetrically, the bridge declares a session dead on missed
pongs and drops it (`peer-session-owner.ts`), which the peer observes as its connection closing.

This makes every liveness failure and every credit-window wedge a full re-dial, including the
authorization lease refresh — there is no cheaper in-connection recovery path left. `MachineSession`
fences sends/receives across a reconnect with a per-connection generation token
(`_SessionGeneration`/`_generation`, `machine_session.dart`), not a key identity check, since there are
no keys to compare.

`session-takeover` and the base class's capacity eviction are gone from the native path: `acceptPeer`'s
own capacity cap (§1) is the only admission-time bound, and nothing sends a takeover notice any more.

## 4. Frame layout

Wire layout, `FrameKind` and `FRAME_VERSION` are defined in `packages/antgrid-wire/src/peer-frame.ts`
(canonical) and hand-mirrored in `packages/antgrid_relay_client/lib/src/frame.dart`. `FrameKind` carries
a single value on purpose — there is no `sealed`/`handshake` split left to distinguish, and the kind
byte is kept only so a future framing change (Stage A) does not have to re-introduce the field. Peer
identity is authenticated by the connection and deliberately absent from the frame record.

Test vectors: `evals/fixtures/peer-transport-vectors.json`, generated by
`packages/antgrid-wire/scripts/gen-peer-transport-vectors.ts` (`bun run --filter antgrid-wire
gen:peer-vectors`) and consumed by both `packages/antgrid-wire/tests/peer-transport-vectors.test.ts` and
`packages/antgrid_peer_transport/test/peer_transport_vectors_test.dart`. Regenerate and commit the fixture
together with any change to the frame or flow-control constants it pins.

## 5. Per-channel flow control

Each direction of a session carries a cumulative credit window per channel (`control`, `preview`) plus one in-flight cap per socket,
credited by a plaintext `credit { channel, consumed }` session frame. The accounting
counts plaintext payload bytes only — there is no per-frame overhead to add or subtract, and both the sender and the receiver must agree on that in the same change, or the window drains a
fixed amount per frame until the next resync. Constants live in `packages/antgrid-wire/src/flow.ts`
(canonical) and are hand-mirrored in `packages/antgrid_relay_client/lib/src/flow.dart`; read them there
rather than here, since they move independently of this document.

## 6. Netwatch frame IDs

Both endpoints tag every frame with a hash of its payload bytes — `frameIdFor` (`bridge/src/netwatch.ts`),
hand-mirrored as `frameIdOf` (`packages/antgrid_relay_client/lib/src/frame.dart`) — and the joiner
(`joinCaptures`, `bridge/src/cli/netwatch.ts`) pairs same-hash occurrences across the two captures
**in the order they occur**, not by assuming a hash is unique — a ping, a pong, and a credit
frame with the same field values are byte-identical and legitimately recur. `NetwatchKind` names
`frame`/`hello` (formerly `sealed`/`handshake`) alongside `control`/`json`/`drop`/`lifecycle` — see the
type declaration for the current set, since it is a poor fit for a frozen list here.
