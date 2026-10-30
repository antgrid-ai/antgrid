# Session bus over a blind relay: architecture proposal

**Status:** Accepted 2026-10-30, including the three decisions under §Resolved
implementation choices that amend a standing rule. Nothing here is
implemented. The transitional fix on `fix/remote-driven-carrier` (an app
session driving a machine may carry that machine's outbound bus frames) is
unaffected by this document and lands first; this proposal replaces the
mechanism it patches.

The session bus lets one agent session reach another. On one machine it works
with nothing underneath it. Across machines it does not work unless a desktop
app happens to be attached to the right project on the sending machine, and
when it does work a phone that goes to sleep loses messages with no error. This
proposal moves cross-machine delivery off the app and onto the central relay
as a **sealed store-and-forward queue the relay cannot read**, gives the bus a
delivery promise it can keep, and defines the second message kind an
orchestrating agent needs: a control request that a machine executes rather
than a text a session may read.

For example, a session on a laptop can post a finding to a session on a desktop
whose owner is asleep, be told the desktop's bridge has it, and know the
desktop's agent will see it the next time it runs. Later, an orchestrator
session can start a session on each of three machines, hand each a task, and
collect three independent answers, with no app open anywhere.

## Goals and boundaries

- Cross-machine messages between sessions of one account's machines, with no
  app on the path.
- A delivery promise stated in rungs a caller can act on, with the top rung
  honestly excluded.
- A request/response kind that executes control verbs on another machine, with
  authorization held by the receiving machine.
- The relay stays blind: it holds ciphertext, learns sizes, ids and device ids,
  and never a byte of what was said.
- A bridge still cannot dial another bridge. Nothing here opens a native
  connection between two machines.

Out of scope: a hosted message store; relay-side durability across restarts;
exactly-once delivery; artifacts larger than today's `MAX_ARTIFACT_BYTES`; an
orchestrator user interface; making an agent obey a message.

Superseded on purpose: the standing decision in `bridge/src/protocol.ts`
(`SessionBusMessageWire`) that *"messages are lossy on purpose, and reliable
delivery behind text that changes no state would be unbounded retry buying
nothing."* That held while the bus carried only commentary between peers. An
assignment from an orchestrator changes what a session does next, and an
assignment path that may silently drop is not one an orchestrator can be built
on. Retry is bounded below by an acknowledgement and above by a TTL, so it is
neither unbounded nor free.

## Comparable systems

| | SMTP / XMPP s2s / Matrix | MQTT (QoS 1) | Signal | Antgrid today | Antgrid (this proposal) |
|---|---|---|---|---|---|
| Who holds a message for an offline recipient | The receiving server | The broker | The server, as ciphertext | Nobody: the sending bridge holds it until a carrier appears | The relay in memory as ciphertext; the sending bridge durably |
| Who can read it in transit | The servers | The broker | Nobody (end-to-end) | The app that carries it, in principle; in practice it forwards verbatim | Nobody: sealed to the recipient bridge's key, signed by the sender's |
| Delivery contract | Best effort with bounce | At least once, `PUBACK` | At least once, client ack, server deletes | Fire-and-forget; receipt is best effort and never retried | At least once, ack from the recipient bridge, dedup on message id |
| Needs a third device online | No | No | No | **Yes**, an app attached to the right project | No |
| Direct peer dialing | Server to server | None | None | None by design | None by design |

MQTT's QoS 1 is the clearest statement of the contract this proposal adopts:
the sender retries until a `PUBACK`, the receiver deduplicates, and the message
id is the join. Signal is the closest in trust model: the server is a blind
queue, the recipient's long-term key seals the box, and durability on the
sending side is the client's retry. Store-and-forward federation (SMTP, XMPP,
Matrix) is the standard shape for two nodes that cannot dial each other, and is
what Antgrid lacks; its servers read content, which Antgrid's relay must not.

The courier pattern Antgrid uses today appears in eventually-consistent sync
systems, not in messaging. Its failure modes are the ones observed live: a
project that nobody has open in an app cannot send at all, and an app that is
backgrounded keeps its socket alive while delivering nothing, so
`sendToAppSession` returns true and the outbox entry that could have retried
is retired. No guard on the app side changes the class of the failure; a
consumer device is on the delivery path.

