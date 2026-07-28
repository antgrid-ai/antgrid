// Mirror of `packages/antgrid_relay_client/test/relay_slot_test.dart`. The two
// implementations are hand-written copies, so a silent divergence here is an
// admission failure: the bridge would look the phone up under an id no store
// holds. Keep the cases in lockstep.
import { test, expect } from "bun:test";
import { baseSlotDeviceId, slotMachineDeviceId } from "../src/relay-slot";

test("a slot resolves back to the account device identity is keyed by", () => {
  expect(baseSlotDeviceId("device-1#machine-a")).toBe("device-1");
  expect(slotMachineDeviceId("device-1#machine-a")).toBe("machine-a");
});

test("an unscoped id passes through unchanged and claims no machine", () => {
  // Every pre-slot client sends one, and `isForeignSlot` must not reject it.
  expect(baseSlotDeviceId("device-1")).toBe("device-1");
  expect(slotMachineDeviceId("device-1")).toBeNull();
});

test("a machine id containing the separator does not corrupt the base", () => {
  // First separator wins, matching the Dart side; anything after it is scope.
  expect(baseSlotDeviceId("device-1#machine-a#extra")).toBe("device-1");
  expect(slotMachineDeviceId("device-1#machine-a#extra")).toBe("machine-a#extra");
});
