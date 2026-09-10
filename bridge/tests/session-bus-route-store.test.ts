// bridge/tests/session-bus-route-store.test.ts
import { test, expect } from "bun:test";
import { existsSync, mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { MAX_BUS_ROUTES } from "../src/session-bus/constants";
import { loadBusRoutes, saveBusRoutes, type BusRouteMap } from "../src/session-bus/route-store";
import { busDbPath } from "../src/session-bus/bus-db";
import { Database } from "bun:sqlite";

const T0 = 2_000_000;
const TTL = 60_000;

function tmpAbDir(): string {
  return mkdtempSync(join(tmpdir(), "ab-bus-routes-"));
}

function routes(entries: [contextId: string, peerId: string, projectId: string, at: number][]): BusRouteMap {
  return new Map(entries.map(([contextId, peerId, projectId, at]) => [contextId, { peerId, projectId, at }]));
}

test("a route written by one process is the route the next one uses", () => {
  const abDir = tmpAbDir();
  try {
    saveBusRoutes(abDir, routes([["ctx-1", "app#machine", "p1", T0]]));
    const loaded = loadBusRoutes(abDir, TTL, T0 + 1_000);
    expect(loaded.get("ctx-1")).toEqual({ peerId: "app#machine", projectId: "p1", at: T0 });
  } finally {
    rmSync(abDir, { recursive: true, force: true });
  }
});

test("a route round-trips its projectId, and oldest-first order survives save then load", () => {
  const abDir = tmpAbDir();
  try {
    saveBusRoutes(
      abDir,
      routes([
        ["older", "app-a", "proj-a", T0],
        ["newer", "app-b", "proj-b", T0 + 1_000],
      ]),
    );
    const loaded = loadBusRoutes(abDir, TTL * 1_000, T0 + 1_000);
    expect(loaded.get("older")).toEqual({ peerId: "app-a", projectId: "proj-a", at: T0 });
    expect(loaded.get("newer")).toEqual({ peerId: "app-b", projectId: "proj-b", at: T0 + 1_000 });
    expect([...loaded.keys()]).toEqual(["older", "newer"]);
  } finally {
    rmSync(abDir, { recursive: true, force: true });
  }
});

test("a route nothing has carried in longer than the TTL is not loaded", () => {
  const abDir = tmpAbDir();
  try {
    saveBusRoutes(abDir, routes([["fresh", "a", "p1", T0], ["stale", "b", "p1", T0 - TTL]]));
    const loaded = loadBusRoutes(abDir, TTL, T0);
    expect([...loaded.keys()]).toEqual(["fresh"]);
  } finally {
    rmSync(abDir, { recursive: true, force: true });
  }
});

test("past the cap the freshest are kept, and they load oldest first", () => {
  const abDir = tmpAbDir();
  try {
    const over: [string, string, string, number][] = [];
    for (let i = 0; i < MAX_BUS_ROUTES + 5; i++) over.push([`ctx-${i}`, `app-${i}`, "p1", T0 + i]);
    saveBusRoutes(abDir, routes(over));

    const loaded = loadBusRoutes(abDir, TTL * 1_000, T0);
    expect(loaded.size).toBe(MAX_BUS_ROUTES);
    // The five oldest are the ones that went.
    expect(loaded.has("ctx-0")).toBe(false);
    expect(loaded.has(`ctx-${MAX_BUS_ROUTES + 4}`)).toBe(true);
    // Iteration order is what the in-memory eviction reads as age, so the file
    // has to hand back the least recently carried FIRST.
    const first = [...loaded.keys()][0]!;
    const last = [...loaded.keys()][loaded.size - 1]!;
    expect(loaded.get(first)!.at).toBeLessThan(loaded.get(last)!.at);
  } finally {
    rmSync(abDir, { recursive: true, force: true });
  }
});

test("multiple projects' routes share one machine-level table, not one file each", () => {
  const abDir = tmpAbDir();
  try {
    saveBusRoutes(
      abDir,
      routes([
        ["ctx-a", "app-a", "proj-a", T0],
        ["ctx-b", "app-b", "proj-b", T0 + 1],
      ]),
    );
    const loaded = loadBusRoutes(abDir, TTL, T0 + 1_000);
    expect(loaded.get("ctx-a")?.projectId).toBe("proj-a");
    expect(loaded.get("ctx-b")?.projectId).toBe("proj-b");
  } finally {
    rmSync(abDir, { recursive: true, force: true });
  }
});

test("two writers sharing one machine file keep each other's rows", () => {
  const abDir = tmpAbDir();
  try {
    // Writer A's own table has only ever heard of ctx-a.
    saveBusRoutes(abDir, routes([["ctx-a", "app-a", "proj-a", T0]]));
    // Writer B is a separate process (or the same one, later) whose table has
    // only ever heard of ctx-b — its save must not read ctx-a's absence from
    // ITS table as reason to drop what writer A already persisted.
    saveBusRoutes(abDir, routes([["ctx-b", "app-b", "proj-b", T0 + 1]]));
    const loaded = loadBusRoutes(abDir, TTL * 1_000, T0 + 1_000);
    expect(loaded.get("ctx-a")).toEqual({ peerId: "app-a", projectId: "proj-a", at: T0 });
    expect(loaded.get("ctx-b")).toEqual({ peerId: "app-b", projectId: "proj-b", at: T0 + 1 });
  } finally {
    rmSync(abDir, { recursive: true, force: true });
  }
});

test("a save never lets a stale row it still holds regress a fresher one on disk", () => {
  const abDir = tmpAbDir();
  try {
    // A fresher row is already on disk — written by a sibling process, or by
    // this same one moments ago.
    saveBusRoutes(abDir, routes([["ctx-1", "app-fresh", "p1", T0 + 1_000]]));
    // This writer's own table still carries an older row for the same context
    // (e.g. loaded at hydrate and never re-learned since) and saves again.
    saveBusRoutes(abDir, routes([["ctx-1", "app-stale", "p1", T0]]));
    const loaded = loadBusRoutes(abDir, TTL * 1_000, T0 + 2_000);
    expect(loaded.get("ctx-1")).toEqual({ peerId: "app-fresh", projectId: "p1", at: T0 + 1_000 });
  } finally {
    rmSync(abDir, { recursive: true, force: true });
  }
});

test("a named drop erases the row a bare absence would have resurrected", () => {
  const abDir = tmpAbDir();
  try {
    saveBusRoutes(abDir, routes([["ctx-lapsed", "app-a", "p1", T0], ["ctx-live", "app-b", "p1", T0]]));
    // What a TTL expiry or an LRU eviction leaves behind: a table that simply
    // no longer mentions the row. Only the explicit drop makes it gone.
    saveBusRoutes(abDir, routes([["ctx-live", "app-b", "p1", T0]]), { contextIds: ["ctx-lapsed"] });
    const loaded = loadBusRoutes(abDir, TTL * 1_000, T0 + 1_000);
    expect([...loaded.keys()]).toEqual(["ctx-live"]);
  } finally {
    rmSync(abDir, { recursive: true, force: true });
  }
});

test("a dropped context relearned before the save wins over the drop", () => {
  const abDir = tmpAbDir();
  try {
    saveBusRoutes(abDir, routes([["ctx-1", "app-old", "p1", T0]]));
    // noteRoute prunes on a TTL sweep and can re-set the very context it just
    // pruned, in that order, before one save. The incoming row is proof the
    // route is live again, so the drop must not outrank it — which is why
    // contextIds are applied to the DISK rows, before the merge.
    saveBusRoutes(abDir, routes([["ctx-1", "app-new", "p1", T0 + 500]]), { contextIds: ["ctx-1"] });
    const loaded = loadBusRoutes(abDir, TTL * 1_000, T0 + 1_000);
    expect(loaded.get("ctx-1")).toEqual({ peerId: "app-new", projectId: "p1", at: T0 + 500 });
  } finally {
    rmSync(abDir, { recursive: true, force: true });
  }
});

test("a purge drops a project's rows even when the writer's own table never held them", () => {
  const abDir = tmpAbDir();
  try {
    saveBusRoutes(
      abDir,
      routes([
        ["ctx-gone", "app-a", "p-forgotten", T0],
        ["ctx-kept", "app-b", "p-kept", T0],
      ]),
    );
    // The forgetting writer's in-memory table has already dropped ctx-gone, so
    // its save carries only what remains — a plain merge would read that
    // absence as "unknown to me", not "gone", and write ctx-gone straight back.
    saveBusRoutes(abDir, routes([["ctx-kept", "app-b", "p-kept", T0]]), { projectId: "p-forgotten" });
    const loaded = loadBusRoutes(abDir, TTL * 1_000, T0 + 1_000);
    expect([...loaded.keys()]).toEqual(["ctx-kept"]);
  } finally {
    rmSync(abDir, { recursive: true, force: true });
  }
});

test("the route table lives at the machine root, not under any project", () => {
  const abDir = tmpAbDir();
  try {
    saveBusRoutes(abDir, routes([["ctx-1", "app#machine", "p1", T0]]));
    // Pinned as a literal on purpose. Every other case in this file writes and
    // reads through the same helper, so a relocation carries both halves with
    // it and none of them go red — the same blind spot the delivery queue had.
    // This is the assertion that caught the move off routes.json, and it is
    // kept as a literal for the next one.
    expect(existsSync(join(abDir, "session-bus", "bus.db"))).toBe(true);
    // Nothing this store writes may land under a project: a route is looked up
    // by context id, which can name a session in any project on the machine.
    expect(existsSync(join(abDir, "agents"))).toBe(false);
  } finally {
    rmSync(abDir, { recursive: true, force: true });
  }
});

test("one unreadable row costs one route, not the machine's whole table", () => {
  // The JSON store this replaced had no way to say this: a single malformed
  // record failed the file's schema, and the read answered EMPTY — every
  // project's carrier bindings gone at once, for one bad row, with nothing
  // logged. Written by raw SQL because saveBusRoutes cannot produce it.
  const abDir = tmpAbDir();
  try {
    saveBusRoutes(abDir, routes([["ctx-good", "app-a", "p1", T0]]));
    const raw = new Database(busDbPath(abDir));
    try {
      raw.query("INSERT INTO bus_routes (contextId, peerId, projectId, at) VALUES (?, ?, ?, ?)")
        .run("ctx-bad", "", "p1", T0);
    } finally {
      raw.close();
    }

    expect([...loadBusRoutes(abDir, TTL * 1_000, T0).keys()]).toEqual(["ctx-good"]);
  } finally {
    rmSync(abDir, { recursive: true, force: true });
  }
});

test("a machine with no routes yet has no routes", () => {
  const abDir = tmpAbDir();
  try {
    expect(loadBusRoutes(abDir, TTL, T0).size).toBe(0);
  } finally {
    rmSync(abDir, { recursive: true, force: true });
  }
});