## Architecture

### Transport

A cross-machine bus message travels sender bridge → central relay → recipient
bridge over the WebSocket each bridge already holds (`CentralControlClient`,
`bridge/src/central-control-client.ts`). The relay adds four client frames and
four server frames to `packages/antgrid-wire/src/relay-protocol.ts`, all
carrying a `blob` it never parses:

```
client → relay   bus:send     { id, to, blob: { epk, box }, ttlMs }
client → relay   bus:ack      { id, outcome: "applied" | "refused", error? }
client → relay   bus:drain    {}                     (optional: "send me what you hold")
relay → client   bus:receipt  { id, state: "queued" | "delivered-to-socket" }
relay → client   bus:deliver  { id, from, blob }
relay → client   bus:acked    { id, outcome, error? } (the recipient's ack, forwarded)
relay → client   bus:refused  { id, reason, retryable }
relay → client   bus:offline  { id }                  (recipient not connected; queued)
```

`to` and `from` are bare agent device ids, the same ids the relay already keys
connections by (`connections.getByDeviceId`, `relay/src/connections.ts`). The
relay enforces, before it queues anything:

1. The sender is an authenticated `agent` connection.
2. `to` names an `agent` device in the same account
   (`getConnectionsForUser(conn.uid)` is the existing same-account lookup used
   by `sameAccountPeers`), **or** a device the account's inventory lists as an
   agent even if offline. Offline recipients are the point; the relay asks web
   over the existing `/internal/` surface and caches the answer per account for
   the lease interval.
3. Per-sender budgets: frames per second and bytes per minute, bounded like
   `pushRateLimiter` and keyed by `conn.deviceId`.
4. Per-recipient queue bounds: `BUS_RELAY_QUEUE_MESSAGES` and
   `BUS_RELAY_QUEUE_BYTES` per device, and a TTL of `min(ttlMs,
   BUS_MESSAGE_TTL_MS)`.

A `blob` is delivered to the recipient's live socket when one exists and queued
otherwise. The queue is in memory. A relay restart loses what it held; the
sender notices by the missing ack and resends after it reconnects. This is
deliberate: durability lives in the sending bridge's outbox (`held-store.ts`,
retried on `OUTBOX_TICK_MS` in `session-bus/coordinator.ts`), which already
exists, survives bridge restarts, and needs no relay-side database. The relay
stays as close to stateless as a queue can be.

`MAX_CONTROL_FRAME_BYTES` on the relay socket (`relay/src/server.ts`) rises
from 64 KiB to 128 KiB. A sealed `MAX_ENVELOPE_BYTES` (64 KiB) plaintext is
about 88 KiB as base64, and an artifact chunk (`ARTIFACT_CHUNK_BYTES`, 64 KiB)
seals to the same. The per-sender byte budget, not the frame cap, is what
bounds a sender.

The relay fans out `peer-online` / `peer-offline` to same-account **agents** as
well as apps (`fanOutAgentPresence` today tells apps only). A sender holding a
message for an offline machine retries on that machine's `peer-online` rather
than on the tick alone.

### Keys

Each agent device gets a dedicated static X25519 **bus key**, generated beside
its Ed25519 identity on first run (`DeviceIdentity`, `bridge/src/device.ts`,
gains `busX25519PublicKey` / `busX25519PrivateKey`; the private half never
leaves the machine, like the Ed25519 seed). The public half is registered on
the existing heartbeat (`POST /account/devices/me/heartbeat`,
`web/src/routes/agents.ts`) and stored in a new nullable `Device.busPublicKey`
column.

Distribution rides the authorization snapshot every bridge already fetches
every 20 seconds (`AuthorizationLease`, `bridge/src/peer/authorization-lease.ts`).
`buildAuthorizationSnapshot` (`web/src/models/peer-authorization.ts`) gains a
`machines` array beside `peers`: every non-revoked `agent` device in the account
other than the caller, as `{ deviceId, displayName, machineName, ed25519Pub,
busPublicKey, orchestrator }`. It carries **no endpoint id and no relay
endpoint registration**. The `peers` array keeps its bipartite rule unchanged,
and `acceptPeer` (`bridge/src/peer/native-host-connection.ts`) admits only
endpoint ids from `peers`, so a bridge still cannot be admitted by another
bridge whatever it learns from `machines`. The one-line predicate at
`peer-authorization.ts` that hides agents from agents was doing two jobs; this
keeps the dialing half and relaxes only the knowing half.

