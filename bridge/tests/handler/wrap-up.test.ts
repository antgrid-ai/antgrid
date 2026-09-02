// bridge/tests/handler/wrap-up.test.ts
import { describe, it, expect } from "bun:test";
import { mkdtempSync, mkdirSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  buildWrapUp, wrapUpDetail, wrapUpPushBody,
  MAX_WRAPUP_ITEMS_PER_GROUP, MAX_WRAPUP_TEXT_CHARS, MAX_WRAPUP_DETAIL_CHARS,
  type WrapUpRecord,
} from "../../src/handler/wrap-up";
import { loadWrapUps, pruneWrapUps, saveWrapUps, MAX_STORED_WRAPUPS } from "../../src/handler/wrap-up-store";
import type { InstructionItem, ItemStatus } from "../../src/handler/backlog";

function item(id: string, status: ItemStatus, text = `item ${id}`): InstructionItem {
  return { id, text, status, createdAt: 1 };
}

function build(backlog: InstructionItem[], over: Partial<Parameters<typeof buildWrapUp>[0]> = {}): WrapUpRecord {
  return buildWrapUp({
    wrapUpId: "wrap-1", terminalId: "t1", at: 500, goal: "Migrate auth",
    backlog, blockedReports: [], ...over,
  });
}

describe("wrap-up composition", () => {
  it("groups the outcomes in reporting order and drops the empty ones", () => {
    const rec = build([
      item("a", "skipped"), item("b", "done"), item("c", "failed"), item("d", "done"),
    ]);
    expect(rec.outcomes.map((o) => o.status)).toEqual(["done", "failed", "skipped"]);
    expect(rec.outcomes[0]).toEqual({ status: "done", total: 2, items: ["item b", "item d"] });
  });

  it("samples the items but keeps the true total, so +N more stays derivable", () => {
    const many = Array.from({ length: 11 }, (_, i) => item(`i${i}`, "done"));
    const [done] = build(many).outcomes;
    expect(done!.total).toBe(11);
    expect(done!.items).toHaveLength(MAX_WRAPUP_ITEMS_PER_GROUP);
  });

  // The text is judge- and user-authored, and lands in a persisted JSON string, a
  // notification body and a Flutter Text at once.
  it("escapes control characters in item text rather than stripping them", () => {
    const bell = String.fromCharCode(7);
    const [done] = build([item("a", "done", `ring${bell}ring`)]).outcomes;
    expect(done!.items[0]).not.toContain(bell);
    expect(done!.items[0]).toContain("x07");
  });

  it("clips item text, the goal and the blocked reasons to the wire cap", () => {
    const long = "x".repeat(MAX_WRAPUP_TEXT_CHARS + 80);
    const rec = build([item("a", "done", long)], {
      goal: long, blockedReports: [{ reasoning: long }],
    });
    expect(rec.outcomes[0]!.items[0]!.length).toBe(MAX_WRAPUP_TEXT_CHARS + 1);
    expect(rec.goal.length).toBe(MAX_WRAPUP_TEXT_CHARS + 1);
    expect(rec.blockedReasons[0]!.length).toBe(MAX_WRAPUP_TEXT_CHARS + 1);
  });

  it("freezes the blocked reports, count and reasons, capped", () => {
    const rec = build([item("a", "done")], {
      blockedReports: [1, 2, 3, 4, 5].map((n) => ({ reasoning: `refused ${n}` })),
    });
    expect(rec.blockedTotal).toBe(5);
    expect(rec.blockedReasons).toEqual(["refused 1", "refused 2", "refused 3"]);
  });
});

