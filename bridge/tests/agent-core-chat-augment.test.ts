// Verifies the shared helper maps a chat slot id + live api port into the
// correlation env the bundled title plugins require.
import { test, expect } from "bun:test";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { buildChatSpawnAugment } from "../src/agent-core";

test("chat spawn augment stamps slot id and api port for claude", () => {
  const abDir = mkdtempSync(join(tmpdir(), "ab-chat-augment-"));
  const aug = buildChatSpawnAugment("claude-code", "slot-123", 8790, abDir);
  expect(aug.env.ANTGRID_TERMINAL_ID).toBe("slot-123");
  expect(aug.env.ANTGRID_API_PORT).toBe("8790");
  expect(aug.args).toContain("--plugin-dir");
});

test("omits api port when server not yet up", () => {
  const aug = buildChatSpawnAugment("codex", "slot-9", null);
  expect(aug.env.ANTGRID_TERMINAL_ID).toBe("slot-9");
  expect("ANTGRID_API_PORT" in aug.env).toBe(false);
});
