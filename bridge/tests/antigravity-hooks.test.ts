import { test, expect } from "bun:test";
import {
  antigravityScriptPath,
  antigravityHookCommand,
  mergeAntigravityHookEntries,
  ANTIGRAVITY_HOOK_GROUP,
} from "../src/agents/antigravity/global-hooks";

test("antigravityScriptPath resolves under the bundled antigravity plugin dir", () => {
  const p = antigravityScriptPath();
  expect(p.replace(/\\/g, "/")).toMatch(/\/plugin\/antigravity\/post-title\.js$/);
});

test("antigravityHookCommand composes a single UNQUOTED command string (no args array)", () => {
  // Deliberately unquoted — confirmed live that agy's command parser does
  // naive whitespace splitting, not shell-style parsing, so a quoted path
  // arrives at `node` with the literal `"` characters still attached,
  // breaking module resolution (Cannot find module '...\"...\"').
  const cmd = antigravityHookCommand("C:\\p\\post-title.js", "PreInvocation");
  expect(cmd).toBe("node C:\\p\\post-title.js PreInvocation");
});

test("mergeAntigravityHookEntries adds both entries under the named group on an empty file", () => {
  const merged = mergeAntigravityHookEntries({}, [
    { event: "PreInvocation", command: "node a.js PreInvocation" },
    { event: "Stop", command: "node a.js Stop" },
  ]);
  expect(merged).toEqual({
    [ANTIGRAVITY_HOOK_GROUP]: {
      PreInvocation: [{ type: "command", command: "node a.js PreInvocation", timeout: 5 }],
      Stop: [{ type: "command", command: "node a.js Stop", timeout: 5 }],
    },
  });
  // No hooks.json shape produced by this module ever carries a separate "args"
  // array — confirmed live that agy's hook runner ignores it and pipes the
  // payload to bare `node`'s stdin instead, which crashes trying to eval it.
  expect(JSON.stringify(merged)).not.toContain('"args"');
});

test("mergeAntigravityHookEntries is idempotent and preserves other top-level groups", () => {
  const existing = {
    "some-other-plugin": { Stop: [{ type: "command", command: "echo mine", timeout: 5 }] },
    [ANTIGRAVITY_HOOK_GROUP]: {
      PreInvocation: [{ type: "command", command: "node a.js PreInvocation", timeout: 5 }],
    },
  };
  const specs = [
    { event: "PreInvocation" as const, command: "node a.js PreInvocation" },
    { event: "Stop" as const, command: "node a.js Stop" },
  ];
  const first = mergeAntigravityHookEntries(existing, specs);
  expect(first).not.toBeNull();
  expect(first["some-other-plugin"]).toEqual(existing["some-other-plugin"]);
  expect(first[ANTIGRAVITY_HOOK_GROUP].Stop).toEqual([
    { type: "command", command: "node a.js Stop", timeout: 5 },
  ]);

  const second = mergeAntigravityHookEntries(first, specs);
  expect(second).toBeNull(); // both entries already present, no-op
});
