import { describe, expect, test } from "bun:test";
import { mayRoute } from "../src/authz";
import type { Connection } from "../src/connections";

function conn(uid: string | undefined, deviceType: "agent" | "app"): Connection {
  return {
    connectionId: crypto.randomUUID(),
    deviceId: crypto.randomUUID(),
    deviceType,
    name: "t",
    publicKey: "pk",
    epoch: 1,
    helloNonce: crypto.randomUUID(),
    ws: { readyState: 1 } as Connection["ws"],
    ip: "127.0.0.1",
    connectedAt: Date.now(),
    lastSeen: Date.now(),
    claims: uid === undefined ? undefined : { uid },
    openStreams: new Set(),
  };
}

describe("mayRoute", () => {
  test("same uid routes", () => {
    expect(mayRoute(conn("u1", "app"), conn("u1", "agent"))).toBe(true);
  });
  test("different uid denied", () => {
    expect(mayRoute(conn("u1", "app"), conn("u2", "agent"))).toBe(false);
  });
  test("missing uid on either side denied (never undefined === undefined)", () => {
    expect(mayRoute(conn(undefined, "app"), conn(undefined, "agent"))).toBe(false);
    expect(mayRoute(conn("u1", "app"), conn(undefined, "agent"))).toBe(false);
  });
});