A dedicated key rather than an X25519 key derived from the Ed25519 identity:
the push path already set the precedent of a separate static sealing key
(`pushPubkey`), key reuse across signing and agreement is the thing every
treatment of the subject tells you not to do, and nothing on the Dart side ever
needs to open a bus blob, so there is no mirror cost either way.

### Sealing

The box follows `sealPush` (`bridge/src/push/seal.ts`): ephemeral-static X25519,
HKDF-SHA256 bound to the ephemeral public key, AES-256-GCM. Three additions:

- HKDF info `antgrid-bus-v1`, so a bus key and a push key can never derive the
  same AEAD key even if someone reuses one.
- **Associated data** is the relay-visible header `from ‖ to ‖ id`. A blob
  re-addressed in transit, by a relay or anyone else, fails to open.
- **An inner signature**: the plaintext carries `sig`, Ed25519 over `(from, to,
  id, body)` with the sender's device identity key, and the recipient verifies
  it against the `ed25519Pub` the snapshot's `machines` entry for `from` holds.
  Provenance therefore does not rest on the relay. A compromised relay can drop
  or delay a message; it cannot author one, and it cannot replay one under a
  different id because the id is under both the AAD and the signature.

Sealing and opening live in `bridge/src/session-bus/seal.ts`, beside the stores
it serves, with `seal.test.ts` next to it. The wire schema for the blob lives in
`antgrid-wire` and is MPL like the rest of that package; the queue logic in
`relay/` is ELv2 and nothing moves across the boundary.

### The inner message

The plaintext of a box, after the AAD and signature, is:

```
{
  v: 1,
  from: <machineDeviceId>,
  to:   <machineDeviceId>,
  id:   <messageId>,
  role: "agent" | "orchestrator",        stamped by the sending bridge, never agent-authored
  kind: "message" | "request" | "response",
  correlationId?: string,                 request ↔ response join; batchId lives in request body
  body: AbMessage,                        exactly one, bare JSON, as today
  sig:  <base64 Ed25519>
}
```

`body` for `kind: "message"` is one of today's `session-bus:post`,
`session-bus:notify`, `session-bus:fetch`, `session-bus:fetch:result`. Their
schemas and `BusEnvelopeSchema` are unchanged. `session-bus:ack` is retired as
a wire type; the transport-level `bus:ack` carries the coordinator's outcome
(`applied` / `refused` with the refusal text) and is the one receipt.

`body` for `kind: "request"` is a control-plane `request` message
(`method`, `params`, `requestId`) from the set §Orchestration lists, and
`kind: "response"` carries its `response`. These are the same shapes the app
sends on the native session stream today, so `dispatchControlPlaneInbound`
(`bridge/src/host-server.ts`) answers them with no new handlers; it gains an
inbound source `"bus"` beside `"relay"` and `"loopback"`, and the sender's
verified role.

### Where it plugs in

`SessionBusCoordinator` (`bridge/src/session-bus/coordinator.ts`) already runs
machine-wide on the host (`host-server.ts`, one instance for every core,
resolving through `sessionIndex`). Its `send(frame, ctx)` seam is the one place
an outbound frame leaves. Today that function picks a project core and a
carrier; after this proposal it seals `frame` to `ctx.to.machineId` and hands
the blob to `CentralControlClient`. Both roles (`lead` and `peer`) collapse to
the same path, because the address is enough and no route back has to be
remembered. The same-machine path (`deliverLocal`) is unchanged.

Inbound, `CentralControlClient` opens a `bus:deliver`, verifies AAD and
signature, checks `remoteFrameAllowed` and `peerBusReachAllowed` exactly as a
relay-origin frame is checked today (`agent-core.ts`), then hands `kind:
"message"` to `sessionBus.handleInbound` and `kind: "request"` to
`dispatchControlPlaneInbound`. The ack goes back after that call returns.

