import { describe, it, expect } from "bun:test";
import type { ServerWebSocket } from "bun";
import { Connections, type Connection, type WsData } from "../src/connections";

let seq = 0;

function makeConn(overrides: Partial<Connection> = {}): Connection {
  seq += 1;
  const ws = { readyState: 1, close: () => {}, send: () => {} } as unknown as ServerWebSocket<WsData>;
  return {
    connectionId: overrides.connectionId ?? `conn-${seq}`,
    deviceId: overrides.deviceId ?? `dev-${seq}`,
    deviceType: overrides.deviceType ?? "agent",
    uid: overrides.uid ?? "user-test",
    publicKey: overrides.publicKey ?? "pk",
    epoch: overrides.epoch ?? 1,
    helloNonce: overrides.helloNonce ?? `nonce-${seq}`,
    helloTs: overrides.helloTs ?? Date.now(),
    ws: overrides.ws ?? ws,
    connectedAt: overrides.connectedAt ?? Date.now(),
    lastSeen: overrides.lastSeen ?? Date.now(),
  };
}

describe("Connections indexing", () => {
  it("insert makes a connection reachable by both connectionId and deviceId", () => {
    const c = new Connections();
    const conn = makeConn({ connectionId: "c1", deviceId: "d1" });
    c.insert(conn);
    expect(c.getByConnectionId("c1")).toBe(conn);
    expect(c.getByDeviceId("d1")).toBe(conn);
    expect(c.getConnectionCount()).toBe(1);
  });

  it("remove drops both indexes", () => {
    const c = new Connections();
    const conn = makeConn({ connectionId: "c1", deviceId: "d1" });
    c.insert(conn);
    c.remove(conn);
    expect(c.getByConnectionId("c1")).toBeUndefined();
    expect(c.getByDeviceId("d1")).toBeUndefined();
    expect(c.getConnectionCount()).toBe(0);
  });

  it("removing a stale (already-superseded) connection object does not evict its successor", () => {
    // Mirrors epoch supersession ordering: the old entry is removed, then the
    // new one is inserted under the same deviceId. A late/duplicate remove()
    // call against the STALE object must be a no-op against the live holder.
    const c = new Connections();
    const oldConn = makeConn({ connectionId: "old", deviceId: "d1" });
    c.insert(oldConn);
    c.remove(oldConn);
    const newConn = makeConn({ connectionId: "new", deviceId: "d1" });
    c.insert(newConn);

    c.remove(oldConn); // stale object, already removed once — must not touch newConn
    expect(c.getByDeviceId("d1")).toBe(newConn);
    expect(c.getByConnectionId("new")).toBe(newConn);
  });
});


describe("Connections user-scoped views", () => {
  it("getConnectionsForUser returns only that uid's live connections", () => {
    const c = new Connections();
    const a = makeConn({ deviceId: "a", uid: "u1" });
    const b = makeConn({ deviceId: "b", uid: "u2" });
    c.insert(a);
    c.insert(b);
    expect(c.getConnectionsForUser("u1")).toEqual([a]);
  });

  it("listConnections/listConnectionsForUser project identity-free summaries", () => {
    const c = new Connections();
    const a = makeConn({ deviceId: "a", uid: "u1", publicKey: "secret-pk" });
    c.insert(a);
    const [summary] = c.listConnections();
    expect(summary).toMatchObject({ deviceId: "a", deviceType: "agent" });
    expect(summary).not.toHaveProperty("publicKey");
    expect(summary).not.toHaveProperty("uid");

    const [scoped] = c.listConnectionsForUser("u1");
    expect(scoped.deviceId).toBe("a");
    expect(c.listConnectionsForUser("nobody")).toEqual([]);
  });

});

describe("Connections.clear", () => {
  it("empties both indexes", () => {
    const c = new Connections();
    c.insert(makeConn({ connectionId: "c1", deviceId: "d1" }));
    c.clear();
    expect(c.getConnectionCount()).toBe(0);
    expect(c.getByConnectionId("c1")).toBeUndefined();
  });
});

describe("getByAccountDevice", () => {
  // An app registers one per-machine slot (`<accountDeviceUuid>#<machine>`) per
  // machine it holds open, so anything driven by an account device id — the
  // internal revoke route — must reach all of them, not just an exact hit.
  it("returns every per-machine slot scoped under the account device", () => {
    const c = new Connections();
    const a = makeConn({ deviceId: "acct-1#machine-a", deviceType: "app" });
    const b = makeConn({ deviceId: "acct-1#machine-b", deviceType: "app" });
    c.insert(a);
    c.insert(b);

    expect(new Set(c.getByAccountDevice("acct-1"))).toEqual(new Set([a, b]));
  });

  it("returns the bare holder when the device registered unscoped", () => {
    const c = new Connections();
    const agent = makeConn({ deviceId: "acct-1", deviceType: "agent" });
    c.insert(agent);

    expect(c.getByAccountDevice("acct-1")).toEqual([agent]);
  });

  it("does not match an account device that merely shares a prefix", () => {
    const c = new Connections();
    c.insert(makeConn({ deviceId: "acct-10#machine-a", deviceType: "app" }));
    c.insert(makeConn({ deviceId: "acct-1-other", deviceType: "app" }));

    expect(c.getByAccountDevice("acct-1")).toEqual([]);
  });

  it("returns nothing for a device with no live connection", () => {
    const c = new Connections();
    c.insert(makeConn({ deviceId: "acct-2#machine-a", deviceType: "app" }));

    expect(c.getByAccountDevice("acct-1")).toEqual([]);
  });
});
