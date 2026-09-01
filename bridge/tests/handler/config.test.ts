// bridge/tests/handler/config.test.ts
import { test, expect, describe, it } from "bun:test";
import { mkdtempSync, writeFileSync, mkdirSync, readFileSync, readdirSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { appendActivity, ACTIVITY_LOG_MAX_BYTES } from "../../src/handler/config";

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