## The delivery promise

Stated as rungs, because the top one is not the bus's to make:

| rung | fact | witnessed by | surfaced as |
|---|---|---|---|
| 1 | The relay holds it | `bus:receipt` | `sent: true` |
| 2 | The recipient bridge has applied it to its store | `bus:ack { applied }` | `delivered: true`, the stamp on the sender's log entry |
| 3 | The recipient session has had it rendered into a turn | the existing delivery queue, `delivery-queue.ts` | visible in that session's own transcript; not reported back |
| 4 | The recipient agent acted | nothing but an explicit reply on the thread | `antgrid_thread` |

Rung 2 is the promise: *this message is on the target machine's disk and will
be shown to that session when it next runs*. The MCP answer
(`sendLine`, `bridge/src/mcp/server.ts`) and `SendResultView`
(`session-bus/api.ts`) say it in those words. Rung 4 is excluded in the same
words, in the tool descriptions, because an orchestrator that reads rung 2 as
rung 4 will plan on work that was never done.

Mechanics:

- **At least once.** The sender's outbox holds a frame until a `bus:acked`
  names its id, resending on every tick and on the recipient's `peer-online`,
  until `BUS_MESSAGE_TTL_MS`. A `refused` ack stops retry and stamps the log
  entry with the refusal; so does a terminal `bus:refused` from the relay.
- **Dedup on receipt.** `handleInbound` gains a `seen(messageId)` check against
  the message log before `onMessage`; a duplicate is acked `applied` and not
  applied again. Today's `handleInbound` has no such check, which is correct for
  a transport that never redelivers and wrong the moment one does. This lands in
  the same change as retry, never after it.
- **Ordering** is per `(from, to)` by relay queue order and is not promised
  across a reconnect. Threads already tolerate this; the thread id is a
  correlation with no state machine (`BusEnvelopeSchema.threadId`).
- **Holds are still holds.** Remote access off on the sender refuses up front
  (`offMachineSendAllowed`); off on the recipient refuses at its gate and the
  ack says so. A recipient machine that is offline is a queued message, not a
  refusal, and the sender is told `held` with the reason.

## Orchestration

An orchestrator is a session whose job is to drive other sessions. It needs
two things the bus does not give it today: a way to make a machine *do*
something with a result, and a roster it can address without an app having
pushed one.

### Two kinds, two promises

`kind: "message"` is what exists: post, notify, reply, rendered into the target
agent's prompt as fenced content (`session-bus/delivery.ts`). It is advisory at
the last hop and must stay so; the fence is the prompt-injection boundary.

`kind: "request"` executes. Its `body.method` is one of the control verbs
`dispatchControlPlaneInbound` already answers for an app, initially:

- `machine.capability-card` (with sessions): the roster.
- `sessions.list`, `project:sessions`: what a project holds.
- `project:start`: warm a project from the catalog.
- `session:create` (tool, mode, isolation, base branch), then `session:start`
  with its one-shot `initialPrompt`: the orchestrator's primary primitive, two
  requests. `session:start` alone wakes a stopped session; `session:stop`
  stops one.
- `scheduler.*`: what the app may do today, bounded the same way.

Every verb keeps the gate it has: the machine's remote-access switch, the
project catalog (`seenProjects`) and `isSafeProjectId`. None is relaxed for an
orchestrator. "Start a session on machine B" means "B's bridge, under B's
policy, starts one if B allows it", and refusal is a normal response.

### Authorization

Two facts, both checked on the receiving machine:

1. **Who is asking.** `role: "orchestrator"` in the signed header is accepted
   only when the snapshot's `machines` entry for `from` also says
   `orchestrator: true`. The grant is an account-level device attribute set by
   the account owner (a CLI flag first; an app surface later), stored on
   `Device` in web and served in every snapshot. A header the snapshot does not
   back is treated as `role: "agent"`.
2. **What this machine allows.** `agentReach` (today a boolean,
   `agent-reach:get/set`, read by `peerBusReachAllowed` in `agent-core.ts`)
   becomes three-valued: `off`, `messages`, `control`. `messages` is today's
   `on`. `control` additionally admits `kind: "request"` from an orchestrator.
   Default stays `off`. A request arriving under `messages` is refused with a
   code the orchestrator can read.

