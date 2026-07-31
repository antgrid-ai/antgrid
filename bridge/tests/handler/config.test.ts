// bridge/tests/handler/config.test.ts
import { test, expect, describe, it } from "bun:test";
import { mkdtempSync, writeFileSync, mkdirSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  loadHandlerConfig, DEFAULT_HANDLER_CONFIG, appendActivity,
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
