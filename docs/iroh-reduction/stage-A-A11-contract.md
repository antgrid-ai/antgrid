# Stage A, wave A11: frozen implementer contract

Base: `a3fd8f72` (A0 to A10 committed). Four parts build in parallel and do not
talk to each other: **bridge-src**, **bridge-tests**, **dart+app** and
**evals**. This file is the only coordination between them. If it disagrees
with the code, the code wins, and the disagreement goes in your
`outOfScopeNeeds`. Do not guess the other part's side.

`stage-A-waves.md` has no A11 section, so this file is the whole spec. The
product has no users. Compatibility code is waste, and no shim, dual path,
capability probe or version check that exists only for an older app, bridge or
relay may survive this wave. Every item below was re-verified with `git grep`
at the base. Anything found live is listed in §7 with the reason.

## 0. What A11 does

1. **Dead-code sweep.** It deletes:
   - the desktop enable-relay wizard;
   - session takeover;
   - `MachineSession` re-establishment generations;
   - web's peers inventory and `x25519Pub` intake;
   - the relay's retired-streams shim;
   - `slotMachineDeviceId`;
   - the Dart request `action` plumbing and `deleteSession`;
   - the pre-frame `terminal:snapshot` path;
   - `agent:disconnecting`;
   - `publishExcept`;
   - two orphan eval helpers;
   - `ed25519-der.ts`.
2. **Old-app capability flags.** It deletes `checkoutRouting`, `pullsTree` and
   `terminalFramesV1` everywhere: the session hello, the loopback hello, the
   peer session view, every gate that reads them, and the `UPDATE_REQUIRED`
   refusal they produce.
   - Every app pulls trees and renders terminal frames.
   - Every app routes by checkout.
   - `sessionBusCarrier` stays (§7).

Nothing is added except:
- one named relay constant and two relay tests (§4);
- a fail-closed `mayAcceptFrom` (§2.3);
- one-line replacements where a deleted helper had callers.

### Acceptance: net source line count

- **Target:** A11's net source change is at most **-1,000**.
- **Projection:** -1,100 to -1,400.
  - bridge-src, including relay, web and wire: about -850.
  - dart+app: about -400.
  - evals: 0, because it is excluded by the pathspec.

The integrator measures with exactly this command, and no other pathspec:

```bash
git diff --numstat a3fd8f72 HEAD -- . ':!**/test/**' ':!**/tests/**' ':!evals/**' \
  ':!**/*.md' ':!**/test_helpers/**' ':!**/scripts/**' ':!**/*.json' \
  | awk '{a+=$1;d+=$2} END{print a,d,a-d}'
```

- The integrator records the measured number in the ledger, whatever it is.
- **Do not pad.** Delete only what this file names, plus code the named
  deletions leave with no caller. When you delete such code, say so in your
  report.

---

## 1. Wire records

### 1.1 Deleted everywhere (schema, `AbMessageSchema` union, `KNOWN_TYPES`, exported type, `handleAbMessage` case, Dart mirror)

The "Adding a message type" rule, run in reverse.

| Record | Bridge (`protocol.ts`) | Dart mirror | Notes |
|---|---|---|---|
| `agent:enableRelay`, `agent:disableRelay`, `agent:activationPending`, `agent:relayReady`, `agent:relayError` | Schemas at ~1619-1684. Also delete `AgentEnableRelayAuth`, `Base64ish` and `DeviceUuid` (their only users). Delete the union entries ~2673-2677, the types ~2854-2859, and `KNOWN_TYPES` ~3127-3128. Remove the `"agent:enableRelay"` entry from `BODY_REDACTED_MESSAGE_TYPES` and fix its doc ("these three" becomes the true count). | The app's `agent:relayError` listener in `app/lib/providers/agent_transport.dart` (~615-625). | The only emitter was `relay-promotion.ts`, which is deleted. Nothing else sends or emits any of the five. |
| `agent:disconnecting` | Schema ~651-654, union ~2623, type ~2788, `KNOWN_TYPES` ~3111. | none (no Dart handler) | The emitter in `ProjectCore.stop` (~780-785) goes, together with its 200 ms wait. |
| `terminal:snapshot:request`, `terminal:snapshot` | Schemas ~2021-2040, union ~2702, types ~2888-2889, the two set entries at ~2998 and ~3138, and the `protocol.ts` ~2986 comment. | `TerminalSnapshotRequestMessage`, `TerminalSnapshotMessage` and their parse cases in `ab_message.dart` (~1223-1260 and ~2125-2150). Both entries in each set of `project_message_classification.dart` (~60-61 and ~269-281). | Nothing emits `terminal:snapshot`: the only request handler answers with an upgrade error. Delete the `agent-core.ts` case (~2263-2270), `handleTerminalSnapshotRpc` (~4861-4873) and the `terminal.snapshot` RPC intercept (~4969-4985). `message-bus.ts:208` filters `terminal:output` alone. |
| `session:takeover` | none in `protocol.ts`. `packages/antgrid-wire/src/peer-protocol.ts`: drop it from `SESSION_FRAME_TYPES`, delete `SessionTakeoverFrame`, and change the doc from "five frames" to four. | `kSessionTakeover` in `frame.dart`, and everything in §3.2. | A takeover frame now falls through `isSessionFrameType` as an unknown type. |

`CHECKOUT_VARIABLE_MESSAGE_TYPES` and `kCheckoutVariableMessageTypes` lose
nothing, because none of these types is in them. Check anyway, and keep the two
lists identical.

### 1.2 Session hello (`session:hello`), native path

- Bridge `SessionHelloFrame` becomes `{ type: "session:hello", attemptId: string }`.
- `SessionHelloCapabilities` and the `capabilities` field are deleted
  (`protocol.ts` ~146-165).
- A hello that still carries `capabilities` parses. The key is stripped and
  ignored, not refused.
- Dart: `kSessionHelloCapabilities` is deleted (`connection_handshake.dart`
  ~26-38). The hello body is exactly `{'type': 'session:hello', 'attemptId': id}`.

### 1.3 Loopback hello (`hello`, `local-listener.ts`)

- Its `capabilities` object keeps one key, `sessionBusCarrier?: boolean`.
- `pullsTree`, `terminalFramesV1` and `checkoutRouting` are no longer read.
- An owner that sends no `capabilities` is a valid non-carrier owner.

### 1.4 Stream refusals

- `UPDATE_REQUIRED` is deleted from the refusal-code set in
  `packages/antgrid-wire/src/stream-open.ts` (~118-131), from Dart
  `StreamRefusalCode.updateRequired` (`models/stream_open.dart` ~440-442), and
  from `stream-dispatch.ts` (~117, ~192).
- Refusal unions typed `"UPDATE_REQUIRED" | "NOT_ALLOWED"` become
  `"NOT_ALLOWED"`:
  - `file-upload.ts:52`;
  - `tunnel-manager.ts:134`;
  - `project-streams.ts` ~479-483 (the mapping collapses to `NOT_ALLOWED`) and
    the ~564 comment.
- `control:result` for `project:start` no longer has an `UPDATE_REQUIRED`
  branch (`host-server.ts` ~1719-1731).
