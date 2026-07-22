import { describe, test, expect } from "bun:test";
import { listUserSessions } from "../../src/services/sessions.js";
import type { ConnectionSummary } from "../../src/relay/push.js";
import type { DeviceRow } from "../../src/models/device.js";

const RELAY = { baseUrl: "http://relay.local", secret: "s" };
const USER = "user-1";

// Minimal DeviceRow stand-ins — listUserSessions only reads deviceId + displayName.
function device(deviceId: string, displayName: string): DeviceRow {
  return { deviceId, displayName } as DeviceRow;
}

function conn(partial: Partial<ConnectionSummary>): ConnectionSummary {
  return {
    deviceId: "x",
    deviceType: "agent",
    state: "PAIRED",
    connectedAt: 1000,
    lastSeen: 2000,
    ...partial,
  };
}

// fetchImpl returning a fixed (already user-scoped) connection list, as the relay would.
function relayReturning(connections: ConnectionSummary[]): typeof fetch {
  return (async () =>
    new Response(JSON.stringify({ connections }), {
      headers: { "content-type": "application/json" },
    })) as unknown as typeof fetch;
}

describe("listUserSessions", () => {
  test("maps a compound agent and joins the device display name", async () => {
    const devices = [device("uuid-a", "My Mac")];
    const fetchImpl = relayReturning([conn({ deviceId: "uuid-a.proj1", connectedAt: 1234 })]);
    const out = await listUserSessions(RELAY, USER, devices, fetchImpl);
    expect(out).toEqual([
      { deviceUuid: "uuid-a", projectId: "proj1", displayName: "My Mac", connectedAt: 1234 },
    ]);
  });

  test("excludes the bare control-plane connection (no dot)", async () => {
    const devices = [device("uuid-a", "My Mac")];
    const fetchImpl = relayReturning([conn({ deviceId: "uuid-a" })]);
    expect(await listUserSessions(RELAY, USER, devices, fetchImpl)).toEqual([]);
  });

  test("excludes app connections", async () => {
    const devices = [device("uuid-a", "My Mac")];
    const fetchImpl = relayReturning([conn({ deviceId: "uuid-a.proj1", deviceType: "app" })]);
    expect(await listUserSessions(RELAY, USER, devices, fetchImpl)).toEqual([]);
  });

  test("falls back to the deviceUuid when no web device row matches", async () => {
    const devices: DeviceRow[] = []; // row revoked in web, agent still connected
    const fetchImpl = relayReturning([conn({ deviceId: "uuid-a.proj1", connectedAt: 7 })]);
    const out = await listUserSessions(RELAY, USER, devices, fetchImpl);
    expect(out).toEqual([
      { deviceUuid: "uuid-a", projectId: "proj1", displayName: "uuid-a", connectedAt: 7 },
    ]);
  });

  test("preserves a projectId containing dots (splits on first dot only)", async () => {
    const devices = [device("uuid-a", "My Mac")];
    const fetchImpl = relayReturning([conn({ deviceId: "uuid-a.my.proj.v2" })]);
    const out = await listUserSessions(RELAY, USER, devices, fetchImpl);
    expect(out?.[0]?.projectId).toBe("my.proj.v2");
  });

  test("returns null when the relay is unreachable", async () => {
    const devices = [device("uuid-a", "My Mac")];
    const fetchImpl = (async () => { throw new Error("network"); }) as unknown as typeof fetch;
    expect(await listUserSessions(RELAY, USER, devices, fetchImpl)).toBeNull();
  });

  test("returns null when relay config is missing", async () => {
    const devices = [device("uuid-a", "My Mac")];
    expect(await listUserSessions({}, USER, devices)).toBeNull();
  });
});