An `agent`-role sender may send `kind: "request"` only for read-only methods
(`machine.capability-card`, `sessions.list`), which is what lets any session
refresh its own directory without an app.

### Fan-out and results

An orchestrator addressing N machines sends N independent requests sharing a
`batchId` in the body. Each produces its own ack and its own response; there is
no cross-machine transaction and none is implied. Per-target timeout is the
orchestrator's to choose and the MCP tool exposes it. A machine that is offline
answers nothing until it is online, and the orchestrator sees `held` for it, not
failure.

### Budgets

The pair budget (`pair-budget.ts`: no-progress halt, notifies per hour) applies
to `kind: "message"` exactly as today. It does not apply to `kind: "request"`:
a halt lifted only by a human is the right brake on two agents talking in
circles and the wrong one on a session that starts twelve others. Requests get
a per-sender-machine rate on the receiving bridge and the relay's byte budget,
and nothing else; the receiving machine's `control` setting is the off switch.

### Waking and warming

`session:start` on a stopped session is `startLocalSession` today. A request
naming a session in a cold project warms the project first, bounded as
`warmForInboundBus` is (catalog, safe id, folder exists, opened `local`). This
is the transitional fix's Fix 2, kept and generalized.

### MCP surface

- `antgrid_post` / `antgrid_notify` / `antgrid_reply` answer with the rung
  reached, in words: *held on this machine*, *the relay has it*, *machine B's
  bridge has it and will show it to the session*.
- `antgrid_thread` shows per-message delivery state from the stamps.
- New: `antgrid_request` with `to` (machine, or machine+session for session
  verbs), `method`, `params`, `timeoutMs`; answers with the response or the
  refusal. Dispatched by name and refused by the bridge, per the standing rule
  for the MCP server.
- `antgrid_list_sessions` reads a directory the bridge now refreshes itself
  (§Directory), and reports a machine's rows as *as of* a time, never as
  current.

## Directory

The remote half of the directory is today an expiring mirror the app fills by
peeking capability cards and pushing rows over a loopback verb
(`remote-directory.ts`, `session-bus:remote-directory`). The reason for the
TTL and the loopback-only rule is in `bridge/AGENTS.md`: a bridge cannot ask
another bridge, and a verb reachable from a peer would let a phone write rows a
local agent then reads as peers.

Both reasons go away. A bridge refreshes a machine's rows by sending that
machine `kind: "request"`, `machine.capability-card`, over the queue, and the
rows come back signed by the bridge they describe. The mirror stays as a cache
with the same per-row sanitization (`sanitizeRow`, the only path in), the TTL
becomes a refresh interval, and `session-bus:remote-directory` and the app's
pump are deleted. `REMOTE_CARRIER_SILENCE_MS` and the carrier-presence
reasoning around it go with them.

## Security

- **Relay compromise** reads nothing (sealed), forges nothing (inner
  signature over `from, to, id, body`), re-addresses nothing (AAD), and
  replays nothing (id under both, dedup on receipt). It can drop and delay,
  which are the same powers it has over presence today.
- **Cross-account** is refused at the relay by the same-account check and, if
  that failed, at the recipient: a `from` that is not in its snapshot's
  `machines` has no key to verify against and is dropped before parsing.
- **A stolen bus private key** lets its holder read messages sealed to that
  machine until the key is rotated. Rotation is a new keypair on the next
  heartbeat; the snapshot carries the new public key within one lease interval
  and senders seal to whatever the snapshot says. Messages sealed to the old key
  and still queued are lost, which the sender's retry recovers.
- **Role forgery** fails at the snapshot check. An orchestrator grant is
  revoked by clearing the device attribute; it takes effect within one lease
  interval everywhere.
- **Inbound bounds** are the ones a relay-origin frame has today, applied
  before the coordinator sees anything: `remoteFrameAllowed`, the machine
  switch, and for requests the catalog and safe-id checks each verb already
  performs. The widening is deliberate and bounded: a machine with
  `agentReach: control` can be driven by an orchestrator the account owner
  granted, on projects it already knows.
