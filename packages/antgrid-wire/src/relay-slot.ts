/**
 * The app's relay slot id: the `hello.deviceId` one app socket presents,
 * `<accountDeviceUuid>#<machineDeviceUuid>`.
 *
 * The relay arbitrates per `hello.deviceId` and supersedes an equal epoch, so
 * an app holding several machines open at once needs one slot per machine.
 * A slot is a TRANSPORT address: it is what frames are routed to, and nothing
 * else. Everything keyed by the ACCOUNT device — the E2E transcript, the
 * bridge's trusted-peers/paired-phones lookups, the relay's revocation
 * lookup — goes through `baseSlotDeviceId` first.
 *
 * Stripping the scope cannot admit anyone: on the bridge every identity the
 * base id resolves to is still gated by `verifyTranscriptSig`, so a client
 * claiming `<victim>#x` is handed the victim's pubkey and then fails the
 * signature.
 *
 * Hand-mirrored by `packages/antgrid_relay_client/lib/src/relay_slot.dart`
 * (which also mints slots — only the app ever does) — keep the two in
 * lockstep. A divergence is an admission failure, not a type error.
 */
const SLOT_SEPARATOR = "#";

/** Build the app's relay slot id for one (account device, machine) pair. The
 *  one TS copy of the separator — mirrored by
 *  `packages/antgrid_relay_client/lib/src/relay_slot.dart`'s `relaySlotId`,
 *  which also mints slots (only the app ever does). Keep the two in lockstep. */
export function relaySlotId(deviceUuid: string, machineDeviceId: string): string {
  return `${deviceUuid}${SLOT_SEPARATOR}${machineDeviceId}`;
}

/** The bare account `deviceUuid` behind a route id. Unscoped ids pass through,
 *  so a client that dials without a slot keeps working. */
export function baseSlotDeviceId(routeId: string): string {
  const i = routeId.indexOf(SLOT_SEPARATOR);
  return i < 0 ? routeId : routeId.slice(0, i);
}

/** The machine a route id is scoped at, or null when it carries no scope. */
export function slotMachineDeviceId(routeId: string): string | null {
  const i = routeId.indexOf(SLOT_SEPARATOR);
  return i < 0 ? null : routeId.slice(i + SLOT_SEPARATOR.length);
}

/** True when `routeId` is a slot scoped under account device `deviceId`.
 *  False for `deviceId` itself — callers that want both check equality too. */
export function isSlotOf(routeId: string, deviceId: string): boolean {
  return routeId.startsWith(deviceId + SLOT_SEPARATOR);
}