- **Not affected:** `UPGRADE_REQUIRED`, the `terminal:subscribe` version check
  in `terminal-frames/delivery.ts` ~287-297. See §7.

### 1.5 Stream kinds, open frames, admission order and caps: no change

The only change is §1.4. Keep:
- 256 KiB write slicing;
- the per-peer caps;
- hazard J (`stream-ready` before a project open, and `NOT_READY` in-band).

### 1.6 Vectors fixture

Run `bun run --filter antgrid-wire gen:peer-vectors` (bridge-src) after:
- dropping the `"update-required"` refusal sample (generator ~200-203);
- dropping `session:takeover` from `sessionRecords.types`.

It rewrites `evals/fixtures/peer-transport-vectors.json`. Commit the result
unedited. Both the TS and the Dart vector tests must pass against it.

### 1.7 Web HTTP

- `POST /account/devices`: `CreateDeviceBody` drops `x25519Pub`. The field was
  never stored.
  - Zod strips an extra key, so an eval fixture that still sends one keeps
    working.
- Deleted outright:
  - `GET /account/devices/me/peers`, with its `r.use` and handler
    (`web/src/routes/agents.ts` ~33-41 and ~65-80);
  - `listAppDevicePeers` and `listAppDeviceKeys` (`web/src/models/device.ts`
    ~145-164);
  - `inventoryEndpoints` and the `endpoint`/`transportCapabilities` spread at
    ~60, with its imports.
- `endpointInventory` stays in `peer-authorization.ts`, because the
  authorization snapshot uses it.

---

## 2. Bridge (bridge-src)

### 2.1 Enable-relay wizard

- Delete `bridge/src/relay-promotion.ts`.
- `project-core.ts`:
  - Drop the import (~5), the `ensureMachineRelay` dep (~51-54), the
    `promotion` field (~82), `attachLocalStreamForWizard` (~717-735) and
    `this.promotion?.stop()` (~779).
  - `startLocal`'s wrapper (~491-507) reduces to
    `await this.bindLoopback(core, bus)`.
  - Keep `promote()`, `attachRelayStream` and `demoteAllPromoted`. They are
    the phone's `project:start` path.
- `host-server.ts`:
  - Delete the imports (~24-25), the `wizardRemote` field (~638-641),
    `ensureMachineRelay` (~897-990, including its `process.env.RELAY_URL`
    read), and the `ensureMachineRelay:` dep (~2337).
  - `remoteConfig()` becomes `return this.opts.remote ?? null;`.
  - Fix the wizard comments at ~206 and ~2305-2335 so they state only what
    remains true.
- Fix the comments in `push/push-dispatcher.ts:32` and `entitlement.ts:46`.

### 2.2 Capability flags: bridge shapes after A11

```ts
// peer-session-owner.ts
export interface PeerSession { attemptId: string; peerId: string }        // + whatever non-capability fields exist today
onHandshakeComplete?: (peer: { peerId: string }) => void;
// deleted: anySessionSupportsCheckoutRouting()

// project-streams.ts
export interface PeerSessionView { readonly peerId: string; readonly peerPubkey: string }
```

- `peer-session-owner.ts`: delete the capability parsing and fields
  (~28-29, 57-64, 176-186, 196-203, 293-298, 375-380 and 485-502).
- `native-host-connection.ts:686` and `remote-host-connection.ts:7`: drop
  `anySessionSupportsCheckoutRouting`.
- `agent-core.ts`:
  - Delete `setEstablishedPeersProvider`, `setOwnerPullsTreeProvider`,
    `setPeerTerminalFramesV1Provider`, `setOwnerTerminalFramesV1Provider` and
    `clientSupportsTerminalFramesV1` from both the interface (~305-322) and the
    implementation (~978-1003, ~5119-5123). None has a caller in `src`.
  - Delete `peerCanRouteCheckouts` (~1049-1056) and its three gates:
    - tunnel admit (~1331-1333);
    - upload admit (~1358-1360);
    - inbound dispatch (~4925-4928).
  - Delete `everyClientPullsTrees` (~1299-1310) and the re-sync tree re-push it
    guarded (~3519-3538). **A re-sync never pushes `file:tree:full`.** Every
    client pulls it per checkout with `file:tree:snapshot:request`.
  - **Keep `setPeerSessionProvider` and `peerSessionProvider`.**
    `remoteFrameAllowed` and `peerBusReachAllowed` read whether it is wired, and
    `push:register` reads `peerPubkey`.
- `hasIsolatedSessions` is orphaned by the deletions above. Delete the chain:
  - `SessionManager.hasIsolatedSessions`;
  - `AgentCore.hasIsolatedSessions` (interface ~337-339, implementation
    ~5152);
  - `ProjectCore.hasIsolatedSessions` (~150);
  - `HostServer.projectRequiresCheckoutRouting` (~2697-2704).
  - Keep `isIsolatedCheckoutKind`: it has other callers.
- `host-server.ts`:
  - Delete `readvertiseForTest`'s `anySessionSupportsCheckoutRouting` stub
    (~728).
  - The advert computes `dialable = entry?.core.isRelayRegistered() ?? false`
    (~1001-1015 collapses).
  - Delete `project:start`'s asker-capability check (~1719-1731). The
    `seenProjects` lookup directly above it stays untouched.
- `local-listener.ts`:
  - Delete the `pullsTree`/`terminalFramesV1`/`checkoutRouting` socket data,
    `ownerPullsTree`, `ownerSupportsTerminalFramesV1` and
    `requireCheckoutRouting` (~9-16, 45, 70-111, 272-307).
  - Keep `sessionBusCarrier`, `ownerCarriesSessionBus` and `deliverToOwner`.
- `project-core.ts`:
  - Delete the `requireCheckoutRouting` call (~434) and the two provider wires
    (~473-474).
- Refusal unions: see §1.4. `stream-dispatch.ts` passes `NOT_ALLOWED` through
  unchanged.
- Fix the comments in `worktree-capability.ts:6` and
  `worktrees/checkout-types.ts:50`.
- `bridge/scripts/iroh-host-smoke.ts:73`: send the hello without
  `capabilities`.

### 2.3 Project stream authorization (security; exact shape)

In `project-core.ts` ~563-578, `attachRelayStream` passes:

```ts
mayDeliver: /* unchanged: the live remote-access switch */,
// no mayDeliverTo
mayAcceptFrom: (peer) => peer === null ? { code: "NOT_ALLOWED", message: "no session for this peer" } : null,
```

- `ProjectStreamRegistry` keeps its `mayDeliverTo` and `mayAcceptFrom`
  hooks, and keeps calling `mayDeliverTo` on every send and `mayAcceptFrom`
  at every open. Only this caller stops supplying `mayDeliverTo`.
- `bothOf` stays: `mayDeliverTo` remains optional.
- Everything else stays exactly as it is:
  - `remoteFrameAllowed` inbound;
  - `mayDeliver` outbound;
  - the `seenProjects` and `isSafeProjectId` lookups;
  - a stream open never opens or promotes a core.

### 2.4 Small items

- `message-bus.ts`: delete `publishExcept` (~167-176) and the `except` member
  of `emit`'s `audience` (~185, ~211). It has no other user.
