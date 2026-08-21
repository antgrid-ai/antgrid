# E2E Handshake Protocol — v2 (`antgrid.e2e-handshake.v2`)

**Domain:** `antgrid.e2e-handshake.v2`
**Version byte:** `0x02`
**Status:** In use (pre-release).

The crypto below is v2 and frozen: the transcript bytes, key schedule, confirm
labels and frame layout are the cross-language interop contract, and changing
any of them is a domain bump. The *conversation* around that crypto is v3
(`attemptId` correlation, kind-byte framing, acked establishment, rekey on a
live session) and is versioned by the relay wire, not by this domain.

---

## 1. Overview and lineage

The app↔agent E2E channel is established by a **signed-Diffie-Hellman
Authenticated Key Exchange (AKE)**. The design follows the ISO/IEC 9798-3 /
TLS-1.3 lineage: Ed25519 transcript signatures provide identity authentication;
a Finished-style HMAC over derived keying material provides explicit key
confirmation. The protocol is in the SIGMA family but is **not** literal
SIGMA-I: identities are signed inside the transcript rather than MACed, and
there is no identity protection (device IDs are relay routing IDs, so hiding
them from the relay is meaningless). The phone's signature over the client-hello
uses an **empty agent-ephemeral slot** — the phone signs before it knows the
agent's ephemeral key, which preserves the pull-model property; the
MITM-defeating bind of the agent ephemeral comes from the agent's own signature.

**Why not Noise?** No turnkey Noise library pair interoperates across Bun (TS)
and Dart without significant build complexity. This construction is in the same
provable-security family and reaches the same goals with a precision
specification and cross-language test vectors (§10).

---

## 2. Preconditions

Before the handshake, each side has pinned the peer's Ed25519 identity:

| Side | Pinned value | Where it comes from |
|---|---|---|
| **Phone** | Agent's Ed25519 public key (`agentEd25519Pub`) | `GET /account/agents` → `InventoryAgent.ed25519Pub`, with the `RecentAgent` row that path caches as the offline fallback. Resolution order in `app/lib/providers/agent_coordinates.dart` prefers the inventory: it cannot be stale. |
| **Agent** | Phone's Ed25519 public key (`phoneEd25519Pub`) | Account-trust admission. `resolvePhoneEd25519PubB64` (`bridge/src/relay-client.ts`) tries every identity source — verified-key cache, account device inventory, paired-phones rows — and accepts the first whose key verifies *this* transcript signature. |

Neither side proceeds past signature verification unless the peer's Ed25519
identity is already pinned by one of these paths. The relay plays no role in
identity pinning; it is zero-knowledge for these values.

The agent tries **every** known identity rather than the first hit on purpose: a
cached key that no longer verifies (device re-registered under a new Ed25519 key
— web updates `publicKey` in place) must fall through to the inventory instead
of dead-ending admission until process restart.

---

## 3. Message flow

The phone initiates (pull model): it arms its listener, then sends
`handshake:client-hello`. The agent generates its ephemeral key only upon
receipt.

```
1. phone → agent : handshake:client-hello  { attemptId, pubkey: e_p, nonce, sig: sig_p }
2. agent → phone : handshake:agent-hello   { attemptId, pubkey: e_a,        sig: sig_a }
3. agent → phone : handshake:agent-ready   { attemptId, confirm: tag_a }   ← SEALED
4. phone → agent : app:ready               { attemptId, confirm: tag_p, capabilities? }  ← SEALED
5. agent → phone : established             { attemptId }                  ← SEALED
```

**`attemptId`** is a phone-generated random string carried by every frame in the
exchange. It correlates one attempt end-to-end so a rekey on a live socket
cannot be confused with the session it is replacing (§8). It is **not** part of
the signed transcript — it is a correlator, not an authenticated value; the
security of an attempt rests on `nonce` and the signatures.

