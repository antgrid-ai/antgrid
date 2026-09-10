import { test, expect, beforeEach, afterEach } from "bun:test";
import { Database } from "bun:sqlite";
import { existsSync, mkdirSync, mkdtempSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { setLogLevel } from "../src/logger";
import { BUS_DB_VERSION, busDbPath, resetBusDbAnnouncements, tryBusDb, withBusDb } from "../src/session-bus/bus-db";
import { emptyDeliveries, enqueueLine, loadDeliveries, saveDeliveries } from "../src/session-bus/delivery-queue";
import { listSessionBusSessions, removeSessionBusProject, removeSessionBusSession } from "../src/session-bus/store-fs";
import { emptyHeld, holdMessage, loadHeld, saveHeld } from "../src/session-bus/held-store";
import { appendLog, emptyLog, loadMessageLog, saveMessageLog } from "../src/session-bus/message-log";
import { stampEnvelope } from "../src/session-bus/envelope";
import { MAX_LOG_ENTRIES } from "../src/session-bus/constants";

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

const PEER = { machineId: "m2", projectId: "p-remote", sessionId: "s-remote" };

function logOf(count: number, from = 0) {
  let state = emptyLog();
  for (let i = from; i < from + count; i += 1) {
    state = appendLog(state, {
      at: i + 1,
      direction: "out",
      peer: PEER,
      envelope: stampEnvelope(
        { taskId: null, contextId: "ctx-1", parts: [{ kind: "text", text: `m${i}` }], summary: "s" },
        { messageId: `m-${i}`, peer: { ...PEER, sessionName: "remote" }, now: i + 1 },
      ),
    });
  }
  return state;
}

function seqs(): number[] {
  const raw = new Database(busDbPath(abDir), { readonly: true });
  try {
    return (raw.query("SELECT seq FROM bus_messages ORDER BY seq").all() as { seq: number }[]).map((r) => r.seq);
  } finally {
    raw.close();
  }
}

test("appending at the cap rewrites the rows that changed, not the whole store", () => {
  // `seq` is AUTOINCREMENT, so a row that kept its seq was never deleted and
  // re-inserted. That is the only way to tell the difference from outside: the
  // store's contract is a whole-scope replace either way, and both paths leave
  // exactly the same records behind. What differs is a few hundred writes per
  // message on the loop that serves every PTY on the machine.
  saveMessageLog(abDir, "p1", "s1", logOf(MAX_LOG_ENTRIES));
  const before = seqs();
  expect(before).toHaveLength(MAX_LOG_ENTRIES);

  saveMessageLog(abDir, "p1", "s1", logOf(MAX_LOG_ENTRIES + 1));
  const after = seqs();

  expect(after).toHaveLength(MAX_LOG_ENTRIES);
  // The oldest row is gone, every survivor kept its identity, and exactly one
  // row is new.
  expect(after.slice(0, -1)).toEqual(before.slice(1));
  expect(after[after.length - 1]).toBeGreaterThan(before[before.length - 1]!);

  expect(loadMessageLog(abDir, "p1", "s1").entries.map((e) => e.envelope.messageId))
    .toEqual(Array.from({ length: MAX_LOG_ENTRIES }, (_, i) => `m-${i + 1}`));
});

test("a record removed from the middle does not survive the write", () => {
  // The case the fast path must never take: it can only skip rewriting rows it
  // has proved are the ones wanted, and a hole in the middle is not provable —
  // so the whole scope goes. A delivery line that survived its own removal is
  // one the agent is handed twice.
  saveDeliveries(abDir, "p1", enqueueLine(
    enqueueLine(
      enqueueLine(emptyDeliveries(), { id: "l-1", sessionId: "s1", kind: "wake", text: "a", queuedAt: 1 }),
      { id: "l-2", sessionId: "s1", kind: "wake", text: "b", queuedAt: 2 },
    ),
    { id: "l-3", sessionId: "s1", kind: "wake", text: "c", queuedAt: 3 },
  ));

  const kept = loadDeliveries(abDir, "p1");
  saveDeliveries(abDir, "p1", { ...kept, lines: kept.lines.filter((l) => l.id !== "l-2") });

  expect(loadDeliveries(abDir, "p1").lines.map((l) => l.id)).toEqual(["l-1", "l-3"]);
});

test("nothing that only reads or reclaims brings the database into being", () => {
  // Every session delete on the machine runs the reclaim, and most sessions
  // never send a bus message. Creating a database to delete nothing from is not
  // free: each file under the state dir is a handle another process can be
  // holding when the next rename lands there, and this suite lost two runs to
  // exactly that — in tests that never touched the bus.
  expect(loadHeld(abDir, "p1", "s1").held).toEqual([]);
  expect(loadDeliveries(abDir, "p1").lines).toEqual([]);
  expect(loadMessageLog(abDir, "p1", "s1").entries).toEqual([]);
  expect(listSessionBusSessions(abDir)).toEqual([]);
  removeSessionBusProject(abDir, "p1");
  removeSessionBusSession(abDir, "p1", "s1");

  expect(existsSync(busDbPath(abDir))).toBe(false);

  // And a write still creates it, or none of the above would mean anything.
  saveHeld(abDir, "p1", "s1", holdMessage(emptyHeld(), {
    messageId: "h-1", contextId: "c", role: "lead",
    to: { machineId: "m", projectId: "p", sessionId: "s" },
    frame: { type: "session-bus:message" }, heldAt: 1,
  }));
  expect(existsSync(busDbPath(abDir))).toBe(true);
});