- `peer-session-owner.ts`: delete the unused `onMessage`/`onDisconnected`
  options (~31-32, ~367). `payloadTransport` (~86) becomes the literal
  `"iroh"`.
- Delete `bridge/src/ed25519-der.ts` (§5.2 moves its one constant).
- `relay-slot.ts:8`: stop re-exporting `slotMachineDeviceId`.
  `packages/antgrid-wire/src/relay-slot.ts`:
  - delete `slotMachineDeviceId` (~38-42);
  - rewrite the file doc (~8-15), which names an E2E transcript, trusted-peers
    and `verifyTranscriptSig`, none of which exists.
- Stale "E2E"/"sealed" comments may be corrected **only in lines you already
  touch**. There is no sweep. (Superseded by the owner brief's item j: the
  integrator swept the named files; see §11.)

---

## 3. Dart and app (dart+app)

### 3.1 `MachineSession` establishment (`machine_session.dart`)

One `MachineSession` per `PeerLink`, and a failed hello closes the link, so a
session establishes at most once.

- Delete:
  - the `_SessionGeneration` class (~83-91);
  - `_generation` and `_epochCounter`;
  - the public `ready` future and its `_readyCompleter`;
  - the `established` stream (`_established$`);
  - the `_armEstablishedReady` re-arming (~494-500, ~523);
  - `_reopenAtEstablish` and its loop (~588-593, ~1591-1605).
- Keep **one** completer, `_firstEstablished`, completed once at establishment
  and never re-armed. `_attemptBind` (~1242) awaits it, because `openProject`
  can precede establishment.
- The send fences (~416-465, ~898-921) test the `_established` bool, not a
  generation.
- Establishment still calls the control transport's `refreshSnapshot`.
- The "pre-A4" comments (~1089, ~1467) state only the current behaviour.
- The `sessionDownEvents` doc (~251) drops its mention of takeover.

### 3.2 Takeover

Delete:
- `_takeovers`, `takeoverEvents` and the `session:takeover` case in
  `machine_session.dart` (~206, ~238-242, ~885-891, ~948);
- `PeerSessionTakenOver` and `noteSessionTakenOver` in
  `connection_supervisor.dart` (~38-39, ~179-180);
- the matching state in `supervisor_state.dart:12`;
- the matching code in `peer_connection.dart` (~105-106, ~329-331) and
  `relay_connection.dart` (~156-157);
- the takeover label in `ab_status_helpers.dart:72`;
- the take-back branch in `workspace_shell.dart` (~3282).

Fix the comments in `agent_transcript_view.dart:179` and `peer_link.dart:13`.

### 3.3 Hello and loopback

- `connection_handshake.dart`: delete `kSessionHelloCapabilities` and the
  `'capabilities'` key (~112).
- `LocalTransport` (`local_transport.dart`):
  - Replace the `Map capabilities` field and constructor parameter with
    `final bool sessionBusCarrier` (default `false`).
  - The hello includes `'capabilities': {'sessionBusCarrier': true}` only when
    it is true, and otherwise omits the key.
  - Drop the handshake import (~10).
- `local_agent_launcher.dart` (~315-329) constructs it with
  `sessionBusCarrier: true`.
- `models/stream_open.dart`: delete `updateRequired`.
- `upload_service.dart:168`: fix the comment.

### 3.4 Request plumbing (`agent_transport.dart`, `buffered_agent_transport.dart`)

- Delete `AgentTransport.action` (~171-178) and every implementation:
  - `buffered_agent_transport.dart` ~285-291;
  - `fake_agent_transport.dart` ~225-231 and ~315-322;
  - any other `implements AgentTransport`.
- Delete the retired classification helpers at `agent_transport.dart` ~23-43
  and ~72-86.
- `requestWithOutcome` keeps its signature. Its doc says every call is treated
  as a mutation. In `BufferedAgentTransport`:
  - `!isEstablished` gives `notSent`;
  - an `RpcException` that is an application refusal is rethrown exactly as
    today;
  - any other `RpcException` or a timeout after send gives `outcomeUnknown`.
- The `isEstablished`, `establishmentEpoch` and `hydrate` docs describe the
  current single-session model, with no "reconnect generation" or "E2E"
  wording. **Their behaviour is unchanged.**
- `project_session.dart` ~506-509: drop the `action` use.
- `control_plane_client.dart`:
  - Delete `deleteSession` (~704-739). It has no caller.
  - ~673 becomes `.timeout(const Duration(seconds: 15))`.
  - The pre-RPC catch at ~643 stays (it also catches timeouts). Reword its
    comment only.
- The `run()` wrapper callers inline `run().timeout(t)`:
  - `file_service.dart` ~1114, 1171, 1322, 1394, 1473;
  - `terminal_service.dart` ~2200, 2232;
  - `search_service.dart:115`, with no timeout.
- `local_transport.dart:373`: the catch stays; reword the comment.
- `reply_latch.dart:10`: fix the doc.
- `terminal_service.dart:439`: the comment names `terminal:output` only.

### 3.5 Devices API

- `DevicesApiCreator.createDevice` (`devices_api_contract.dart`,
  `devices_api.dart` ~77 and ~96) loses the `x25519Pub` parameter and body key.
  Its other parameters are unchanged.
- `device_provisioning.dart` ~80 and ~162: update the call sites.
- **`DeviceRecord.x25519Pub` stays** (§7).
- `app/lib/providers/remote_access.dart:94`: fix the comment.

### 3.6 Relay error banner

- `relay_error_banner.dart` stays: `workspace_shell.dart` ~873-919 sets its
  `SESSIONS` and `LICENSE` codes.
- Only its doc (~6) changes: it no longer mentions `agent:relayError`.

### 3.7 Slot comment

- `relay_slot.dart:13`: drop the `slotMachineDeviceId` mirror note.

---

## 4. Relay (bridge-src) and relay tests (bridge-tests)

`relay/src/server.ts`:
- Delete the retired-streams shim (~350-359), which answers `stream-open` and
  `stream-close` with `PROTOCOL_VIOLATION`. Such a frame now takes the ordinary
  unknown-control-type path.
- Delete the `PEER_MAX_RECORD_BYTES` import (~10).
- Add, near the other module constants:

```ts
// Largest legitimate control frame: push:deliver (pushToken ≤4096 + epk ≤256 + box ≤8192, ~12.7 KiB)
// or hello (licenseToken ≤8192 …, ~9.2 KiB); 64 KiB leaves ~5x headroom for JSON escaping.
const MAX_CONTROL_FRAME_BYTES = 64 * 1024;
```

  and use `maxPayloadLength: MAX_CONTROL_FRAME_BYTES` (~519).
- Before committing, verify the field bounds quoted in the comment against the
  control-envelope schemas in `packages/antgrid-wire`. If a bound differs,
  correct the comment. Change the constant only if a legal frame would exceed
  it.
- The control JSON rate limiter is untouched.

Relay tests (bridge-tests):
- Delete `relay/tests/streams.test.ts`.
- `hello-smoke.test.ts:41` sends `{type:"ping"}`.
- `routing.test.ts`:
  - the binary frame at ~24-25 becomes 1 KiB;
  - delete the metrics-retired test (~75-85).