**Field types.** The four `handshake:*` / `app:ready` types have Zod schemas in
`bridge/src/protocol.ts`. `established` does not, and neither do the other bare
sealed session frames (§8.1) — they are handled directly in
`bridge/src/relay-client.ts` and `machine_session.dart`, so adding a field to
one is not caught by the `AbMessageSchema` union.

| Message | Field | Type | Notes |
|---|---|---|---|
| `handshake:client-hello` | `attemptId` | string | Correlator; fresh per attempt |
| | `pubkey` | base64 string | Phone's ephemeral X25519 public key (raw 32 bytes) |
| | `nonce` | base64 string | 32 random bytes; fresh per attempt |
| | `sig` | base64 string | Ed25519 over transcript with **empty** agent-X25519 slot |
| `handshake:agent-hello` | `attemptId` | string | Echoes the client-hello's |
| | `pubkey` | base64 string | Agent's ephemeral X25519 public key (raw 32 bytes) |
| | `sig` | base64 string | Ed25519 over **complete** transcript (both ephemerals) |
| `handshake:agent-ready` | `attemptId` | string | |
| | `confirm` | base64 string | `tag_a` = HMAC-SHA256(k_confirm, "agent-finished") |
| `app:ready` | `attemptId` | string | |
| | `confirm` | base64 string | `tag_p` = HMAC-SHA256(k_confirm, "phone-finished") |
| | `capabilities` | object, optional | `{ checkoutRouting?: true }` — see below |
| `established` | `attemptId` | string | Agent's ack; the phone's terminal event |

`app:ready.capabilities` is load-bearing, not decorative: it reaches the agent
as `onHandshakeComplete(capabilities)` and sets `peerCheckoutRouting`, which
decides whether this app may be routed checkout-scoped frames at all. An app
that does not advertise `checkoutRouting` is refused a project holding a managed
session rather than shown main's workspace beside an isolated agent (root
`CLAUDE.md`, "Checkout-scoped routing").

Messages 3–5 are sealed with the session transport keys (§7). Messages 3 and 4
are sealed under **candidate** keys — the session is not confirmed yet. The
agent flips to established only after verifying `tag_p`; the phone only after
verifying `tag_a` *and* receiving `established`.

**Attempt pacing.** One attempt is bounded by
`ConnectionHandshake.defaultAttemptTimeout`. The relay client package
deliberately owns no retry: `MachineSession.ensureEstablished` drives exactly one
attempt (concurrent callers join the in-flight `_handshakeFuture` — single-flight
per machine session, not per project) and throws `HandshakeException` on
failure. Retry pacing and give-up belong to the app's `ConnectionSupervisor`
(`_kMaxInitialHandshakeAttempts`, per-rung exponential backoff). See §8's
tunables table.

---

## 4. Canonical transcript

The canonical transcript is the byte string signed by both parties and hashed as
the HKDF salt. It is the single source of truth for cross-language interop.

**Byte layout** (fields joined with `0x00` separator bytes; **no trailing
separator**):

```
domain         (utf8: "antgrid.e2e-handshake.v2")
0x00
versionByte    (1 byte: 0x02)
0x00
registrationId (utf8: the relay registration id — equals agentDeviceId today)
0x00
role           (utf8: "agent" | "phone")
0x00
agentDeviceId  (utf8)
0x00
phoneDeviceId  (utf8)
0x00
agentX25519Pub (raw bytes, 32 bytes in sig_a; ZERO-LENGTH in sig_p)
0x00
phoneX25519Pub (raw bytes, 32 bytes)
0x00
nonce          (raw bytes, 32 bytes)
```

**Notes:**
- `registrationId` equals `agentDeviceId` today: both are the bare machine
  `deviceUuid`. It stays a distinct field so a future change to the registration
  shape does not require a domain bump. It carries **no project binding** — v3
  registers one machine socket and multiplexes every project over it as a
  stream, so one E2E session covers them all.
