import { expect, test } from "bun:test";
import { AdmissionRegistry } from "../src/peer/admission-registry";

test("anonymous admissions stay bounded and release exactly once", () => {
  const registry = new AdmissionRegistry(2);
  const first = registry.reserve()!;
  const second = registry.reserve()!;
  expect(registry.reserve()).toBeNull();
  expect(registry.size).toBe(2);

  first.release();
  first.release();
  expect(registry.size).toBe(1);
  expect(registry.reserve()).not.toBeNull();
});

test("retirement fences completions without freeing unresolved ownership", () => {
  const registry = new AdmissionRegistry(1);
  const reservation = registry.reserve()!;
  registry.retireGeneration();

  expect(reservation.current).toBe(false);
  expect(registry.size).toBe(1);
  expect(registry.reserve()).toBeNull();

  reservation.release();
  expect(registry.reserve()?.current).toBe(true);
});
