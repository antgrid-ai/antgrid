// bridge/tests/session-bus-route-store.test.ts
import { test, expect } from "bun:test";
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { MAX_BUS_ROUTES } from "../src/session-bus/constants";
import { loadBusRoutes, saveBusRoutes, type BusRouteMap } from "../src/session-bus/route-store";
import { sessionBusProjectDir } from "../src/session-bus/store-fs";

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
    saveBusRoutes(abDir, "p1", routes([["ctx-1", "app#machine", "p1", T0]]));
    const loaded = loadBusRoutes(abDir, "p1", TTL, T0 + 1_000);
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
      "p1",
      routes([
        ["older", "app-a", "proj-a", T0],
        ["newer", "app-b", "proj-b", T0 + 1_000],
      ]),
    );
    const loaded = loadBusRoutes(abDir, "p1", TTL * 1_000, T0 + 1_000);
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
    saveBusRoutes(abDir, "p1", routes([["fresh", "a", "p1", T0], ["stale", "b", "p1", T0 - TTL]]));
    const loaded = loadBusRoutes(abDir, "p1", TTL, T0);
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
    saveBusRoutes(abDir, "p1", routes(over));

    const loaded = loadBusRoutes(abDir, "p1", TTL * 1_000, T0);
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

test("an unreadable routes file loads as no routes rather than throwing", () => {
  const abDir = tmpAbDir();
  try {
    const dir = sessionBusProjectDir(abDir, "p1");
    mkdirSync(dir, { recursive: true });
    writeFileSync(join(dir, "routes.json"), "{ not json", "utf8");
    expect(loadBusRoutes(abDir, "p1", TTL, T0).size).toBe(0);
  } finally {
    rmSync(abDir, { recursive: true, force: true });
  }
});

test("a project with no file yet has no routes", () => {
  const abDir = tmpAbDir();
  try {
    expect(loadBusRoutes(abDir, "never-run", TTL, T0).size).toBe(0);
  } finally {
    rmSync(abDir, { recursive: true, force: true });
  }
});
