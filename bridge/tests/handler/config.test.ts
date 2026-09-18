// bridge/tests/handler/config.test.ts
import { test, expect, describe, it } from "bun:test";
import { mkdtempSync, writeFileSync, mkdirSync, readFileSync, readdirSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { appendActivity, readRecentActivity, ACTIVITY_LOG_MAX_BYTES } from "../../src/handler/config";
import type { ActivityRecord } from "../../src/handler/config";

function tmpAbDir(): string { return mkdtempSync(join(tmpdir(), "ab-handler-")); }

test("appendActivity writes one JSONL line per record", () => {
  const ab = tmpAbDir();
  appendActivity(ab, "p1", { recordId: "r1", at: 1, terminalId: "t", decision: "handle", reason: "ok" });
  appendActivity(ab, "p1", { recordId: "r2", at: 2, terminalId: "t", decision: "escalate", reason: "blocked" });
  const raw = readFileSync(join(ab, "agents", "p1", "handler-activity.jsonl"), "utf8");
  const lines = raw.trim().split("\n");
  expect(lines).toHaveLength(2);
  expect(JSON.parse(lines[1]).decision).toBe("escalate");
});

describe("activity log rotation", () => {
  const record = (recordId: string) => (
    { recordId, at: 1, terminalId: "t", decision: "handle", reason: "ok" } as const
  );

  it("leaves a log under the cap alone", () => {
    // The invariant that matters: rotation must never read the file it appends to.
    // A "keep the last N records" bound would turn an O(1) append into a full-file
    // read on every judge decision.
    const ab = tmpAbDir();
    appendActivity(ab, "p1", record("r1"));
    appendActivity(ab, "p1", record("r2"));
    expect(existsSync(join(ab, "agents", "p1", "handler-activity.1.jsonl"))).toBe(false);
  });

  it("rolls the log once it reaches the cap", () => {
    const ab = tmpAbDir();
    const dir = join(ab, "agents", "p1");
    mkdirSync(dir, { recursive: true });
    writeFileSync(join(dir, "handler-activity.jsonl"), "x".repeat(ACTIVITY_LOG_MAX_BYTES), "utf8");
    appendActivity(ab, "p1", record("r1"));
    const live = readFileSync(join(dir, "handler-activity.jsonl"), "utf8").trim().split("\n");
    expect(live).toHaveLength(1);
    expect(JSON.parse(live[0]!).recordId).toBe("r1");
    expect(readFileSync(join(dir, "handler-activity.1.jsonl"), "utf8")).toBe("x".repeat(ACTIVITY_LOG_MAX_BYTES));
  });

  it("a second roll replaces the rolled generation rather than accumulating", () => {
    const ab = tmpAbDir();
    const dir = join(ab, "agents", "p1");
    mkdirSync(dir, { recursive: true });
    writeFileSync(join(dir, "handler-activity.jsonl"), "x".repeat(ACTIVITY_LOG_MAX_BYTES), "utf8");
    appendActivity(ab, "p1", record("r1"));
    writeFileSync(join(dir, "handler-activity.jsonl"), "y".repeat(ACTIVITY_LOG_MAX_BYTES), "utf8");
    appendActivity(ab, "p1", record("r2"));
    expect(readdirSync(dir).sort()).toEqual(["handler-activity.1.jsonl", "handler-activity.jsonl"]);
    expect(readFileSync(join(dir, "handler-activity.1.jsonl"), "utf8")).toBe("y".repeat(ACTIVITY_LOG_MAX_BYTES));
    expect(JSON.parse(readFileSync(join(dir, "handler-activity.jsonl"), "utf8").trim()).recordId).toBe("r2");
  });
});

describe("readRecentActivity", () => {
  const record = (n: number): ActivityRecord => (
    { recordId: `r${n}`, at: n, terminalId: "t", decision: "handle", reason: `reason ${n}` }
  );
  const ids = (recs: ActivityRecord[]) => recs.map((r) => r.recordId);

  function seed(ab: string, count: number, from = 1): void {
    for (let n = from; n < from + count; n++) appendActivity(ab, "p1", record(n));
  }

  it("answers empty for a project whose handler was never armed", () => {
    // The ordinary state of most projects. Throwing here would strand the app
    // on a request it is waiting for an answer to.
    expect(readRecentActivity(tmpAbDir(), "never-armed", 50)).toEqual({ records: [], truncated: false });
  });

  it("returns every record, newest first, when the log is shorter than the limit", () => {
    const ab = tmpAbDir();
    seed(ab, 3);
    const got = readRecentActivity(ab, "p1", 50);
    expect(ids(got.records)).toEqual(["r3", "r2", "r1"]);
    expect(got.truncated).toBe(false);
  });

  it("carries the whole record through unchanged", () => {
    const ab = tmpAbDir();
    appendActivity(ab, "p1", { ...record(1), detail: "the detail" });
    expect(readRecentActivity(ab, "p1", 50).records[0]).toEqual({
      recordId: "r1", at: 1, terminalId: "t", decision: "handle", reason: "reason 1", detail: "the detail",
    });
  });

  it("keeps the newest `limit` and marks the answer truncated", () => {
    const ab = tmpAbDir();
    seed(ab, 10);
    const got = readRecentActivity(ab, "p1", 3);
    expect(ids(got.records)).toEqual(["r10", "r9", "r8"]);
    expect(got.truncated).toBe(true);
  });

  it("reaches into the rolled generation when the live log cannot fill the answer", () => {
    const ab = tmpAbDir();
    const dir = join(ab, "agents", "p1");
    mkdirSync(dir, { recursive: true });
    writeFileSync(join(dir, "handler-activity.1.jsonl"),
      [1, 2, 3].map((n) => JSON.stringify(record(n))).join("\n") + "\n", "utf8");
    seed(ab, 2, 4);
    const got = readRecentActivity(ab, "p1", 50);
    expect(ids(got.records)).toEqual(["r5", "r4", "r3", "r2", "r1"]);
    expect(got.truncated).toBe(false);
  });

  it("reports truncated when a rolled generation exists it did not need to read", () => {
    // Older rows are unreachable whether or not this answer went looking for
    // them, so a full-looking page must still say the feed is shortened.
    const ab = tmpAbDir();
    const dir = join(ab, "agents", "p1");
    mkdirSync(dir, { recursive: true });
    writeFileSync(join(dir, "handler-activity.1.jsonl"), `${JSON.stringify(record(0))}\n`, "utf8");
    seed(ab, 3);
    const got = readRecentActivity(ab, "p1", 3);
    expect(ids(got.records)).toEqual(["r3", "r2", "r1"]);
    expect(got.truncated).toBe(true);
  });

  it("drops a torn trailing line rather than failing the read", () => {
    // An append can land between this read's stat and its last byte, so a half
    // written final record is normal traffic, not corruption.
    const ab = tmpAbDir();
    seed(ab, 2);
    const path = join(ab, "agents", "p1", "handler-activity.jsonl");
    writeFileSync(path, `${readFileSync(path, "utf8")}{"recordId":"r3","at":3,"term`, "utf8");
    expect(ids(readRecentActivity(ab, "p1", 50).records)).toEqual(["r2", "r1"]);
  });

  it("drops a line that parses but is not a record", () => {
    const ab = tmpAbDir();
    const dir = join(ab, "agents", "p1");
    mkdirSync(dir, { recursive: true });
    writeFileSync(join(dir, "handler-activity.jsonl"),
      `null\n[]\n{"recordId":"r1"}\n${JSON.stringify(record(2))}\n`, "utf8");
    expect(ids(readRecentActivity(ab, "p1", 50).records)).toEqual(["r2"]);
  });

  it("hands over a decision kind this build does not know", () => {
    // The log is the only durable account of a finished session. A row written
    // by a newer build must still reach the feed, which renders an unknown kind
    // as its raw reason rather than dropping it.
    const ab = tmpAbDir();
    const dir = join(ab, "agents", "p1");
    mkdirSync(dir, { recursive: true });
    writeFileSync(join(dir, "handler-activity.jsonl"),
      `${JSON.stringify({ ...record(1), decision: "invented_later" })}\n`, "utf8");
    const kind: string = readRecentActivity(ab, "p1", 50).records[0]!.decision;
    expect(kind).toBe("invented_later");
  });

  it("reads only the tail of a log past the read window", () => {
    // A log at the rotation cap must not be read whole. What matters is that
    // the newest records come back and the answer admits it is partial.
    const ab = tmpAbDir();
    const dir = join(ab, "agents", "p1");
    mkdirSync(dir, { recursive: true });
    const filler = `${JSON.stringify({ ...record(0), reason: "x".repeat(400) })}\n`;
    const lines = [filler.repeat(Math.ceil(ACTIVITY_LOG_MAX_BYTES / filler.length)),
      `${JSON.stringify(record(1))}\n`, `${JSON.stringify(record(2))}\n`].join("");
    writeFileSync(join(dir, "handler-activity.jsonl"), lines, "utf8");
    const got = readRecentActivity(ab, "p1", 2);
    expect(ids(got.records)).toEqual(["r2", "r1"]);
    expect(got.truncated).toBe(true);
  });

  it("returns nothing for a non-positive limit", () => {
    const ab = tmpAbDir();
    seed(ab, 3);
    expect(readRecentActivity(ab, "p1", 0)).toEqual({ records: [], truncated: false });
  });
});
