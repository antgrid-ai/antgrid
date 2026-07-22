import { describe, expect, test } from "bun:test";
import { buildGeminiHooks, composeGeminiDefaults } from "../src/gemini-defaults";

const HOOK_COMMAND = { binary: "/opt/Antgrid App/antgrid-bridge", preargs: ["hook"] };

describe("gemini-defaults", () => {
  test("emits event-specific bridge hooks without Node", () => {
    const h = buildGeminiHooks(HOOK_COMMAND, "gemini");
    for (const ev of ["SessionStart", "Stop"] as const) {
      const cmd = h[ev][0].hooks[0];
      expect(cmd.type).toBe("command");
      expect(cmd.command).toContain("antgrid-bridge");
      expect(cmd.command).toContain("gemini");
      expect(cmd.command).toContain(ev === "SessionStart" ? "session-start" : "after-agent");
      // gemini/qwen turn-end hook is keyed `Stop`, not `AfterAgent` — see gemini-defaults.ts.
      expect(cmd.command).not.toMatch(/\bnode(?:\.exe)?\b/i);
    }
  });

  test("qwen label is threaded into the command", () => {
    const h = buildGeminiHooks(HOOK_COMMAND, "qwen");
    expect(h.SessionStart[0].hooks[0].command).toContain("qwen");
  });

  test("composeGeminiDefaults merges general and hooks", () => {
    const merged = composeGeminiDefaults({
      general: { enableNotifications: true, notificationMethod: "osc777" },
      hooks: buildGeminiHooks(HOOK_COMMAND, "gemini"),
    });
    expect((merged as any).general.enableNotifications).toBe(true);
    expect((merged as any).hooks.Stop).toBeDefined();
  });

  test("composeGeminiDefaults omits general when not supplied", () => {
    const merged = composeGeminiDefaults({ hooks: buildGeminiHooks(HOOK_COMMAND, "qwen") });
    expect((merged as any).general).toBeUndefined();
    expect((merged as any).hooks).toBeDefined();
  });
});
