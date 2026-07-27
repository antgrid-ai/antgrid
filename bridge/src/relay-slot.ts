/**
 * Relay slot ids — `antgrid-wire/src/relay-slot.ts` holds the contract.
 *
 * Re-exported rather than defined here because the relay needs the same strip
 * (revocation is per ACCOUNT device, but an app's live sockets are keyed by
 * slot), and the separator must not exist in two TS copies.
 */
export { baseSlotDeviceId, slotMachineDeviceId, isSlotOf } from "antgrid-wire";