- **Logging** on the relay records ids, device ids, sizes and outcomes, never a
  blob. On the bridge the standing rule holds: a log line carries `lineKey`'s
  digest and never content (`line-key.ts`, enforced by
  `session-bus-logging.test.ts`).

## What is removed

On the bridge: `ClientBusCarrierMessage` and the `client:bus-carrier` handling,
`ProjectCore.sendLead` / `carrierPresent` / `sendToAppSession` /
`sendToOwner`'s bus use, `AgentCore.busCarrierPeers`, the coordinator's route
table (`noteRoute`, `routeFor`, `route-store.ts`, `MAX_BUS_ROUTES`,
`BUS_ROUTE_TTL_MS`, `BUS_ROUTE_PERSIST_INTERVAL_MS`), the host's
`busRouteMissWarned` / `busOwnerMissWarned` latches, `ownerCarriesSessionBus`
and the loopback hello's `capabilities.sessionBusCarrier`, the
`session-bus:remote-directory` verb and `remote-directory.ts`'s push ingest,
and the `session-bus:ack` wire type.

On the app: `app/lib/session_bus/session_bus_carrier.dart`, its test, the
`declareBusCarrier` router call, `remoteOpenProjects` on the registry, the
directory pump, and the `sessionBusCarrier` capability on the loopback hello.
The app keeps reading its own bridge's bus (`session-bus:inbox`, `:thread`,
`:directory`) and gains a delivery-state column from the stamps.

On the relay: nothing is removed.

## Invariants amended

These lines are true today and false after this lands; each changes in the
same PR as the code that invalidates it.

- Root `AGENTS.md`, Project Overview: *"The central WebSocket is control-only
  and never accepts application payloads."* becomes: *"The central WebSocket
  carries control frames and sealed bus blobs it cannot read; it never accepts
  a readable application payload."* The Conventions rule **NEVER add a
  plaintext payload path** is unchanged and still true.
- `relay/AGENTS.md`, the security invariant: *"The relay never accepts
  application payload bytes"* becomes *"never accepts application payload bytes
  it can read; bus blobs are opaque and bounded (`bus-queue.ts`)."*
- `docs/architecture.md` §The session bus: rewritten to point here.
- `bridge/AGENTS.md` §The session bus: the first, third, fourth and eighth
  bullets (which way a frame leaves; the directory's loopback-only arm; what
  may be reported as delivery; `sendToAppSession`) are replaced by two: where a
  cross-machine frame leaves and arrives, and what each delivery rung is
  witnessed by. The no-progress-halt, fenced-delivery, capability-card,
  address-matching and logging bullets stand.
- `bridge/src/protocol.ts`, `SessionBusMessageWire`: the "lossy on purpose"
  paragraph is replaced by a pointer to the at-least-once contract above.

## Delivery and validation

Phases, each mergeable on its own and each leaving the bus working:

1. **Keys and the snapshot.** Bus keypair on the bridge; `busPublicKey` on
   `Device` with its migration; heartbeat registration; `machines` in the
   snapshot. No message moves yet. Gate: `web` tests for the snapshot shape,
   bridge test that a device with no bus key is listed with `busPublicKey:
   null` and never sealed to.
2. **Relay queue and sealing.** The eight frames, bounds, presence fan-out to
   agents; `session-bus/seal.ts` with AAD and signature. Gate: relay tests for
   every refusal reason and both bounds; bridge `seal.test.ts` including a
   re-addressed blob and a wrong-signer blob failing to open; a new eval
   `evals/tests/gate-session-bus-relay.test.ts` with two bridges and the
   in-process relay from `setupTestEnv()`, no app: a post crosses; a post to an
   offline bridge is held, then delivered on its reconnect; a redelivered
   message is applied once; remote access off on either side refuses with the
   documented code.
3. **The seam.** `send(frame, ctx)` seals and enqueues; inbound opens and
   dispatches; dedup in `handleInbound`; `bus:ack` replaces `session-bus:ack`;
   `SendResultView` and `sendLine` say the rung. The transitional carrier path
   is deleted in this phase, not later, so there is never a build with two
   outbound paths. Gate: every suite under `bridge/tests/session-bus-*.test.ts`
   and `host-server.test.ts` green with the carrier tests deleted; the eval
   above extended with the thread round trip and the pair budget crossing the
   relay.