- **Add:**
  - an over-bound text frame (`MAX_CONTROL_FRAME_BYTES + 1` bytes of JSON) makes
    the server drop the connection. Bun enforces `maxPayloadLength` without a
    close frame, so the client observes 1006, not 1009 (see §11);
  - a `push:deliver` at the schema maximum for every field is accepted.
- Docs: fix `relay/CLAUDE.md:13` and `relay/relay-requirements.md:42`
  (bridge-src).

---

## 5. Test seams and tests

### 5.1 Seams after A11

- `bridge/tests/test-peer-session-owner.ts`:
  - It builds `PeerSessionView = { peerId, peerPubkey }`.
  - Every capability argument or default is removed.
  - A helper that took a `checkoutRouting` flag loses it. Callers that passed
    `false` to provoke `UPDATE_REQUIRED` are deleted (§5.2).
- Dart fakes of `AgentTransport` lose `action`.
- Fakes of `DevicesApiCreator.createDevice` lose `x25519Pub`.
- The eval `LocalTestClient` (`evals/helpers/local-client.ts`):
  - It drops the `pullsTree` and `terminalFramesV1` options and their defaults.
  - It keeps a `capabilities` passthrough so a test can declare
    `sessionBusCarrier`.
  - The default hello sends no `capabilities`.
- `evals/helpers/relay-client.ts`: delete the `omit*` capability options and
  the `capabilities` hello key (~1379-1424). Delete the takeover case (~1322)
  and its comment (~1297).

### 5.2 bridge-tests

**Delete:**
- `bridge/tests/relay-promotion.test.ts`
- `bridge/tests/protocol-enable-relay.test.ts`
- `bridge/tests/agent-core-terminal-snapshot.test.ts`
- `bridge/tests/agent-core-terminal-snapshot-rpc.test.ts`
- `web/tests/routes/account-devices-peers.test.ts`
- `relay/tests/streams.test.ts`

**Change:**
- `remote-access-gate.test.ts`: delete the "promotion wires (and clears)" test
  (~306-374) and its import (~10).
- `host-server.test.ts`: delete the wizard heartbeat test (~445-485) and the
  `AgentEnableRelay` import.
- `netwatch-local.test.ts` (~312-338): switch the redaction case to
  `agent:question-resolve`, which is still in `BODY_REDACTED_MESSAGE_TYPES`,
  for both the well-formed and the malformed variant.
- `project-core.test.ts` (~374, ~436): fix the comments.
- `agent-core-checkout-routing.test.ts`:
  - delete the retired snapshot-request test (~377-402) and the
    `terminal.snapshot` RPC test (~404-437);
  - delete every `UPDATE_REQUIRED` or non-routing-peer case;
  - keep all `checkoutId` routing cases.
- `protocol.test.ts`:
  - delete the `terminal:snapshot` describe (~316-360);
  - keep ~460 (session frames);
  - delete the `dartHelloKeys` capability mirror (~614).
- `agent-core-resync-pushes.test.ts`:
  - replace ~97-150 with one assertion that a re-sync emits no
    `file:tree:full`;
  - keep ~237.
- `handshake-pull.test.ts:71` and `host-control-plane.test.ts:178`: hellos
  without `capabilities`.
- `local-listener.test.ts`:
  - delete the `pullsTree`/`terminalFramesV1`/`checkoutRouting` cases
    (~118-166, ~269);
  - keep and extend the `sessionBusCarrier` cases so both of these are
    asserted:
    - an owner without the key is not a carrier;
    - an owner with `sessionBusCarrier: true` is a carrier.
- `peer-session-hello.test.ts:129`: keep it. `session:established` from the
  app stays refused.
- Delete the `UPDATE_REQUIRED` cases in:
  - `project-streams.test.ts`;
  - `terminal-streams.test.ts`;
  - `tunnel-streams.test.ts`;
  - `upload-streams.test.ts`;
  - `worktree-remote-security.test.ts`.
- **Add** to `project-streams.test.ts`: a project-stream open for a peer the
  session provider does not know is refused `NOT_ALLOWED`. This is the §2.3
  fail-closed check.
- Anything asserting `hasIsolatedSessions`, `anySessionSupportsCheckoutRouting`
  or `peerCanRouteCheckouts` is deleted. That includes the test for the
  `session-manager` method, if one exists.
- `relay-slot.test.ts`: delete the `slotMachineDeviceId` tests.
- `relay-client-hello.test.ts`: inline
  `const ED25519_SPKI_PREFIX = Buffer.from("302a300506032b6570032100", "hex");`
  and drop the `ed25519-der` import.
- Any other bridge test that fails to compile because a deleted symbol is gone:
  fix it by deleting the dead assertion, never by restoring the symbol. The
  grep list in §9 names the likely ones.
- Wire tests:
  - `packages/antgrid-wire/tests/peer-protocol.test.ts` (~7, ~38-47): no
    takeover;
  - `stream-open.test.ts`: no `UPDATE_REQUIRED`;
  - `peer-transport-vectors.test.ts`: passes on the regenerated fixture.
- Web tests:
  - `devices-create.test.ts` and `devices-create-kind.test.ts`: replace
    `listAppDeviceKeys` with a direct `db.device.findMany`;
  - drop the `x25519Pub` fixture keys in `custom-claims`, `entitlement-flow`,
    `oauth-end-to-end`, `agents`, `devices-create*` and `devices-delete`.
  - Add one test: `POST /account/devices` without `x25519Pub` returns 201.

### 5.3 dart+app tests

- `machine_session_establish_test.dart`:
  - delete the takeover group (~169-240);
  - ~90 awaits establishment through a public observable that still exists
    (`sessionDownEvents` or the `isEstablished` poll), not `session.ready`.
- `machine_session_lifecycle_test.dart` (~141): delete the takeover case.
- `peer_connection_session_binding_test.dart:179`: use `sessionDownEvents`
  `onDone` in place of takeover.
- `workspace_blocking_error_test.dart:11` and `ab_status_helpers_test.dart:21`:
  delete the takeover label assertions.
- `hydrate_action_contract_test.dart` (~148-178) and
  `remote_request_outcome_test.dart` (~59-64, ~152): delete the `action`
  cases. Keep or adjust the `requestWithOutcome` cases to §3.4:
  - pre-establishment gives `notSent`;
  - a non-refusal `RpcException` gives `outcomeUnknown`.
- `control_plane_client_test.dart` (~447-500): delete the `deleteSession`
  tests.
- `local_transport_connect_test.dart` (~129-135): the hello carries no
  `capabilities` by default.
  - **Add:** `sessionBusCarrier: true` sends exactly
    `{'sessionBusCarrier': true}`.
- `connection_handshake_test.dart`: the hello equals
  `{'type': 'session:hello', 'attemptId': <id>}`.
- `peer_transport_vectors_test.dart` (~193-211): no `updateRequired`. Match
  the regenerated fixture's refusal list with `unorderedEquals`.
