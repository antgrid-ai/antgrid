// bridge/tests/handler/templates.test.ts
import { test, expect } from "bun:test";
import { TEMPLATES } from "../../src/handler/templates";

test("watchdog never auto-replies", () => {
  expect(TEMPLATES.watchdog.autoReplyAllowed).toBe(false);
});

test("closer and autopilot may auto-reply", () => {
  expect(TEMPLATES.closer.autoReplyAllowed).toBe(true);
  expect(TEMPLATES.autopilot.autoReplyAllowed).toBe(true);
});

test("every template carries non-empty judge guidance", () => {
  for (const t of ["watchdog", "closer", "autopilot"] as const) {
    expect(TEMPLATES[t].judgeGuidance.length).toBeGreaterThan(0);
  }
});
