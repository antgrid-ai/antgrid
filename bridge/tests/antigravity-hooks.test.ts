import { test, expect } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  antigravityScriptPath,
  antigravityHookCommand,
  mergeAntigravityHookEntries,
  ANTIGRAVITY_HOOK_GROUP,
} from "../../packages/antgrid-agents/src/agents/antigravity/global-hooks";

test("antigravityScriptPath resolves under the bundled antigravity plugin dir", () => {
  const directory = mkdtempSync(join(tmpdir(), "agent-assets-test-"));
  try {
    const p = antigravityScriptPath(directory);
    expect(p.replace(/\\/g, "/")).toMatch(/\/agent-assets\/[^/]+\/antigravity\/post-title\.js$/);
  } finally { rmSync(directory, { recursive: true, force: true }); }
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

test("mergeAntigravityHookEntries wraps PreToolUse in the matcher/hooks group shape, unlike the flat PreInvocation/Stop arrays", () => {
  const merged = mergeAntigravityHookEntries({}, [
    { event: "PreToolUse", command: "node a.js PreToolUse", matcher: "*" },
  ]);
  expect(merged).toEqual({
    [ANTIGRAVITY_HOOK_GROUP]: {
      PreToolUse: [{ matcher: "*", hooks: [{ type: "command", command: "node a.js PreToolUse", timeout: 5 }] }],
    },
  });
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

test("mergeAntigravityHookEntries treats a PreToolUse matcher change as a real diff, not a no-op", () => {
  const spec = (matcher: string) => [{ event: "PreToolUse" as const, command: "node a.js PreToolUse", matcher }];
  const first = mergeAntigravityHookEntries({}, spec("*"));
  expect(mergeAntigravityHookEntries(first, spec("*"))).toBeNull(); // unchanged → no-op
  const second = mergeAntigravityHookEntries(first, spec("run_command"));
  expect(second[ANTIGRAVITY_HOOK_GROUP].PreToolUse[0].matcher).toBe("run_command");
});

test("asset upgrades replace accumulated managed hooks without mutating other groups", () => {
  const specs = (hash: string) => (["PreInvocation", "Stop"] as const).map((event) => ({
    event, command: antigravityHookCommand(`C:/agent-assets/${hash}/antigravity/post-title.js`, event),
  }));
  const original = mergeAntigravityHookEntries({ personal: { Stop: [{ command: "echo mine" }] } }, specs("old"));
  original[ANTIGRAVITY_HOOK_GROUP].Stop.push({ type: "command", command: "node legacy/post-title.js Stop", timeout: 5 });
  const before = structuredClone(original);
  const upgraded = mergeAntigravityHookEntries(original, specs("new"));
  expect(original).toEqual(before);
  expect(upgraded.personal).toEqual(original.personal);
  for (const { event, command } of specs("new")) {
    expect(upgraded[ANTIGRAVITY_HOOK_GROUP][event]).toEqual([{ type: "command", command, timeout: 5 }]);
  }
  expect(mergeAntigravityHookEntries(upgraded, specs("new"))).toBeNull();
});