- `app/test/models/terminal_snapshot_parse_test.dart`: delete.
- `classification_completeness_test.dart` and
  `project_message_classification_test.dart` (~41, ~63, ~83): drop both
  snapshot types.
- `terminal_frame_mode_test.dart`:
  - delete the "terminal:snapshot is dropped once a terminal is in frame mode"
    test (~889);
  - delete the `terminal:snapshot:request` assertion (~723);
  - the `terminal.snapshot` "isEmpty" assertions may stay or go.
- `terminal_reattach_test.dart:98` and `terminal_attach_state_test.dart:193`:
  delete the snapshot-request assertions.
- `createDevice` fakes lose `x25519Pub`:
  - `connection_identity_test`;
  - `host_uuid_backfill_test`;
  - `post_signin_provisioning_test`;
  - `sign_out_reprovision_test`;
  - `controller_provisioning_test`;
  - `device_provisioning_test`;
  - `devices_api_device_cap_test`;
  - `devices_api_timeout_test`;
  - `provisioning_coordinator_test`;
  - `app/test/helpers/fake_device_store.dart`, if it implements the creator.
- `AgentTransport` fakes (`app/lib/test_helpers/fake_agent_transport.dart`,
  `app/test/helpers/test_peer_runtime.dart`, and any other implementer) lose
  `action`.

### 5.4 evals

**Delete:**
- `evals/tests/local-promotion.test.ts`
- `evals/helpers/restartable-relay.ts`
- `evals/helpers/tcp-forwarder.ts` (they import only each other)

**Change:**
- `evals/helpers/local-test-env.ts`: drop the `licenseToken` and `relayUrl`
  options, `promo`, `generateKeyPairSync` and `b64RawKey`. The other callers,
  `local-terminal.test.ts` and `multi-project-isolation.test.ts`, keep
  compiling.
- `evals/helpers/harness.ts`:
  - drop the `/account/devices/me/peers` mock route (~299, ~342, ~361-362);
    `accountDevices` stays, because `PeerAuthorizationFixture` reads it;
  - drop the capability options (~632-651);
  - the bootstrap `x25519Pub` (~258, ~279, ~512) stays.
- `evals/helpers/two-bridge.ts:161` and
  `evals/tests/gate-multi-machine-slots.test.ts:24`: drop the peers-route use.
- `gate-two-devices-one-bridge.test.ts` (~12, ~41-46, ~109-120): drop the
  takeover expectations. Two devices are two sessions.
- `gate-inventory-miss.test.ts:131` and
  `gate-iroh-host-authorization.test.ts:134`: hellos without `capabilities`.
- `gate-lazy-hydration.test.ts`: delete row 3 (~145-150).
- `gate-project-streams.test.ts`: delete ~116-147, the `UPDATE_REQUIRED` row.
- Fix the comments in `gate-worktree-isolation.test.ts:9` and
  `gate-terminal-frames.test.ts:3`.
- Any eval that relied on a re-sync `file:tree:full` push now pulls with
  `file:tree:snapshot:request`.
- `gate-session-bus.test.ts:153` keeps a non-carrier owner. That is now the
  default.
- `evals/support/iroh-authorization.ts:60`: dropping `x25519Pub` is optional
  (web strips it).
- `evals/helpers/dart-app-client.ts`: untouched. Its `x25519PublicKey` is
  device identity.

---

## 6. Docs and ledger

- **Root `CLAUDE.md`** (bridge-src):
  - delete the "App capabilities are hand-mirrored across the licence
    boundary" rule;
  - delete the sentence in the checkout-scoped routing rule about refusing an
    app that does not advertise `checkoutRouting`.
- **`docs/architecture.md`** (bridge-src): "Tree state flows pull-first"
  states that every client pulls, with no capability.
- **`docs/protocol/peer-session.md`** (bridge-src):
  - remove takeover (~335-358);
  - the hello has no `capabilities`;
  - no `UPDATE_REQUIRED` refusal.
- **`bridge/CLAUDE.md`** (bridge-src):
  - ~126 and the session-bus bullet on the `checkoutRouting` gate: remove the
    gate, and state that isolation now rests on the admission rules that remain;
  - remove the `stream-mux`/wizard wording where it describes deleted code.
- **`bridge/requirements.md`** (~287, ~437) (bridge-src): no
  `agent:disconnecting`.
- **`relay/CLAUDE.md` and `relay/relay-requirements.md`** (bridge-src): §4.
- **`web/CLAUDE.md:16` and `web/prisma/schema.prisma` ~116-118 (comment
  only)** (bridge-src): no peers inventory and no `x25519Pub` intake.
- **`packages/antgrid_relay_client/CLAUDE.md`** (dart+app):
  - drop `session:takeover` from the session-frame list;
  - drop the `_SessionGeneration` fence wording;
  - drop the `kSessionHelloCapabilities` sentence in the
    `connection_handshake.dart` bullet.
- **`app/CLAUDE.md`** (dart+app):
  - the `sessionBusCarrier` line (~27) stays;
  - fix any "Session hello, no app-layer crypto" text naming generations or
    capabilities.
- **`docs/iroh-reduction/ledger.md`** (evals writes the row skeleton; the
  integrator fills the numbers). Add:
  - an A11 status row;
  - gate evidence (§8);
  - the measured `A11 net = N` from the §0 command.

---

## 7. Kept because live (re-verified; do not delete)

| Item | Why it stays |
|---|---|
| `sessionBusCarrier` (loopback hello), `ownerCarriesSessionBus`, `deliverToOwner` | The desktop is the only session-bus carrier. A loopback owner is not identified as one without the flag, and the eval `LocalTestClient` plus `gate-session-bus.test.ts:153` rely on a non-carrier owner. |
| `endpointInventory` (`web/src/.../peer-authorization.ts`) | The authorization snapshot still uses it. Only `inventoryEndpoints` in `agents.ts` goes. |
| `relay_error_banner.dart` | `workspace_shell.dart` sets the `SESSIONS` and `LICENSE` banners. |
| `UPGRADE_REQUIRED` terminal version check (`terminal-frames/delivery.ts` ~287-297) | It validates a field every client sends, not a capability flag. |
| The `RpcException` catches in `local_transport.dart:373` and `control_plane_client.dart:643` | They also catch timeouts. Only the comments change. |
| `establishmentEpoch`, `hydrate`, and the app reconnect ladder | Still used by project sessions across supervisor redials. |
| `ProjectCore.promote`, `attachRelayStream`, `demoteAllPromoted` | The phone's `project:start` path, and the remote-access switch-off path. |
| `setPeerSessionProvider` / `peerSessionProvider` | `remoteFrameAllowed` and `peerBusReachAllowed` read whether it is wired, and `push:register` reads `peerPubkey`. |
| `establishedPeers()` on the remote connection | The push `resolveTargets` in `project-core.ts` uses it. |
| `ProjectStreamRegistry` `mayDeliverTo` / `mayAcceptFrom` hooks and `bothOf` | A security invariant: the hooks stay, and §2.3 fills `mayAcceptFrom`. |
| `DeviceRecord.x25519Pub`, bridge `auth/credentials.ts` x25519, `key-exchange.ts`, `push/seal.ts` | Push encryption. |
| `isIsolatedCheckoutKind` | Other callers in `session-manager.ts` and `host-server.ts`. |
| 256 KiB write slicing, the control JSON rate limiter, `LocalTransport`, `local-listener`, the loopback channel label (D2) | Out of scope by owner decision. |
| `HelloMessage.name`, `LICENSE_REQUIRED`, `PEER_SELECTION_MS`/`PEER_REFRESH_MS` | Not in this wave. |

