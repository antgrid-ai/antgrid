import { test, expect, beforeEach, afterEach } from "bun:test";
import { Database } from "bun:sqlite";
import { existsSync, mkdirSync, mkdtempSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { setLogLevel } from "../src/logger";
import { BUS_DB_VERSION, busDbPath, resetBusDbAnnouncements, tryBusDb, withBusDb } from "../src/session-bus/bus-db";
import { emptyDeliveries, enqueueLine, loadDeliveries, saveDeliveries } from "../src/session-bus/delivery-queue";
import { emptyHeld, holdMessage, loadHeld, saveHeld } from "../src/session-bus/held-store";

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
  // No caller of this seam has a throw-shaped path to put a database error on:
  // each folds its store from whatever comes back, so the empty store has to be
  // an answer. A directory standing where the file goes is the cheapest
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

test("a database this build cannot read at all is moved aside, not kept forever", () => {
  // Every store on the machine is in this one file, so a truncated write from a
  // power cut would otherwise cost this abDir its routes, held messages, logs,
  // artifact handles and delivery queue for the life of the install — the JSON
  // stores recovered on their next write without anyone deciding they should.
  withBusDb(abDir, (db) => db.exec("INSERT INTO bus_routes (contextId, peerId, projectId, at) VALUES ('c', 'p', 'proj', 1)"), null);
  writeFileSync(busDbPath(abDir), "this is not a database".repeat(20));

  const rows = withBusDb(
    abDir,
    (db) => {
      db.query("INSERT INTO bus_routes (contextId, peerId, projectId, at) VALUES (?, ?, ?, ?)").run("after", "p", "proj", 2);
      return db.query("SELECT contextId FROM bus_routes").all() as { contextId: string }[];
    },
    [],
  );

  expect(rows.map((r) => r.contextId)).toEqual(["after"]);
  // Kept rather than deleted: a database that reached this state is the only
  // evidence of whatever produced it.
  expect(existsSync(`${busDbPath(abDir)}.corrupt`)).toBe(true);
});

test("a lock we merely lost is NOT treated as corruption", () => {
  // The other half of the rule above, and the one that costs rows if it is
  // wrong: a sibling host holding the write lock is the documented setup, and
  // moving the file aside there would throw away everything it had written.
  withBusDb(abDir, (db) => db.exec("INSERT INTO bus_routes (contextId, peerId, projectId, at) VALUES ('kept', 'p', 'proj', 1)"), null);

  const blocker = new Database(busDbPath(abDir));
  try {
    blocker.exec("BEGIN EXCLUSIVE");
    expect(tryBusDb(abDir, "a write under a sibling's lock", (db) =>
      db.query("INSERT INTO bus_routes (contextId, peerId, projectId, at) VALUES (?, ?, ?, ?)").run("blocked", "p", "proj", 2),
    )).toBe(false);
  } finally {
    blocker.exec("ROLLBACK");
    blocker.close();
  }

  expect(existsSync(`${busDbPath(abDir)}.corrupt`)).toBe(false);
  expect(withBusDb(abDir, (db) => (db.query("SELECT contextId FROM bus_routes").all() as { contextId: string }[]).map((r) => r.contextId), []))
    .toEqual(["kept"]);
});

test("an operation that must not be reported as done answers false when it was not", () => {
  // `withBusDb`'s empty-store fallback is a truthful answer to a read and to a
  // save the next message event rewrites. It is a lie for a delete and for a
  // publish: nothing comes after them to correct it, and a caller is about to
  // report success on their behalf.
  mkdirSync(busDbPath(abDir), { recursive: true });
  expect(tryBusDb(abDir, "a write with nowhere to go", () => {})).toBe(false);

  rmSync(busDbPath(abDir), { recursive: true, force: true });
  expect(tryBusDb(abDir, "a write that can land", () => {})).toBe(true);
});

test.skipIf(process.platform === "win32")("the database is owner-only, like every other store under the state dir", () => {
  // One file now holds every message body, held frame, rendered delivery line
  // and peer relay slot id on the machine. SQLite gives `-wal` and `-shm` the
  // mode of the database file, so the whole set rides on this one chmod.
  withBusDb(abDir, (db) => db.exec("INSERT INTO bus_routes (contextId, peerId, projectId, at) VALUES ('c', 'p', 'proj', 1)"), null);
  expect(statSync(busDbPath(abDir)).mode & 0o777).toBe(0o600);
});

test("a bad row costs that row in every store built on this seam", () => {
  // `bus_held` and `bus_deliveries` have no suite of their own, and the
  // property is the seam's rather than either store's: a record that fails Zod
  // on the way back in is skipped alone. Held messages are the ones a restart
  // re-arms, and a queued line is one the sending machine was already told had
  // left — emptying either store on one bad row loses work nothing can notice
  // is missing.
  saveHeld(abDir, "p1", "s1", holdMessage(
    holdMessage(emptyHeld(), { messageId: "h-good", contextId: "c", role: "lead", to: { machineId: "m", projectId: "p", sessionId: "s" }, frame: { type: "session-bus:message" }, heldAt: 1 }),
    { messageId: "h-bad", contextId: "c", role: "lead", to: { machineId: "m", projectId: "p", sessionId: "s" }, frame: { type: "session-bus:message" }, heldAt: 2 },
  ));
  saveDeliveries(abDir, "p1", enqueueLine(
    enqueueLine(emptyDeliveries(), { id: "l-good", sessionId: "s1", kind: "wake", text: "a", queuedAt: 1 }),
    { id: "l-bad", sessionId: "s1", kind: "wake", text: "b", queuedAt: 2 },
  ));

  const raw = new Database(busDbPath(abDir));
  try {
    raw.query("UPDATE bus_held SET held = ? WHERE held LIKE ?").run("{trunc", "%h-bad%");
    raw.query("UPDATE bus_deliveries SET line = ? WHERE line LIKE ?").run("{trunc", "%l-bad%");
  } finally {
    raw.close();
  }

  expect(loadHeld(abDir, "p1", "s1").held.map((h) => h.messageId)).toEqual(["h-good"]);
  expect(loadDeliveries(abDir, "p1").lines.map((l) => l.id)).toEqual(["l-good"]);
});