- `phoneDeviceId` is the app's bare account `deviceUuid` — **not** its relay
  route id. The two differ: the app addresses each machine on its own relay slot
  (`<deviceUuid>#<machineDeviceUuid>`, see `bridge/src/relay-slot.ts`) so it can
  hold several machines open at once, and the agent strips that scope
  (`baseSlotDeviceId`) before building the transcript. The transcript binds the
  account identity the agent resolves from the peer's inventory; a transport
  address must never enter it, or one phone would sign a different transcript
  per machine — and, because this transcript is also the HKDF salt, would derive
  keys the other side cannot open.
- `agentX25519Pub` is **zero-length** (empty byte sequence) in `sig_p` (the
  phone's client-hello signature). The phone signs before it knows the agent
  ephemeral; the agent signs the complete transcript including its own ephemeral.
- The transcript is role-specific: for the HKDF salt (§5), the full `"agent"`
  role transcript (including both ephemerals) is used.

Canonical implementation: `bridge/src/e2e/transcript.ts` (TS) and
`packages/antgrid_relay_client/lib/src/e2e/transcript.dart` (Dart).

---

## 5. Key schedule

```
ss        = X25519(e_priv_self, e_pub_peer)                    // 32-byte shared secret
context   = SHA-256(agentRoleTranscript)                       // full transcript, role="agent", both ephemerals present
prk       = HKDF-Extract(salt = context, ikm = ss)
okm       = HKDF-Expand(prk, info = "antgrid-e2e-v2", L = 96)

k_a2p     = okm[ 0 ..  32)   // agent → phone AES-256-GCM key
k_p2a     = okm[32 ..  64)   // phone → agent AES-256-GCM key
k_confirm = okm[64 ..  96)   // key-confirmation HMAC key (never used for transport)

ss is zeroized immediately after HKDF-Extract.
```

**Why SHA-256(transcript) as the HKDF salt?** The salt binds the derived keys to
the entire authenticated context (both identities, both ephemerals, nonce,
registrationId, version).

Canonical implementation: `bridge/src/e2e/key-schedule.ts` (TS) and
`packages/antgrid_relay_client/lib/src/e2e/key_schedule.dart` (Dart).

---

## 6. Key confirmation

```
tag_a = HMAC-SHA256(k_confirm, "agent-finished")   // sent by agent in handshake:agent-ready (sealed)
tag_p = HMAC-SHA256(k_confirm, "phone-finished")   // sent by phone in app:ready (sealed)
```

Both sides use **constant-time comparison** — `timingSafeEqual` in TS,
`verifyConfirmTagV2`'s accumulating XOR loop in Dart. A tag mismatch is a hard
handshake failure: keys are discarded and the attempt ends. There is no silent
fallthrough.

The confirm gate means **no application-layer traffic is ever dispatched on
unconfirmed keys**: the agent's `onHandshakeComplete` callback (which starts
services and begins dispatching) fires only after `tag_p` verifies; the phone
dispatches nothing before `established`.

Canonical implementation: `bridge/src/e2e/confirm.ts` (TS) and
`packages/antgrid_relay_client/lib/src/e2e/confirm.dart` (Dart).

---

## 7. Transport

This section is the byte-level contract a reimplementation must match. §8 covers
the state machine around it.

**Framing:** `nonce(12 bytes) ‖ ciphertext ‖ tag(16 bytes)`

**Cipher:** AES-256-GCM with random 96-bit nonces (production; a test-only hook
allows fixed nonces for golden-vector verification).

**Directional keys:**

| Side | Send key | Receive key |
|---|---|---|
| Agent | `k_a2p` | `k_p2a` |
| Phone | `k_p2a` | `k_a2p` |

Directional keys eliminate the reflection/nonce-collision class: a frame sealed
by the agent with `k_a2p` cannot be replayed back as a frame "from the phone" —
it would be opened with the agent's recv key `k_p2a`, a different key, and fail
authentication.