---

## 8. Gates (integrator)

```bash
bun run --filter antgrid-wire test
bun run --filter antgrid-bridge test > .tmp/a11-bridge.log 2>&1; grep "(fail)" .tmp/a11-bridge.log
bun run --filter antgrid-relay test
bun run --filter antgrid-web test
cd packages/antgrid_relay_client && dart test
cd packages/antgrid_peer_transport && dart test
cd app && flutter test -j 2
bun run --filter antgrid-evals test:evals
bun run --filter antgrid-evals test:evals:dart-terminal
bun run --filter antgrid-bridge qualify:iroh-host      # exercises the capability-free hello (§2.2)
bun run --filter antgrid-bridge qualify:iroh-interop   # needs the prebuilt DLL from .tmp
flutter analyze      # once, alone, never concurrently
```

**Pre-existing red that is not A11's:**

- Six stale-runId bridge failures:
  - `index-hook-subcommand` (1);
  - `plugin/antigravity-post-title` (3);
  - `plugin/opencode-notify` (2).
- The `git-branches` stash pop and the `git-sync` tests can time out under
  load.

---

## 9. Hard rules for every part

- Edit only the files you own (§10). Everything else goes in
  `outOfScopeNeeds`.
- Never use `git stash`, `checkout`, `reset` or `restore`.
- Run Bun tests per workspace only. Never run a bare `bun test` at the root.
  Redirect full-suite output to a file and grep for `(fail)`.
- Comments are WHY-only: no narration of this wave, and no "was X, now Y" or
  "removed in A11".
- A removed message type leaves every layer of the "Adding a message type"
  list: schema, union, `KNOWN_TYPES`, export and `handleAbMessage` case, plus
  its Dart mirror.
- `packages/antgrid-wire` (Apache-2.0) receives deletions only. Nothing moves
  into it.
- Every security invariant stays as it is:
  - `remoteFrameAllowed` inbound and `mayDeliver` outbound;
  - `seenProjects` and `isSafeProjectId`;
  - `mayDeliverTo` on every send and `mayAcceptFrom` at open;
  - a stream open never opens or promotes a core.
- Owner decisions D1 to D7 and hazard J stand.

**Symbols to grep before finishing.** Outside `docs/iroh-reduction/` history,
each must return zero hits, or only hits in files §10 assigns to you:

- `relay-promotion`, `RelayPromotion`, `ensureMachineRelay`, `wizardRemote`,
  `attachLocalStreamForWizard`;
- `enableRelay`, `disableRelay`, `activationPending`, `relayReady`,
  `agent:relayError`, `AgentEnableRelay`;
- `agent:disconnecting`;
- `terminal:snapshot`, `terminal.snapshot`, `TerminalSnapshot`,
  `handleTerminalSnapshotRpc`;
- `session:takeover`, `SessionTakeoverFrame`, `kSessionTakeover`,
  `takeoverEvents`, `PeerSessionTakenOver`, `noteSessionTakenOver`;
- `_SessionGeneration`, `_epochCounter`, `_reopenAtEstablish`,
  `_armEstablishedReady`;
- `SessionHelloCapabilities`, `kSessionHelloCapabilities`, `checkoutRouting`,
  `pullsTree`, `terminalFramesV1`;
- `anySessionSupportsCheckoutRouting`, `peerCanRouteCheckouts`,
  `requireCheckoutRouting`, `projectRequiresCheckoutRouting`,
  `hasIsolatedSessions`, `everyClientPullsTrees`;
- `setEstablishedPeersProvider`, `setOwnerPullsTreeProvider`,
  `TerminalFramesV1Provider`, `clientSupportsTerminalFramesV1`;
- `UPDATE_REQUIRED`, `updateRequired`;
- `publishExcept`, `slotMachineDeviceId`, `ed25519-der`;
- `restartable-relay`, `tcp-forwarder`;
- `listAppDevicePeers`, `listAppDeviceKeys`, `inventoryEndpoints`,
  `devices/me/peers`;
- `deleteSession(` in `control_plane_client.dart`;
- `.action(` on an `AgentTransport`;
- `PEER_MAX_RECORD_BYTES` in `relay/src`.

`scripts/sym.ts:16` names `enableRelay` only as an example in a doc comment.
bridge-src changes the example word.

---

## 10. File ownership (disjoint; every touched file has exactly one owner)

Path rules first. The explicit rows below are the files known to be touched,
and the rules decide any file not listed.

| Path rule | Owner |
|---|---|
| `bridge/src/**`, `bridge/scripts/**`, `bridge/CLAUDE.md`, `bridge/requirements.md` | bridge-src |
| `relay/src/**`, `relay/CLAUDE.md`, `relay/relay-requirements.md` | bridge-src |
| `web/src/**`, `web/prisma/schema.prisma`, `web/CLAUDE.md` | bridge-src |
| `packages/antgrid-wire/src/**`, `packages/antgrid-wire/scripts/**`, `evals/fixtures/peer-transport-vectors.json` (regenerated only) | bridge-src |
| root `CLAUDE.md`, `docs/architecture.md`, `docs/protocol/peer-session.md`, `scripts/sym.ts` | bridge-src |
| `bridge/tests/**`, `relay/tests/**`, `web/tests/**`, `packages/antgrid-wire/tests/**` | bridge-tests |
| every `*.dart` file, `packages/antgrid_relay_client/CLAUDE.md`, `app/CLAUDE.md` | dart+app |
| `evals/**` except the fixture above, and the Bun side of the eval client | evals |
| `docs/iroh-reduction/ledger.md` | evals (skeleton), integrator (numbers) |

