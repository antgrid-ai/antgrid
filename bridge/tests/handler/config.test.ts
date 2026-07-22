// bridge/tests/handler/config.test.ts
import { test, expect } from "bun:test";
import { mkdtempSync, writeFileSync, mkdirSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  loadHandlerConfig, saveHandlerConfig, DEFAULT_HANDLER_CONFIG, appendActivity,
} from "../../src/handler/config";

function tmpAbDir(): string { return mkdtempSync(join(tmpdir(), "ab-handler-")); }

test("missing config returns the watchdog default", () => {
  expect(loadHandlerConfig(tmpAbDir(), "p1")).toEqual(DEFAULT_HANDLER_CONFIG);
  expect(DEFAULT_HANDLER_CONFIG.enabled).toBe(false);
  expect(DEFAULT_HANDLER_CONFIG.template).toBe("watchdog");
});

test("save then load round-trips", () => {
  const ab = tmpAbDir();
  saveHandlerConfig(ab, "p1", { version: 1, enabled: true, template: "closer", model: "haiku" });
  expect(loadHandlerConfig(ab, "p1")).toEqual({ version: 1, enabled: true, template: "closer", model: "haiku" });
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
