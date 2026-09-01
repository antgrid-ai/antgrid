// bridge/tests/handler/config.test.ts
import { test, expect, describe, it } from "bun:test";
import { mkdtempSync, writeFileSync, mkdirSync, readFileSync, readdirSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  loadHandlerConfig, DEFAULT_HANDLER_CONFIG, appendActivity, ACTIVITY_LOG_MAX_BYTES,
} from "../../src/handler/config";

function tmpAbDir(): string { return mkdtempSync(join(tmpdir(), "ab-handler-")); }

test("missing config returns the v2 default", () => {
  expect(loadHandlerConfig(tmpAbDir(), "p1")).toEqual(DEFAULT_HANDLER_CONFIG);
  expect(DEFAULT_HANDLER_CONFIG.defaultNotifyOnly).toBe(false);
});

test("corrupt config falls back to default, does not throw", () => {
  const ab = tmpAbDir();
  const dir = join(ab, "agents", "p1");
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, "handler-config.json"), "{ not json", "utf8");
  expect(loadHandlerConfig(ab, "p1")).toEqual(DEFAULT_HANDLER_CONFIG);
});

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

describe("config v2", () => {
  it("defaults to v2 with defaultNotifyOnly false", () => {
    expect(DEFAULT_HANDLER_CONFIG).toEqual({ version: 2, defaultNotifyOnly: false });
  });
  it("migrates a v1 config file, dropping enabled/template/model", () => {
    const dir = mkdtempSync(join(tmpdir(), "handler-config-"));
    const projectDir = join(dir, "agents", "proj");
    mkdirSync(projectDir, { recursive: true });
    writeFileSync(
      join(projectDir, "handler-config.json"),
      JSON.stringify({ version: 1, enabled: true, template: "watchdog", model: "opus" }),
    );
    expect(loadHandlerConfig(dir, "proj")).toEqual({ version: 2, defaultNotifyOnly: false });
  });
  it("a stored v2 file with legacy tool/model keys still parses (extra keys ignored)", () => {
    const dir = mkdtempSync(join(tmpdir(), "handler-config-"));
    const projectDir = join(dir, "agents", "proj");
    mkdirSync(projectDir, { recursive: true });
    writeFileSync(
      join(projectDir, "handler-config.json"),
      JSON.stringify({ version: 2, tool: "codex", model: "gpt-5.3", defaultNotifyOnly: true }),
    );
    // Zod objects strip unknown keys by default — the legacy overrides just vanish.
    expect(loadHandlerConfig(dir, "proj")).toEqual({ version: 2, defaultNotifyOnly: true });
  });
  it("falls back to default on corrupt json", () => {
    const abDir = mkdtempSync(join(tmpdir(), "ab-cfg-"));
    const dir = join(abDir, "agents", "proj");
    mkdirSync(dir, { recursive: true });
    writeFileSync(join(dir, "handler-config.json"), "not json", "utf8");
    expect(loadHandlerConfig(abDir, "proj")).toEqual(DEFAULT_HANDLER_CONFIG);
  });
});