**GCM nonce birthday bound:** Random 96-bit nonces have a collision birthday
bound at ~2^32 messages per key. Keys are per-connection and per-direction; ~4
billion messages in one terminal session is orders of magnitude beyond any
realistic workload. No counter-nonce scheme is needed; revisit only if a future
feature multiplexes bulk transfer over one session key.

**Cipher swap (Dart only).** `E2eTransportDart.useAlgorithm` accepts any
`AesGcm` so Flutter hosts can install a native-backed implementation — the
default pure-Dart cipher runs at single-digit MB/s on the calling isolate, and a
tunneled preview response is megabytes of it. Anything installed there MUST stay
byte-compatible with node:crypto's `aes-256-gcm` and the framing above. The
handshake primitives are deliberately **not** swappable: they produce the
transcript bytes the bridge verifies.

Canonical implementation: `bridge/src/e2e/transport.ts` (TS) and
`packages/antgrid_relay_client/lib/src/e2e/transport.dart` (Dart).

---

## 8. Session lifecycle

### 8.1 Frame-kind dispatch

Downgrade is prevented **structurally** by the route-frame kind byte
(`antgrid-wire` `frame.ts`), not by a per-connection `confirmed` flag. `kind=1`
(`handshake`) admits exactly the two plaintext handshake types (`client-hello`,
`agent-hello`); everything else is `kind=0` (`sealed`) and is decrypt-or-drop at
all times. There is no plaintext app-traffic path to lock out — a `kind=1` frame
that is not a signature-valid handshake message is dropped with a log, and the
receiver never try-parses ciphertext as plaintext. This supersedes the v2
"post-establishment plaintext lockout".

The relay does not interpret `kind`; it parses the header for `to`/`channel` and
forwards route frames opaquely.

Within `kind=0`, sealed plaintext is one of two shapes and the split is
unambiguous: **session frames are bare `{ type, … }` objects**
(`handshake:agent-ready`, `app:ready`, `established`, `ping`, `pong`,
`session-takeover`), while app traffic is **always** wrapped in a stream
envelope `{ s?, m }`. A top-level `type` is therefore never app traffic, and
`s` absent or `"0"` is the machine control plane.

### 8.2 Establishment is bidirectionally acked

Neither side dispatches app traffic before its terminal event — agent: verified
`tag_p`; phone: the sealed `established { attemptId }`. The phone retransmits
`app:ready` on an interval (re-sealed each time; GCM nonces are per-seal) until
`established` arrives, which closes the dropped-`app:ready` wedge. The agent's
`app:ready` handler is idempotent: a duplicate for the live attempt just
re-acks. Enforced in `bridge/src/relay-client.ts` (kind-byte receive dispatch
plus the `established`/`pending` attempt state) and
`packages/antgrid_relay_client/lib/src/connection_handshake.dart`.

### 8.3 Rekey on a live session (make-before-break)

Because a live session can no longer be downgraded, the agent is free to rekey
in place. On any `kind=1` `client-hello` whose transcript signature verifies
against the pinned phone identity — even while a session is established — the
agent runs a fresh attempt (new `attemptId`) while keeping the **old session keys
live for RECEIVING only** (at most two live receive contexts). When the new
attempt's `app:ready` confirm tag verifies, it atomically swaps send+receive to
the new keys and zeroizes the old set.

Security argument:

- **No forgery** — the same signature requirement the lockout protected: a
  `client-hello` without a valid transcript signature over the pinned phone key
  never starts an attempt.
- **No replay-teardown DoS** — a *replayed* captured `client-hello` starts a
  half-open attempt that can never confirm (the replayer lacks the ephemeral
  private key) and expires on its own; the live session is untouched, so
  rekey-on-live-session introduces no teardown surface.
- **No downgrade** — `kind=0` is decrypt-or-drop always; there is no plaintext
  app path to fall back to.

