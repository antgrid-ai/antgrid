import { test, expect, beforeEach, afterEach } from "bun:test";
import { Database } from "bun:sqlite";
import { existsSync, mkdirSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { setLogLevel } from "../src/logger";
import { BUS_DB_VERSION, busDbPath, resetBusDbAnnouncements, withBusDb } from "../src/session-bus/bus-db";

setLogLevel("error");

let abDir: string;

beforeEach(() => {
  abDir = mkdtempSync(join(tmpdir(), "antgrid-bus-db-"));
  resetBusDbAnnouncements();
});

afterEach(() => {
  rmSync(abDir, { recursive: true, force: true });
});

test("a fresh abDir gets a stamped database, and the tables it names", () => {
  const rows = withBusDb(
    abDir,
    (db) => {
      db.query("INSERT INTO bus_routes (contextId, peerId, projectId, at) VALUES (?, ?, ?, ?)").run("c1", "p1", "proj", 1);
      return db.query("SELECT contextId FROM bus_routes").all() as { contextId: string }[];
    },
    [],
  );
  expect(rows.map((r) => r.contextId)).toEqual(["c1"]);
  expect(existsSync(busDbPath(abDir))).toBe(true);

  const db = new Database(busDbPath(abDir), { readonly: true });
  try {
    expect((db.query("PRAGMA user_version").get() as { user_version: number }).user_version).toBe(BUS_DB_VERSION);
  } finally {
    db.close();
  }
});

test("a database written under another version is dropped, never read", () => {
  // The whole of the no-migration decision, made observable. Reading a row
  // written under a shape this bridge no longer holds is the failure; losing it
  // costs a relearned route and a redelivered message, both of which the
  // protocol already tolerates.
  withBusDb(abDir, (db) => db.exec("INSERT INTO bus_routes (contextId, peerId, projectId, at) VALUES ('old', 'p', 'proj', 1)"), null);
  const raw = new Database(busDbPath(abDir));
  try {
    raw.exec("PRAGMA user_version = 99");
  } finally {
    raw.close();
  }

  const found = withBusDb(abDir, (db) => db.query("SELECT contextId FROM bus_routes").all(), null);
  expect(found).toEqual([]);

  const db = new Database(busDbPath(abDir), { readonly: true });
  try {
    expect((db.query("PRAGMA user_version").get() as { user_version: number }).user_version).toBe(BUS_DB_VERSION);
  } finally {
    db.close();
  }
});

test("a database that cannot be opened answers the fallback rather than throwing", () => {
  // Every caller of this seam replaced a JSON store whose read answered EMPTY on
  // any failure at all, and none of them has a throw-shaped path to put a
  // database error on. A directory standing where the file goes is the cheapest
  // unopenable path there is, and it behaves the same on every platform.
  mkdirSync(busDbPath(abDir), { recursive: true });

  // Identity, not equality: a fallback that merely LOOKS like the query's own
  // empty answer would prove nothing about which of the two came back.
  const fallback = { fellBack: true };
  const answer = withBusDb<unknown>(abDir, (db) => db.query("SELECT contextId FROM bus_routes").all(), fallback);

  expect(answer).toBe(fallback);
});

test("a failure does not take the next operation with it", () => {
  // The fallback is per call. A caller that recovers — the directory removed, a
  // permission restored — must not be held to the first answer, because nothing
  // in this process would ever revisit it.
  mkdirSync(busDbPath(abDir), { recursive: true });
  expect(withBusDb(abDir, () => "reached", "fell back")).toBe("fell back");

  rmSync(busDbPath(abDir), { recursive: true, force: true });

  expect(withBusDb(abDir, () => "reached", "fell back")).toBe("reached");
});
