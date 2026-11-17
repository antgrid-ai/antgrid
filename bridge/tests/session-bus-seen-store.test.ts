// The recipient's memory of what it has already decided: a resend is answered
// from here rather than applied again, so what this store keeps and what it
// forgets decides whether a duplicate can ever be applied twice.
import { afterEach, beforeEach, expect, test } from "bun:test";
import { Database } from "bun:sqlite";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { setLogLevel } from "../src/logger";
import { busDbPath, resetBusDbAnnouncements } from "../src/session-bus/bus-db";
import { BUS_MAX_PLAINTEXT_BYTES } from "antgrid-wire";
import { MAX_BUS_SEEN } from "../src/session-bus/constants";
import { BUS_CLOCK_SKEW_MS } from "../src/session-bus/seal";
import { openSeenStore } from "../src/session-bus/seen-store";

setLogLevel("error");

let abDir: string;

beforeEach(() => {
  abDir = mkdtempSync(join(tmpdir(), "antgrid-bus-seen-"));
  resetBusDbAnnouncements();
});

afterEach(() => {
  try { rmSync(abDir, { recursive: true, force: true }); } catch { /* Windows handle */ }
});

const rows = (): { from_machine: string; id: string }[] => {
  const db = new Database(busDbPath(abDir), { readonly: true });
  try {
    return db.query("SELECT from_machine, id FROM bus_seen ORDER BY at, id").all() as { from_machine: string; id: string }[];
  } finally {
    db.close();
  }
};

test("a recorded verdict is read back by sender and id, and by nothing else", () => {
  const store = openSeenStore(abDir, () => 1_000);
  expect(store.get("m1", "i1")).toBeNull();

  store.record("m1", "i1", "applied", undefined, 10_000);
  store.record("m1", "i2", "refused", "UNKNOWN_PEER", 10_000);
  store.record("m1", "i3", "applied", undefined, 10_000, "an answer");

  expect(store.get("m1", "i1")).toEqual({ outcome: "applied" });
  expect(store.get("m1", "i2")).toEqual({ outcome: "refused", code: "UNKNOWN_PEER" });
  expect(store.get("m1", "i3")).toEqual({ outcome: "applied", response: "an answer" });
  // The key is the pair: the same id from another machine is a different message.
  expect(store.get("m2", "i1")).toBeNull();
});

test("recording again replaces the verdict instead of adding a row", () => {
  const store = openSeenStore(abDir, () => 1_000);
  store.record("m1", "i1", "refused", "UNKNOWN_PEER", 10_000);
  store.record("m1", "i1", "applied", undefined, 10_000);
  expect(store.get("m1", "i1")).toEqual({ outcome: "applied" });
  expect(rows()).toHaveLength(1);
});

test("a cached response is capped at the plaintext bound", () => {
  const store = openSeenStore(abDir, () => 1_000);
  store.record("m1", "i1", "applied", undefined, 10_000, "x".repeat(BUS_MAX_PLAINTEXT_BYTES * 2));
  expect(store.get("m1", "i1")!.response!.length).toBeLessThanOrEqual(BUS_MAX_PLAINTEXT_BYTES);
});

test("a row is dropped once its message could no longer be accepted, and not before", () => {
  let now = 1_000;
  const store = openSeenStore(abDir, () => now);
  store.record("m1", "old", "applied", undefined, 2_000);
  store.record("m1", "live", "applied", undefined, 2_000_000_000);

  // Past expiry plus the skew a clock may legitimately be off by: a resend is
  // refused as stale by then, so remembering it any longer buys nothing.
  now = 2_000 + BUS_CLOCK_SKEW_MS + 1;
  for (let i = 0; i < 100; i++) store.record("m2", `filler-${i}`, "applied", undefined, 2_000_000_000);

  const ids = rows().map((r) => r.id);
  expect(ids).not.toContain("old");
  expect(ids).toContain("live");
});

test("the table is held to its cap by dropping the oldest verdicts", () => {
  let now = 100_000;
  const store = openSeenStore(abDir, () => now++);
  store.record("m1", "created", "applied", undefined, 2_000_000_000);
  // Seeded in one transaction: filling the cap through `record` is the same
  // statement made ten thousand times slower.
  const raw = new Database(busDbPath(abDir));
  try {
    raw.transaction(() => {
      const insert = raw.query("INSERT INTO bus_seen (from_machine, id, at, expires_at, outcome) VALUES ('m1', ?, ?, 2000000000, 'applied')");
      for (let i = 0; i < MAX_BUS_SEEN + 150; i++) insert.run(`i-${i}`, 10 + i);
    })();
  } finally {
    raw.close();
  }

  for (let i = 0; i < 99; i++) store.record("m2", `fresh-${i}`, "applied", undefined, 2_000_000_000);

  const ids = rows().map((r) => r.id);
  expect(ids.length).toBeLessThanOrEqual(MAX_BUS_SEEN);
  expect(ids).not.toContain("i-0");
  expect(ids).toContain("fresh-98");
});
