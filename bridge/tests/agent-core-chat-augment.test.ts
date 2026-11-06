// Verifies the shared helper maps a chat slot id + live api port into the
// correlation env the bundled title plugins require.
import { test, expect } from "bun:test";
import { existsSync, mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { buildChatSpawnAugment } from "../src/agent-core";
import { setMemoryLaunchGate } from "../src/agent-host";

test("chat spawn augment stamps slot id and api port for claude", () => {
  const abDir = mkdtempSync(join(tmpdir(), "ab-chat-augment-"));
  const aug = buildChatSpawnAugment("claude-code", "slot-123", 8790, abDir);
  expect(aug.env.ANTGRID_TERMINAL_ID).toBe("slot-123");
  expect(aug.env.ANTGRID_API_PORT).toBe("8790");
  expect(aug.args).toContain("--plugin-dir");
});

test("chat spawn augment adds MCP without replacing native settings", () => {
  const abDir = mkdtempSync(join(tmpdir(), "ab-chat-augment-"));
  const aug = buildChatSpawnAugment("claude-code", "slot-123", 8790, abDir);
  expect(aug.args.some((arg) => arg.startsWith("--mcp-config="))).toBe(true);
  expect(aug.args).not.toContain("--strict-mcp-config");
  expect(existsSync(join(abDir, "mcp"))).toBe(true);
});

test("omits api port when server not yet up", () => {
  const aug = buildChatSpawnAugment("codex", "slot-9", null);
  expect(aug.env.ANTGRID_TERMINAL_ID).toBe("slot-9");
  expect("ANTGRID_API_PORT" in aug.env).toBe(false);
});

test("reports the Memory server as withheld while the launch gate is closed", () => {
  const abDir = mkdtempSync(join(tmpdir(), "ab-chat-augment-"));
  const restore = setMemoryLaunchGate(() => false);
  try {
    const aug = buildChatSpawnAugment("claude-code", "slot-1", 8790, abDir);
    expect(aug.memoryWithheld).toBe(true);
    expect(aug.env.ANTGRID_MEMORY_MCP).toBeUndefined();
  } finally {
    restore();
  }
});

test("reports the Memory server as registered when the launch gate is open", () => {
  const abDir = mkdtempSync(join(tmpdir(), "ab-chat-augment-"));
  const restore = setMemoryLaunchGate(() => true);
  try {
    const aug = buildChatSpawnAugment("claude-code", "slot-1", 8790, abDir);
    expect(aug.memoryWithheld).toBe(false);
    expect(aug.env.ANTGRID_MEMORY_MCP).toBe("1");
  } finally {
    restore();
  }
});
