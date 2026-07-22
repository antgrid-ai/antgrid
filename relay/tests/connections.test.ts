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
    name: overrides.name ?? "test",
    publicKey: overrides.publicKey ?? "pk",
    epoch: overrides.epoch ?? 1,
    ws: overrides.ws ?? ws,
    ip: overrides.ip ?? "127.0.0.1",
    connectedAt: overrides.connectedAt ?? Date.now(),
    lastSeen: overrides.lastSeen ?? Date.now(),
    claims: overrides.claims,
    openStreams: overrides.openStreams ?? new Set<string>(),
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

describe("Connections.countOpenStreamsForUser", () => {
  it("sums openStreams across agent connections for one uid, ignoring apps and other users", () => {
    const c = new Connections();
    const a1 = makeConn({ deviceId: "a1", deviceType: "agent", claims: { uid: "u1" }, openStreams: new Set(["s1", "s2"]) });
    const a2 = makeConn({ deviceId: "a2", deviceType: "agent", claims: { uid: "u1" }, openStreams: new Set(["s3"]) });
    const otherUser = makeConn({ deviceId: "a3", deviceType: "agent", claims: { uid: "u2" }, openStreams: new Set(["s4", "s5"]) });
    const app = makeConn({ deviceId: "p1", deviceType: "app", claims: { uid: "u1" }, openStreams: new Set(["ignored"]) });
    for (const conn of [a1, a2, otherUser, app]) c.insert(conn);

    expect(c.countOpenStreamsForUser("u1")).toBe(3);
    expect(c.countOpenStreamsForUser("u2")).toBe(2);
    expect(c.countOpenStreamsForUser("nobody")).toBe(0);
  });

  it("reflects live removal — release-before-insert never double counts", () => {
    const c = new Connections();
    const old = makeConn({ deviceId: "a1", deviceType: "agent", claims: { uid: "u1" }, openStreams: new Set(["s1"]) });
    c.insert(old);
    expect(c.countOpenStreamsForUser("u1")).toBe(1);

    c.remove(old); // supersession: drop old (and its openStreams) before inserting the new epoch
    const fresh = makeConn({ deviceId: "a1", deviceType: "agent", claims: { uid: "u1" }, openStreams: new Set() });
    c.insert(fresh);
    expect(c.countOpenStreamsForUser("u1")).toBe(0);
  });
});

describe("Connections IP counting", () => {
  it("increments and decrements per IP, clamping at zero", () => {
    const c = new Connections();
    expect(c.getConnectionCountByIp("1.2.3.4")).toBe(0);
    c.incrementIpCount("1.2.3.4");
    c.incrementIpCount("1.2.3.4");
    expect(c.getConnectionCountByIp("1.2.3.4")).toBe(2);
    c.decrementIpCount("1.2.3.4");
    expect(c.getConnectionCountByIp("1.2.3.4")).toBe(1);
    c.decrementIpCount("1.2.3.4");
    expect(c.getConnectionCountByIp("1.2.3.4")).toBe(0);
    // Further decrements below zero are a no-op, not negative.
    c.decrementIpCount("1.2.3.4");
    expect(c.getConnectionCountByIp("1.2.3.4")).toBe(0);
  });

  it("tracks distinct IPs independently", () => {
    const c = new Connections();
    c.incrementIpCount("1.1.1.1");
    c.incrementIpCount("2.2.2.2");
    c.incrementIpCount("2.2.2.2");
    expect(c.getConnectionCountByIp("1.1.1.1")).toBe(1);
    expect(c.getConnectionCountByIp("2.2.2.2")).toBe(2);
  });
});

describe("Connections user-scoped views", () => {
  it("getConnectionsForUser returns only that uid's live connections", () => {
    const c = new Connections();
    const a = makeConn({ deviceId: "a", claims: { uid: "u1" } });
    const b = makeConn({ deviceId: "b", claims: { uid: "u2" } });
    c.insert(a);
    c.insert(b);
    expect(c.getConnectionsForUser("u1")).toEqual([a]);
  });

  it("listConnections/listConnectionsForUser project identity-free summaries", () => {
    const c = new Connections();
    const a = makeConn({ deviceId: "a", claims: { uid: "u1" }, publicKey: "secret-pk" });
    c.insert(a);
    const [summary] = c.listConnections();
    expect(summary).toMatchObject({ deviceId: "a", deviceType: "agent" });
    expect(summary).not.toHaveProperty("publicKey");
    expect(summary).not.toHaveProperty("claims");

    const [scoped] = c.listConnectionsForUser("u1");
    expect(scoped.deviceId).toBe("a");
    expect(c.listConnectionsForUser("nobody")).toEqual([]);
  });
});

describe("Connections.clear", () => {
  it("empties both indexes and IP counts", () => {
    const c = new Connections();
    c.insert(makeConn({ connectionId: "c1", deviceId: "d1" }));
    c.incrementIpCount("1.2.3.4");
    c.clear();
    expect(c.getConnectionCount()).toBe(0);
    expect(c.getByConnectionId("c1")).toBeUndefined();
    expect(c.getConnectionCountByIp("1.2.3.4")).toBe(0);
  });
});
