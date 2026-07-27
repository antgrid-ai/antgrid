import { describe, it, expect } from "bun:test";
import { HelloMessage, RouteHeader } from "../src/index";

// An agent's device id is its bare machine `deviceUuid`; an app's is a
// per-machine relay slot, `<accountDeviceUuid>#<machineDeviceUuid>` (see
// relay-slot.ts). Both shapes must parse — and so must a route header's `to`,
// since that is how an agent addresses the slot back. The compound
// `deviceUuid.projectId` registration is gone, but '.' remains legal.
const fakePubKey = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
const b64 = (n: number) => Buffer.from(new Uint8Array(n)).toString("base64");

const baseHello = {
  type: "hello",
  protocolVersion: 3,
  deviceType: "agent" as const,
  name: "agent",
  publicKey: fakePubKey,
  epoch: 0,
  licenseToken: "test-license-token",
  ts: "2026-06-08T12:36:33.442Z",
  nonce: b64(24),
  sig: b64(64),
};

describe("v3 device id validation", () => {
  // The app cannot dial at all if this rejects: every one of its sockets
  // presents a slot, and a schema failure is PROTOCOL_VIOLATION before the
  // signature is even looked at.
  it("HelloMessage accepts an app's per-machine relay slot", () => {
    const slot = "11111111-2222-3333-4444-555555555555#66666666-7777-8888-9999-000000000000";
    const result = HelloMessage.safeParse({ ...baseHello, deviceType: "app", deviceId: slot });
    expect(result.success).toBe(true);
    if (result.success) {
      expect(result.data.deviceId).toBe(slot);
    }
  });

  it("HelloMessage accepts a bare deviceId with '.'", () => {
    const result = HelloMessage.safeParse({ ...baseHello, deviceId: "M.p1" });
    expect(result.success).toBe(true);
    if (result.success) {
      expect(result.data.deviceId).toBe("M.p1");
    }
  });

  it("HelloMessage still rejects deviceId with a space (negative sanity)", () => {
    const result = HelloMessage.safeParse({ ...baseHello, deviceId: "bad id" });
    expect(result.success).toBe(false);
  });

  // Two UUIDs plus the separator is 73 chars; the cap is what keeps an
  // unbounded id out of the connection table's keys.
  it("HelloMessage rejects a deviceId past the 128-char cap", () => {
    const result = HelloMessage.safeParse({ ...baseHello, deviceId: "a".repeat(129) });
    expect(result.success).toBe(false);
  });

  it("RouteHeader accepts a slot as 'to' — it is how the agent replies", () => {
    const result = RouteHeader.safeParse({
      type: "message",
      to: "phone-1#machine-1",
      channel: "control",
    });
    expect(result.success).toBe(true);
  });

  it("RouteHeader accepts a bare 'to' device id", () => {
    const result = RouteHeader.safeParse({
      type: "message",
      to: "phone-1",
      channel: "control",
    });
    expect(result.success).toBe(true);
  });
});
