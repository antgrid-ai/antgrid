import { expect, test } from "bun:test";
import {
  removeManagedCursorHookEntries,
  replaceManagedCursorHookEntries,
} from "../src/agents/cursor-agent/global-hooks";

test("replaces legacy and stale Antgrid commands while preserving user hooks", () => {
  const current = {
    sessionStart: '"C:/Program Files/Antgrid/antgrid-bridge.exe" "hook" "cursor" "session-start"',
    stop: '"C:/Program Files/Antgrid/antgrid-bridge.exe" "hook" "cursor" "stop"',
  };
  const data = {
    version: 1,
    hooks: {
      sessionStart: [
        { command: 'node "C:/old/plugin/cursor/post-title.js"' },
        { command: '"D:/old/antgrid-bridge.exe" "hook" "cursor" "session-start"' },
        { command: "echo mine" },
      ],
      stop: [
        { command: 'node.exe "C:/old/plugin/cursor/post-notify.js"' },
        { command: "echo stop" },
      ],
    },
  };

  const replaced = replaceManagedCursorHookEntries(data, current);

  expect(replaced!.hooks.sessionStart).toEqual([
    { command: "echo mine" },
    { command: current.sessionStart, timeout: 5 },
  ]);
  expect(replaced!.hooks.stop).toEqual([
    { command: "echo stop" },
    { command: current.stop, timeout: 5 },
  ]);
  expect(JSON.stringify(replaced)).not.toMatch(/\bnode(?:\.exe)?\b/i);
});

test("recognizes a stale custom-named binary via its token despite a spaced install path", () => {
  // Custom binary name (not antgrid-bridge / index.ts), so recognition falls to
  // binaryToken. The quoted `C:/Program Files/...` path must be read whole — a
  // regex that stops at the first space yields token "Program" and leaks the
  // stale entry.
  const current = {
    sessionStart: '"C:/Program Files/Antgrid/antgrid.exe" "hook" "cursor" "session-start"',
    stop: '"C:/Program Files/Antgrid/antgrid.exe" "hook" "cursor" "stop"',
  };
  const data = {
    hooks: {
      sessionStart: [
        { command: '"D:/relocated/antgrid.exe" "hook" "cursor" "session-start"' },
        { command: "echo mine" },
      ],
      stop: [{ command: '"D:/relocated/antgrid.exe" "hook" "cursor" "stop"' }],
    },
  };

  const replaced = replaceManagedCursorHookEntries(data, current);

  expect(replaced!.hooks.sessionStart).toEqual([
    { command: "echo mine" },
    { command: current.sessionStart, timeout: 5 },
  ]);
  expect(replaced!.hooks.stop).toEqual([{ command: current.stop, timeout: 5 }]);
});

test("replaces junk entries minted by pre-isolation test runs (Bun.main = test file)", () => {
  const current = {
    sessionStart: '"C:/Program Files/Antgrid/antgrid-bridge.exe" "hook" "cursor" "session-start"',
    stop: '"C:/Program Files/Antgrid/antgrid-bridge.exe" "hook" "cursor" "stop"',
  };
  const data = {
    hooks: {
      sessionStart: [
        {
          command:
            '"C:/Users/dev/.bun/bin/bun.exe" "C:/repo/bridge/tests/session-manager.test.ts" "hook" "cursor" "session-start"',
        },
        { command: "echo mine" },
      ],
    },
  };

  const replaced = replaceManagedCursorHookEntries(data, current);

  expect(replaced!.hooks.sessionStart).toEqual([
    { command: "echo mine" },
    { command: current.sessionStart, timeout: 5 },
  ]);
});

test("does not claim a user's own .test.ts hook script as bridge-managed", () => {
  const current = {
    sessionStart: '"/app/antgrid-bridge" "hook" "cursor" "session-start"',
    stop: '"/app/antgrid-bridge" "hook" "cursor" "stop"',
  };
  // Every junk-matcher conjunct except the argv tail comes free from the
  // path: "hooks/" supplies "hook", ".cursor" supplies "cursor", "on-stop"
  // supplies the event word, and the extension supplies ".test.ts".
  const userHook = "bun /home/me/.cursor/hooks/on-stop.test.ts";
  const data = { hooks: { stop: [{ command: userHook }] } };

  const replaced = replaceManagedCursorHookEntries(data, current);

  expect(replaced!.hooks.stop).toEqual([
    { command: userHook },
    { command: current.stop, timeout: 5 },
  ]);
});

test("returns null when current managed hooks are already exact", () => {
  const commands = {
    sessionStart: '"/app/antgrid-bridge" "hook" "cursor" "session-start"',
    stop: '"/app/antgrid-bridge" "hook" "cursor" "stop"',
  };
  const data = {
    hooks: {
      sessionStart: [{ command: commands.sessionStart, timeout: 5 }],
      stop: [{ command: commands.stop, timeout: 5 }],
    },
  };
  expect(replaceManagedCursorHookEntries(data, commands)).toBeNull();
});

test("uninstall removes current and legacy managed commands only", () => {
  const commands = {
    sessionStart: '"/app/antgrid-bridge" "hook" "cursor" "session-start"',
    stop: '"/app/antgrid-bridge" "hook" "cursor" "stop"',
  };
  const data = {
    hooks: {
      sessionStart: [
        { command: commands.sessionStart, timeout: 5 },
        { command: 'node "/old/plugin/cursor/post-title.js"' },
        { command: "echo mine" },
      ],
      stop: [{ command: commands.stop, timeout: 5 }],
    },
  };
  expect(removeManagedCursorHookEntries(data, commands)).toEqual({
    hooks: { sessionStart: [{ command: "echo mine" }] },
  });
});