| File | Owner |
|---|---|
| `bridge/src/relay-promotion.ts` (delete) | bridge-src |
| `bridge/src/ed25519-der.ts` (delete) | bridge-src |
| `bridge/src/protocol.ts` | bridge-src |
| `bridge/src/agent-core.ts` | bridge-src |
| `bridge/src/project-core.ts` | bridge-src |
| `bridge/src/host-server.ts` | bridge-src |
| `bridge/src/local-listener.ts` | bridge-src |
| `bridge/src/message-bus.ts` | bridge-src |
| `bridge/src/peer-session-owner.ts` | bridge-src |
| `bridge/src/peer/native-host-connection.ts` | bridge-src |
| `bridge/src/remote-host-connection.ts` | bridge-src |
| `bridge/src/project-streams.ts` | bridge-src |
| `bridge/src/peer/stream-dispatch.ts` | bridge-src |
| `bridge/src/file-upload.ts` | bridge-src |
| `bridge/src/tunnel-manager.ts` | bridge-src |
| `bridge/src/session-manager.ts` | bridge-src |
| `bridge/src/relay-slot.ts` | bridge-src |
| `bridge/src/push/push-dispatcher.ts` (comment) | bridge-src |
| `bridge/src/entitlement.ts` (comment) | bridge-src |
| `bridge/src/worktree-capability.ts` (comment) | bridge-src |
| `bridge/src/worktrees/checkout-types.ts` (comment) | bridge-src |
| `bridge/scripts/iroh-host-smoke.ts` | bridge-src |
| `bridge/CLAUDE.md`, `bridge/requirements.md` | bridge-src |
| `relay/src/server.ts` | bridge-src |
| `relay/CLAUDE.md`, `relay/relay-requirements.md` | bridge-src |
| `web/src/routes/agents.ts` | bridge-src |
| `web/src/routes/devices.ts` | bridge-src |
| `web/src/models/device.ts` | bridge-src |
| `web/prisma/schema.prisma` (comment only; no migration) | bridge-src |
| `web/CLAUDE.md` | bridge-src |
| `packages/antgrid-wire/src/peer-protocol.ts` | bridge-src |
| `packages/antgrid-wire/src/stream-open.ts` | bridge-src |
| `packages/antgrid-wire/src/relay-slot.ts` | bridge-src |
| `packages/antgrid-wire/scripts/gen-peer-transport-vectors.ts` | bridge-src |
| `evals/fixtures/peer-transport-vectors.json` (regenerated) | bridge-src |
| `CLAUDE.md` (root), `docs/architecture.md`, `docs/protocol/peer-session.md`, `scripts/sym.ts` | bridge-src |
| `bridge/tests/relay-promotion.test.ts` (delete) | bridge-tests |
| `bridge/tests/protocol-enable-relay.test.ts` (delete) | bridge-tests |
| `bridge/tests/agent-core-terminal-snapshot.test.ts` (delete) | bridge-tests |
| `bridge/tests/agent-core-terminal-snapshot-rpc.test.ts` (delete) | bridge-tests |
| `bridge/tests/remote-access-gate.test.ts` | bridge-tests |
| `bridge/tests/host-server.test.ts` | bridge-tests |
| `bridge/tests/netwatch-local.test.ts` | bridge-tests |
| `bridge/tests/project-core.test.ts` | bridge-tests |
| `bridge/tests/agent-core-checkout-routing.test.ts` | bridge-tests |
| `bridge/tests/agent-core-resync-pushes.test.ts` | bridge-tests |
| `bridge/tests/protocol.test.ts` | bridge-tests |
| `bridge/tests/handshake-pull.test.ts` | bridge-tests |
| `bridge/tests/host-control-plane.test.ts` | bridge-tests |
| `bridge/tests/local-listener.test.ts` | bridge-tests |
| `bridge/tests/peer-session-hello.test.ts` (verify only) | bridge-tests |
| `bridge/tests/project-streams.test.ts` | bridge-tests |
| `bridge/tests/terminal-streams.test.ts` | bridge-tests |
| `bridge/tests/tunnel-streams.test.ts` | bridge-tests |
| `bridge/tests/upload-streams.test.ts` | bridge-tests |
| `bridge/tests/worktree-remote-security.test.ts` | bridge-tests |
| `bridge/tests/relay-slot.test.ts` | bridge-tests |
| `bridge/tests/relay-client-hello.test.ts` | bridge-tests |
| `bridge/tests/test-peer-session-owner.ts`, `bridge/tests/fake-session.ts` | bridge-tests |
| any other `bridge/tests/**` hit from the §9 grep (`control-plane-start`, `control-plane-sessions-list`, `host-promotion`, `agent-reach-gate`, `checkout-mirror-contract`, `terminal-frame-*`, `terminal-owner-lifetime`, `push/push-multi-device-targeting`, `agent-core-transcript-snapshot`, …) | bridge-tests |
| `relay/tests/streams.test.ts` (delete), `relay/tests/hello-smoke.test.ts`, `relay/tests/routing.test.ts`, the new relay frame-bound tests | bridge-tests |
| `web/tests/routes/account-devices-peers.test.ts` (delete) | bridge-tests |
| `web/tests/routes/devices-create.test.ts`, `devices-create-kind.test.ts`, `devices-delete.test.ts`, `agents.test.ts`, `web/tests/auth/custom-claims.test.ts`, `web/tests/billing/entitlement-flow.test.ts`, `web/tests/integration/oauth-end-to-end.test.ts` | bridge-tests |
| `packages/antgrid-wire/tests/peer-protocol.test.ts`, `stream-open.test.ts`, `peer-transport-vectors.test.ts` | bridge-tests |
| `packages/antgrid_relay_client/lib/src/machine_session.dart` | dart+app |
| `packages/antgrid_relay_client/lib/src/connection_handshake.dart` | dart+app |
| `packages/antgrid_relay_client/lib/src/local_transport.dart` | dart+app |
| `packages/antgrid_relay_client/lib/src/frame.dart` | dart+app |
| `packages/antgrid_relay_client/lib/src/agent_transport.dart` | dart+app |
| `packages/antgrid_relay_client/lib/src/buffered_agent_transport.dart` | dart+app |
| `packages/antgrid_relay_client/lib/src/models/stream_open.dart` | dart+app |
| `packages/antgrid_relay_client/lib/src/peer_link.dart` (comment) | dart+app |
| `packages/antgrid_relay_client/lib/src/relay_slot.dart` (comment) | dart+app |
| `packages/antgrid_relay_client/lib/antgrid_relay_client.dart` (exports, if a deleted symbol is exported) | dart+app |
| `packages/antgrid_relay_client/CLAUDE.md` | dart+app |
| `packages/antgrid_relay_client/test/**` (`machine_session_establish_test`, `machine_session_lifecycle_test`, `connection_handshake_test`, `local_transport_connect_test`, `hydrate_action_contract_test`, …) | dart+app |
| `packages/antgrid_peer_transport/test/peer_transport_vectors_test.dart` (and any other `packages/antgrid_peer_transport/**` hit) | dart+app |
| `packages/antgrid_eval_client/**` Dart files (only if a deleted symbol is used) | dart+app |
| `app/lib/providers/agent_transport.dart` | dart+app |
| `app/lib/providers/relay_error_banner.dart` (doc) | dart+app |
| `app/lib/providers/relay_connection.dart` | dart+app |
| `app/lib/providers/remote_access.dart` (comment) | dart+app |
| `app/lib/connection/connection_supervisor.dart`, `supervisor_state.dart`, `peer_connection.dart` | dart+app |
| `app/lib/widgets/ab_status_helpers.dart`, `app/lib/widgets/agent_transcript_view.dart` | dart+app |
| `app/lib/screens/workspace_shell.dart` | dart+app |
| `app/lib/launcher/local_agent_launcher.dart` | dart+app |
| `app/lib/models/ab_message.dart` | dart+app |
| `app/lib/project/project_message_classification.dart`, `app/lib/project/project_session.dart` | dart+app |
| `app/lib/services/control_plane_client.dart`, `file_service.dart`, `terminal_service.dart`, `search_service.dart`, `reply_latch.dart`, `upload_service.dart` | dart+app |
| `app/lib/services/devices_api_contract.dart`, `devices_api.dart`, `device_provisioning.dart` | dart+app |
| `app/lib/test_helpers/fake_agent_transport.dart` | dart+app |
| `app/CLAUDE.md` | dart+app |
| `app/test/**` (every file named in §5.3, `app/test/models/terminal_snapshot_parse_test.dart` (delete), `app/test/helpers/**`, …) | dart+app |
| `evals/tests/local-promotion.test.ts` (delete) | evals |
| `evals/helpers/restartable-relay.ts`, `evals/helpers/tcp-forwarder.ts` (delete) | evals |
| `evals/helpers/local-test-env.ts`, `local-client.ts`, `relay-client.ts`, `harness.ts`, `two-bridge.ts` | evals |
| `evals/tests/gate-two-devices-one-bridge.test.ts`, `gate-inventory-miss.test.ts`, `gate-iroh-host-authorization.test.ts`, `gate-lazy-hydration.test.ts`, `gate-project-streams.test.ts`, `gate-multi-machine-slots.test.ts`, `gate-worktree-isolation.test.ts`, `gate-terminal-frames.test.ts` | evals |
| `evals/support/iroh-authorization.ts` (optional) | evals |
| `docs/iroh-reduction/ledger.md` | evals (skeleton), integrator (numbers) |

