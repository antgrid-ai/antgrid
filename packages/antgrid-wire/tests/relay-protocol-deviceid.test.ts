import { describe, it, expect } from "bun:test";
import { HelloMessage, RouteHeader } from "../src/index";

// v3 device ids are bare machine/phone ids — no '#' fan-out sub-ids and no
// compound `deviceUuid.projectId` registrations, though '.' remains legal.
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
  it("HelloMessage rejects deviceId with '#' (sub-deviceId fan-out is gone)", () => {
    const result = HelloMessage.safeParse({ ...baseHello, deviceId: "M#M.p1" });
    expect(result.success).toBe(false);
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

  it("RouteHeader rejects 'to' with '#'", () => {
    const result = RouteHeader.safeParse({
      type: "message",
      to: "phone#M.p1",
      channel: "control",
    });
    expect(result.success).toBe(false);
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