describe("wrap-up rendering", () => {
  const rec = build([
    item("a", "done"), item("b", "done"),
    item("s1", "skipped"), item("s2", "skipped"), item("s3", "skipped"), item("s4", "skipped"),
  ]);

  it("renders the push sentence the notification has always carried", () => {
    expect(wrapUpPushBody(rec, { openUndos: 0 }))
      .toBe("Handler: done — Migrate auth. Done: item a, item b. Skipped: item s1, item s2, item s3 +1 more");
  });

  it("falls back to a bare completion when the session had no goal", () => {
    expect(wrapUpPushBody(build([item("a", "done")], { goal: "" }), { openUndos: 0 }))
      .toBe("Handler: done — session complete. Done: item a");
  });

  it("re-caps the push at three items even when the record sampled eight", () => {
    const many = build(Array.from({ length: 9 }, (_, i) => item(`i${i}`, "done")));
    expect(many.outcomes[0]!.items).toHaveLength(MAX_WRAPUP_ITEMS_PER_GROUP);
    expect(wrapUpPushBody(many, { openUndos: 0 })).toContain("+6 more");
  });

  // The count is an argument, never a field: an undo taken after the wrap-up, or a
  // re-arm retiring the offers, would make a stored one a lie.
  it("appends the undo clause only from the count passed in", () => {
    expect(wrapUpPushBody(rec, { openUndos: 2 })).toEndWith(". 2 flagged action(s) can still be undone");
    expect(wrapUpPushBody(rec, { openUndos: 0 })).not.toContain("can still be undone");
  });

  // The feed the old push pointed at is not durable — that premise is what this
  // record exists to replace, so the tail goes with it.
  it("names the blocked reports without pointing at the activity feed", () => {
    const blocked = build([item("a", "done")], { blockedReports: [{ reasoning: "refused" }] });
    const body = wrapUpPushBody(blocked, { openUndos: 0 });
    // A count reads the same whether the guard stopped something trivial or the
    // one thing the session existed to do.
    expect(body).toContain("Could not: refused");
    expect(body).not.toContain("activity feed");
    expect(wrapUpDetail(blocked)).not.toContain("activity feed");
  });

  it("caps the push at two named reports and says how many more", () => {
    const blocked = build([item("a", "done")], {
      blockedReports: [{ reasoning: "one" }, { reasoning: "two" }, { reasoning: "three" }],
    });
    const body = wrapUpPushBody(blocked, { openUndos: 0 });
    expect(body).toContain("Could not: one; two +1 more");
  });

  it("offers the undo ahead of the reports, because only the undo expires", () => {
    // OS surfaces truncate the tail. The reports keep on the wrap-up card; the
    // offer to undo is gone once the user stops looking for it, so it goes first.
    const blocked = build([item("a", "done")], { blockedReports: [{ reasoning: "refused" }] });
    const body = wrapUpPushBody(blocked, { openUndos: 2 });
    expect(body.indexOf("can still be undone")).toBeLessThan(body.indexOf("Could not:"));
  });

  it("keeps the goal and the undo count out of the activity row's detail", () => {
    const detail = wrapUpDetail(build([item("a", "done")], { goal: "Migrate auth" }));
    expect(detail).toBe("Done: item a");
    expect(detail).not.toContain("Migrate auth");
    expect(detail).not.toContain("undone");
  });

  it("clips the detail to one row's worth", () => {
    const long = build(Array.from({ length: 8 }, (_, i) => item(`i${i}`, "done", "y".repeat(100))));
    expect(wrapUpDetail(long).length).toBe(MAX_WRAPUP_DETAIL_CHARS + 1);
  });
});

describe("wrap-up store", () => {
  const abDir = () => mkdtempSync(join(tmpdir(), "ab-wrapup-"));
  const rec = (id: string, at: number): WrapUpRecord => ({
    wrapUpId: id, terminalId: "t1", at, goal: "g",
    outcomes: [{ status: "done", total: 1, items: ["item a"] }],
    blockedTotal: 0, blockedReasons: [],
  });

  it("round-trips, and reads as empty before anything is written", () => {
    const dir = abDir();
    expect(loadWrapUps(dir, "proj")).toEqual([]);
    saveWrapUps(dir, "proj", [rec("w1", 1)]);
    expect(loadWrapUps(dir, "proj")).toEqual([rec("w1", 1)]);
  });

  it("reads a malformed file as empty rather than throwing at the caller", () => {
    const dir = abDir();
    mkdirSync(join(dir, "agents", "proj"), { recursive: true });
    const path = join(dir, "agents", "proj", "handler-wrapups.json");
    writeFileSync(path, "{ not json", "utf8");
    expect(loadWrapUps(dir, "proj")).toEqual([]);
    writeFileSync(path, JSON.stringify({ version: 1, entries: [{ wrapUpId: "w" }] }), "utf8");
    expect(loadWrapUps(dir, "proj")).toEqual([]);
  });

  it("keeps the newest records and drops the rest, on disk as in memory", () => {
    const all = Array.from({ length: MAX_STORED_WRAPUPS + 3 }, (_, i) => rec(`w${i}`, i));
    expect(pruneWrapUps(all).map((r) => r.wrapUpId)).toEqual(all.slice(-MAX_STORED_WRAPUPS).map((r) => r.wrapUpId));
    const dir = abDir();
    saveWrapUps(dir, "proj", all);
    expect(loadWrapUps(dir, "proj")).toHaveLength(MAX_STORED_WRAPUPS);
  });
});