The phone drives a rekey (a fresh `ConnectionHandshake`, new `attemptId`, on the
live socket) on any of: missed sealed pongs (§8.5), a run of consecutive RPC
timeouts while established, or peer-online following a peer-offline. Owned by
`MachineSession`.

### 8.4 Cross-device takeover (break-then-make)

A signature-verified `client-hello` from a **different** peer is not a rekey —
it displaces the live session outright (one active phone per machine). The
signature is proof of the new phone's identity, so the agent does not wait for
liveness to discover the old session is obsolete: it sends a sealed
`session-takeover` to the displaced phone *on that phone's still-live keys*,
then tears the session down and proceeds with the new attempt.

The notice is best-effort (the displaced device may already be gone) but not
optional: without it the loser only learns via liveness timeout and rekeys
straight back, producing a two-device ping-pong. On the phone, `session-takeover`
is **report-only** — `MachineSession` tears down and emits on `takeoverEvents`,
and nothing re-establishes automatically, because two devices each reclaiming on
takeover would evict each other forever. Re-establishing is a user action.

### 8.5 Sealed liveness

After a period of sealed-receive silence, a side sends a sealed `ping`; the peer
answers a sealed `pong`. Both sides implement both roles. After a bounded number
of consecutive unanswered pings the E2E session is declared dead. The socket
underneath may well still be up — this detects an E2E layer that died alone.

The two sides then diverge, and deliberately: the **phone** drives a rekey on
the live socket (§8.3), while the **agent** drops its keys and waits to be
rekeyed. Only the phone may initiate (pull model), so an agent that tried to
re-drive would have nothing to send.

Any structurally valid route frame counts as liveness, even if its sealed
payload later fails to decrypt: the socket demonstrably delivered real bytes,
and sealed binary traffic (terminal output, file data) must count the same as an
explicit `pong`.

### 8.6 Key lifetime and zeroization

Session keys (`k_a2p`, `k_p2a`, `k_confirm`) are per-connection and are never
persisted to disk, logs, or closures. `ss` is zeroized immediately after
`HKDF-Extract`. Every teardown path zeroizes (backing buffers overwritten):

| Trigger | Path |
|---|---|
| Socket loss / client teardown | `resetE2eState` |
| Rekey confirmed | swap, then zeroize the superseded set |
| Cross-device takeover | `tearDownEstablished` after the notice |
| Half-open attempt expiry | `tearDownPending` — candidate keys only |
| E2E declared dead (missed pongs) | `tearDownEstablished` |

All of these live in `bridge/src/relay-client.ts`; it is the only owner of E2E
key material on the agent side. Note what is **not** on this list: evicting a
warm project core detaches a stream, it does not touch session keys — there is
one key set per machine socket, not one per project.

Zeroization is best-effort in GC languages; the explicit `fill(0)` /
`fillRange(0, …, 0)` calls prevent the values from lingering in reachable memory
longer than necessary.

### 8.7 Tunables

Values live in code and move; these are the names to look up. Agent side is
`bridge/src/relay-client.ts`, phone side `machine_session.dart` /
`connection_handshake.dart` / `connection_supervisor.dart`.

| Constant | Home | Bounds |
|---|---|---|
| `HALF_OPEN_MS` | agent | How long a half-open attempt (client-hello seen, `app:ready` never arrived) holds candidate keys |
| `PING_SILENCE_MS` / `kPingSilenceSeconds` | both | Sealed-receive silence before a sealed `ping` |
| `MAX_MISSED_PONGS` / `kMaxMissedPongs` | both | Unanswered pings before the session is declared dead |
| `_kConsecutiveTimeoutsToRekey` | phone | Consecutive RPC timeouts on an established session before a rekey |
| `defaultAttemptTimeout` | phone | One handshake attempt, client-hello → `established` |
| `appReadyRetransmit` | phone | Sealed `app:ready` retransmit interval |
| `_kMaxInitialHandshakeAttempts` | phone (supervisor) | Attempts before the initial connect is surfaced as failed |
| `backoffBaseMs` / `backoffCapMs` | phone (supervisor) | Per-rung exponential retry backoff |

