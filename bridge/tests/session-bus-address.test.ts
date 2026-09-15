// bridge/tests/session-bus-address.test.ts
import { test, expect } from "bun:test";
import { addressKey, sameAddress } from "../src/session-bus/address";
import type { SessionMemberKey } from "../src/protocol";

const A: SessionMemberKey = { machineId: "m1", projectId: "p1", sessionId: "s1" };

test("identity is machine + project + session, and labels never fold in", () => {
  expect(sameAddress(A, { ...A })).toBe(true);
  expect(sameAddress(A, { ...A, machineLabel: "Renamed" } as SessionMemberKey)).toBe(true);
  expect(sameAddress(A, { ...A, sessionId: "s2" })).toBe(false);
  expect(sameAddress(A, { ...A, projectId: "p2" })).toBe(false);
  expect(sameAddress(A, { ...A, machineId: "m2" })).toBe(false);
});

test("addressKey agrees with sameAddress on every pair", () => {
  const others: SessionMemberKey[] = [
    { ...A },
    { ...A, sessionId: "s2" },
    { ...A, projectId: "p2" },
    { ...A, machineId: "m2" },
  ];
  for (const b of others) {
    expect(addressKey(A) === addressKey(b)).toBe(sameAddress(A, b));
  }
});