4. **Directory.** Self-refresh over `kind: "request"`; the pump and the
   loopback verb deleted. Gate: the eval lists a peer's sessions with no app
   having run.
5. **Orchestration.** `role`, the snapshot's `orchestrator` attribute and its
   CLI, `agentReach` three-valued, `dispatchControlPlaneInbound` source `"bus"`,
   `antgrid_request`. Gate: the eval starts a session on the second bridge from
   the first, with an initial prompt, under `control`; the same request under
   `messages` is refused; a forged `role` header is treated as `agent`.
6. **App deletion** and the delivery-state column. Gate: `flutter test` with
   the carrier tests removed; `flutter analyze` once, last.

Per `AGENTS.md`, the bridge suite runs as `bun run --filter antgrid-bridge
test`, evals explicitly as `bun run --filter antgrid-evals test:evals`, and
every new control or stream verb is registered in
`bridge/tests/netwatch-ui.test.ts`. Schema versions start at 1 and carry no
upgrade path, since nothing here has shipped.

Live, on the fleet: with `antgrid-public` warm on two machines and no app open
on either, `antgrid_post` from one reaches the other's mailbox and
`antgrid_thread` shows `delivered`; close the recipient's bridge, post, reopen
it, and the post is there once; set `agentReach: control` on one and start a
session on it from the other.

## Deferred work and open questions

- **Relay durability.** If a relay restart under load loses enough in-flight
  messages that the outbox retry is visible to users, a small persistent
  queue on the relay is the next step; its store and the migration of this
  in-memory design are out of scope here.
- **Artifacts over the relay.** `session-bus:fetch` rides the queue in 64 KiB
  chunks, bounded by the per-sender byte budget. A 4 MiB artifact is sixty-four
  round trips. Acceptable for an opt-in pull; a streamed fetch is deferred.
- **Orchestrator surfaces.** Granting the role, choosing `control` on a machine
  and watching a fan-out are CLI-first here. The app surfaces follow the
  mechanism and are their own spec.
- **Cross-account** messaging is not planned.
- **Presence for agents** is new relay traffic per account; if accounts with
  many machines make it noisy, batch it.

## Resolved implementation choices

- **Relay queue over a machine-level native carrier.** A carrier declared on
  the native session stream instead of the project stream was examined and
  would be strictly better than the transitional fix, but it keeps a consumer
  device on the delivery path and cannot serve a machine whose owner's devices
  are asleep, which is the orchestrator's normal case.
- **In-memory relay queue with bridge-side durability** over a relay database:
  the outbox already exists and already survives restarts; a relay store would
  put a database on every message and a migration on every change.
- **Dedicated bus key** over a derived one: see §Keys.
- **Signed inside the box** over trusting the relay's `from`: the relay is
  trusted for admission today, not for content, and an authored message is
  content.
- **One transport-level ack** over keeping `session-bus:ack` beside it: two
  receipts for one fact would disagree eventually and nothing would say which
  was right.
- **Requests reuse the app's control verbs** over a new verb set: the gates,
  handlers and schemas exist and are already exercised from a less trusted
  caller than an account-granted orchestrator.
- **Role verified against the snapshot** over trusting the signed header alone:
  a signature proves the sender wrote the header, not that the account agreed
  with it.
- **Pair budget on messages only**: see §Budgets.
- **`control` as a third `agentReach` value** over a separate switch: one
  setting with three levels is one thing for the owner to understand, and
  `off` remains the default either way.
- **The central WebSocket may carry sealed blobs.** The root `AGENTS.md`
  invariant changes to *"never accepts a readable application payload"*, in
  the phase 2 PR that adds the queue, as §Invariants amended lays out. Agreed
  2026-10-30.
- **The orchestrator grant is an account-level device attribute**, set from
  the CLI first and verified against the authorization snapshot; app surfaces
  are a later spec. Agreed 2026-10-30.
- **The carrier path is deleted in the phase 3 PR that adds the seam**, not
  after it. `fix/remote-driven-carrier` lands first, unchanged. Agreed
  2026-10-30.
