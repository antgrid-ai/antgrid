import { describe, test, expect } from "bun:test";
import { listUserSessions, runningSessionCount } from "../../src/services/sessions.js";
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
    connectedAt: 1000,
    lastSeen: 2000,
    openStreamCount: 1,
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
  test("maps a bare-deviceUuid agent and joins the device display name", async () => {
    const devices = [device("uuid-a", "My Mac")];
    const fetchImpl = relayReturning([
      conn({ deviceId: "uuid-a", connectedAt: 1234, openStreamCount: 2 }),
    ]);
    const out = await listUserSessions(RELAY, USER, devices, fetchImpl);
    expect(out).toEqual([
      { deviceUuid: "uuid-a", displayName: "My Mac", connectedAt: 1234, openStreamCount: 2 },
    ]);
  });

  // The v2 regression: the bare id used to be read as "control plane, not
  // billable" and dropped, which under v3 discards every agent there is.
  test("keeps a bare agent connection with no dot in its deviceId", async () => {
    const devices = [device("uuid-a", "My Mac")];
    const fetchImpl = relayReturning([conn({ deviceId: "uuid-a" })]);
    const out = await listUserSessions(RELAY, USER, devices, fetchImpl);
    expect(out).toHaveLength(1);
    expect(out?.[0]?.deviceUuid).toBe("uuid-a");
  });

  test("keeps a connected agent holding no open stream, reported as idle", async () => {
    const devices = [device("uuid-a", "My Mac")];
    const fetchImpl = relayReturning([conn({ deviceId: "uuid-a", openStreamCount: 0 })]);
    const out = await listUserSessions(RELAY, USER, devices, fetchImpl);
    expect(out?.[0]?.openStreamCount).toBe(0);
    expect(runningSessionCount(out!)).toBe(0);
  });

  test("excludes app connections", async () => {
    const devices = [device("uuid-a", "My Mac")];
    const fetchImpl = relayReturning([conn({ deviceId: "uuid-a#machine-1", deviceType: "app" })]);
    expect(await listUserSessions(RELAY, USER, devices, fetchImpl)).toEqual([]);
  });

  test("falls back to the deviceUuid when no web device row matches", async () => {
    const devices: DeviceRow[] = []; // row revoked in web, agent still connected
    const fetchImpl = relayReturning([conn({ deviceId: "uuid-a", connectedAt: 7 })]);
    const out = await listUserSessions(RELAY, USER, devices, fetchImpl);
    expect(out).toEqual([
      { deviceUuid: "uuid-a", displayName: "uuid-a", connectedAt: 7, openStreamCount: 1 },
    ]);
  });

  // Deploy skew: a relay predating openStreamCount must not sum to NaN and
  // render a confident wrong number — "we couldn't tell" is the honest state.
  test("returns null when the relay answers with a pre-openStreamCount shape", async () => {
    const devices = [device("uuid-a", "My Mac")];
    const legacy = { deviceId: "uuid-a", deviceType: "agent", connectedAt: 1, lastSeen: 2 };
    const fetchImpl = (async () =>
      new Response(JSON.stringify({ connections: [legacy] }), {
        headers: { "content-type": "application/json" },
      })) as unknown as typeof fetch;
    expect(await listUserSessions(RELAY, USER, devices, fetchImpl)).toBeNull();
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

describe("runningSessionCount", () => {
  // Must match the relay's countOpenStreamsForUser denominator: streams summed
  // across machines, not the machine count.
  test("sums open streams across machines", async () => {
    const devices = [device("uuid-a", "My Mac"), device("uuid-b", "Work PC")];
    const fetchImpl = relayReturning([
      conn({ deviceId: "uuid-a", openStreamCount: 3 }),
      conn({ deviceId: "uuid-b", openStreamCount: 2 }),
    ]);
    const out = await listUserSessions(RELAY, USER, devices, fetchImpl);
    expect(out).toHaveLength(2);
    expect(runningSessionCount(out!)).toBe(5);
  });

  test("is zero for an empty list", () => {
    expect(runningSessionCount([])).toBe(0);
  });
});
