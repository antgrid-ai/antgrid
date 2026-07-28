/// The app's relay slot id: the `hello.deviceId` one app socket presents.
///
/// The relay arbitrates per `hello.deviceId` and rejects an epoch that is lower
/// OR EQUAL with `SUPERSEDED`, so every socket the app holds at once needs its
/// own slot. Scoping by the machine each socket serves gives exactly that: one
/// slot per (app device, machine) pair, and the app's own sockets never
/// arbitrate against each other.
///
/// The scope is the AGENT's deviceUuid, so a bridge receiving a slot can tell
/// whether it was addressed at itself — see the presence guard in
/// `bridge/src/relay-client.ts`.
///
/// This is only ever a TRANSPORT address. The E2E transcript binds the bare
/// account `deviceUuid` on both sides, so the account identity a handshake
/// proves is unaffected by how the socket is addressed.
///
/// The relay's `DEVICE_ID` schema (`packages/antgrid-wire/src/relay-protocol.ts`)
/// must admit the separator, in `hello.deviceId` AND in a route header's `to` —
/// a schema miss is `PROTOCOL_VIOLATION` before the signature is looked at.
///
/// Mirrored by `packages/antgrid-wire/src/relay-slot.ts` (the one TS copy, used
/// by both bridge and relay) — keep the two in lockstep.
String relaySlotId(String deviceUuid, String machineDeviceId) =>
    '$deviceUuid$kRelaySlotSeparator$machineDeviceId';

/// Reduce a relay slot id to the bare account `deviceUuid` that identity
/// lookups and the E2E transcript are keyed by. Returns the input unchanged
/// when it carries no scope.
String baseSlotDeviceId(String slotId) {
  final i = slotId.indexOf(kRelaySlotSeparator);
  return i < 0 ? slotId : slotId.substring(0, i);
}

/// `#`, not `.`: a dot is the retired compound `<deviceUuid>.<projectId>` form,
/// and reusing it would make a slot indistinguishable from one of those.
const String kRelaySlotSeparator = '#';
