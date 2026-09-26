/**
 * The app's relay slot id: the `hello.deviceId` one app socket presents,
 * `<accountDeviceUuid>#<machineDeviceUuid>`.
 *
 * The relay arbitrates per `hello.deviceId` and supersedes an equal epoch, so
 * an app holding several machines open at once needs one slot per machine.
 * A slot identifies the app's machine-scoped control connection and native
 * route. Everything keyed by the ACCOUNT device — the bridge's
 * `paired-phones.ts` lookups and central revocation lookup — goes through
 * `baseSlotDeviceId` first.
 *
 * Stripping the scope cannot admit anyone: the native payload path
 * authorizes by endpoint ID from the authorization snapshot
 * (`acceptPeer`, `bridge/src/peer/native-host-connection.ts`), which a
 * stripped or forged slot never resolves to.
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

/** True when `routeId` is a slot scoped under account device `deviceId`.
 *  False for `deviceId` itself — callers that want both check equality too. */
export function isSlotOf(routeId: string, deviceId: string): boolean {
  return routeId.startsWith(deviceId + SLOT_SEPARATOR);
}