**Not touched, even though a grep hits them:**

- `evals/helpers/dart-app-client.ts` and
  `packages/antgrid_eval_client/lib/src/commands.dart`: `x25519PublicKey`
  there is device identity.
- `app/lib/services/agent_keys.dart`, `keychain_device_store.dart` and
  `connection_identity.dart`: they hold x25519 for push.
- `bridge/src/auth/credentials.ts`: bootstrap x25519.
- `app/lib/widgets/ab_banner.dart`: it reads the banner that stays.

---

## 11. As built (integrator reconciliation)

### Measured net

`A11 net = -1,225` (283 added, 1,508 removed), measured with the §0 command
against the working tree at base `a3fd8f72` (nothing committed yet), after the
integrator's own edits. Target ≤ -1,000: met.

### Deviations from §1 to §6

- **§4 relay frame bound.** The over-bound test asserts close code 1006, not
  1009: Bun/uWebSockets enforces `maxPayloadLength` by dropping the connection
  without a close frame. `relay/CLAUDE.md` and `relay/relay-requirements.md`
  say so. The comment's field bounds were checked against
  `packages/antgrid-wire` (`push-protocol.ts`: pushToken 4096, epk 256, box
  8192; `relay-protocol.ts`: licenseToken 8192) and match; the constant stays
  64 KiB.
- **§2.4 `payloadTransport`.** Inlined as the literal `"iroh"` at every call
  site and the method deleted (the brief asks for deletion, not a
  literal-returning method).
- **§2.4 stale comments.** The owner brief's item j wins over "there is no
  sweep": the integrator rewrote the stale E2E, sealed, rekey, credit-window
  and wizard wording in `device.ts`, `host-server.ts`, `project-core.ts`,
  `project-streams.ts`, `local-listener.ts`, `netwatch.ts`, `paired-phones.ts`,
  `tunnel-manager.ts`, `cli/netwatch.ts`, `protocol.ts` (including the
  `createTranscriptReplay` doc), `bridge/CLAUDE.md`, `bridge/requirements.md`,
  `docs/architecture.md` and `docs/protocol/peer-session.md`.
- **`docs/architecture.md` "Tree state flows pull-first"** keeps the reason
  the bridge must not push trees (the reconnect flood), stated without a
  capability.
- **§2.2 `PeerSessionOwnerOptions.onMessage`.** `bridge/tests/netwatch-remote.test.ts`
  passed `onMessage` to observe "never forwarded"; it now spies on the bus,
  which is the only place a forwarded frame can land.
- **§5.3 `machine_session_lifecycle_test.dart` G1.** Without takeover, a
  session can only be torn down by the link closing, which also makes
  `isDispatchAllowed` false and so could not isolate the established fence.
  The test now closes the link after the first write is in flight, reports it
  ready again, and asserts the queued second write is still dropped.
- **§5.3 `terminal.snapshot` RPC absence assertions** in
  `terminal_frame_mode_test.dart`, `terminal_attach_state_test.dart` and
  `terminal_reattach_test.dart`, and the `terminal:snapshot` never-received
  checks in `evals/tests/gate-terminal-frames.test.ts`, are kept. They assert
  the app never issues or receives the retired path; they cost nothing and
  still fail if it comes back.
- **`sessionBusCarrier` kept** (§7): the app's `LocalAgentLauncher` sends it
  true, but the eval `LocalTestClient` and `gate-session-bus.test.ts` open
  loopback owners that are deliberately not carriers, and nothing else tells
  the listener which owner carries the session bus.
- **`agent:relayError` deleted, banner kept**: the only emitter was
  `relay-promotion.ts`; `relay_error_banner.dart` is still set by
  `workspace_shell.dart` (`SESSIONS`, `LICENSE`).
- **App `x25519Pub`**: `createDevice` no longer sends it. `DeviceRecord.x25519Pub`
  and the local launcher's machine-auth JSON still carry it, because push
  sealing reads it.
- **`packages/antgrid-agents/src/payloads.ts`** still justifies
  `AgentTranscriptReplayMessage` with the retired relay rate limit. It is
  outside this wave's ownership and left unchanged.

### Tests deleted

- bridge: 4971 → 4921 total (-50), every one for deleted code:
  `relay-promotion.test.ts` (11), `protocol-enable-relay.test.ts` (5),
  `agent-core-terminal-snapshot.test.ts` (1) and
  `agent-core-terminal-snapshot-rpc.test.ts` (2) deleted whole;
  `local-listener.test.ts` -9 (`ownerPullsTree`,
  `ownerSupportsTerminalFramesV1`, the `checkoutRouting` close);
  `protocol.test.ts` -7 (`terminal:snapshot` schemas, the Dart capability
  mirror); `handshake-pull.test.ts` -6 (per-session `pullsTree` and
  `terminalFramesV1`, one replaced by an `onHandshakeComplete` peer-id test);
  `agent-core-resync-pushes.test.ts` -3 (the `tree:full` re-push, replaced by
  one no-push assertion); `agent-core-checkout-routing.test.ts` -2 (snapshot
  request and RPC); `host-server.test.ts`, `remote-access-gate.test.ts` and
  `worktree-remote-security.test.ts` -1 each (wizard heartbeat, promotion
  wiring, `UPDATE_REQUIRED` refusal); plus the `UPDATE_REQUIRED` rows of the
  stream tests.
- relay: 173 → 172 (`streams.test.ts` and the retired-metrics test deleted;
  the frame-bound and `push:deliver`-maximum tests added).
- relay_client: 273 → 266 (takeover group, `action` tier-2 group, capability
  hello cases).
- app: 4200 → 4189 (`terminal_snapshot_parse_test.dart`, `deleteSession`,
  `classifyRemoteRequest`, takeover labels, `terminal:snapshot` frame-mode
  case).
- web: `account-devices-peers.test.ts` deleted; one test added for
  `POST /account/devices` without `x25519Pub`.