The two sides' liveness constants must stay in lockstep — the Dart copies are
declared as a hand-mirror of the bridge's.

---

## 9. Security claims

**Mutual authentication.** Both parties authenticate via Ed25519 signatures over
the canonical transcript. The phone verifies `sig_a` against the pinned
`agentEd25519Pub` (`/account/agents`, or the `RecentAgent` row it wrote). The agent verifies `sig_p`
against the `phoneEd25519Pub` it resolved from the account device inventory.
Neither can be impersonated without the corresponding Ed25519 private key.

**Full forward secrecy.** Both sides generate fresh X25519 ephemeral keypairs per
handshake; the phone never reuses its persisted Ed25519 identity key as the DH
ephemeral. Compromise of either party's Ed25519 signing key after a session ends
does not expose session keys, because session keys derive from the ephemeral DH
exchange and the ephemerals are discarded after key derivation.

**Active-relay MITM resistance.** `sig_a` covers both ephemerals
(`agentX25519Pub` and `phoneX25519Pub`). A relay that swaps a DH public key
cannot re-sign the transcript with the agent's Ed25519 key, which it does not
hold. The phone verifies `sig_a` against the pinned agent identity, so any
tampering with the ephemerals fails verification.

**Cross-context replay resistance.** The transcript includes `registrationId`
(the machine binding), the protocol version byte `0x02` and domain string
`antgrid.e2e-handshake.v2`, and a 32-byte phone-generated `nonce` fresh per
attempt. A valid transcript signature cannot be replayed to a different machine
or protocol version, and cannot be replayed across attempts. A replayed
`client-hello` can start a half-open attempt but never confirm it (§8.3).

**UKS / identity-misbinding resistance.** Both device identities
(`agentDeviceId`, `phoneDeviceId`) are included in the transcript that both
parties sign, and the transcript hash is bound into the key schedule as the HKDF
salt. An attacker cannot cause two honest parties to derive the same session
keys while believing they are talking to different identities.

**KCI note.** If an agent's Ed25519 signing key is compromised, the attacker can
impersonate *that agent* to any phone that has it pinned. They cannot use it to
impersonate a phone to the agent (a different keypair). Past sessions remain
protected by forward secrecy — the signing key is not used in key derivation.

**Out of scope.** `attemptId` is unauthenticated (§3) and the transcript carries
no project identity (§4), so neither is relied on for any claim above.

---

## 10. Test vectors

Cross-language interop oracle: `evals/fixtures/e2e-handshake-vectors.json`.

The fixture fixes the inputs — Ed25519 seeds, X25519 private keys, nonce, device
IDs — and pins the expected outputs:

| Key | Contents |
|---|---|
| `transcripts` | Canonical transcript bytes (hex) for both `sig_p` (empty agent-ephemeral slot) and `sig_a` (both ephemerals) |
| `signatures` | Ed25519 signatures over each (deterministic) |
| `keySchedule` | `kA2pHex`, `kP2aHex`, `kConfirmHex` |
| `confirm` | `agentTagHex`, `phoneTagHex` |
| `transport` | One AES-GCM seal/open vector per direction, with a test-only fixed nonce |

The HKDF context hash is not pinned separately — the three derived keys pin it
transitively.

**Consumers** (both must pass on identical fixtures):
- `bridge/tests/e2e/vectors.test.ts` — TypeScript (Bun)
- `packages/antgrid_relay_client/test/e2e_vectors_test.dart` — Dart

**Regeneration:** `cd bridge && bun run scripts/gen-e2e-vectors.ts`
Only run this to adopt a deliberate protocol change — a diff to the fixture is a
breaking change to cross-language interop.
