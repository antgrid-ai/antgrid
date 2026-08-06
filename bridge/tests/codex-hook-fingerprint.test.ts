import { test, expect } from "bun:test";
import { createHash } from "node:crypto";
import { computeCommandHookHash, hookStateKey, EVENT_LABELS } from "../src/agents/codex/hook-fingerprint";

// Re-derive the expected hash independently from the documented algorithm:
// canonical compact JSON (sorted keys) of the normalized identity -> sha256.
function expected(eventLabel: string, command: string, timeoutSec: number) {
  const identity = {
    event_name: eventLabel,
    hooks: [{ async: false, command, timeout: timeoutSec, type: "command" }],
  };
  const json = JSON.stringify(identity); // keys already in sorted order here
  return "sha256:" + createHash("sha256").update(json, "utf8").digest("hex");
}

test("hash matches canonical-json sha256 for a Stop hook", () => {
  const cmd = "node /tmp/notify-hook.js task_complete";
  expect(computeCommandHookHash({ eventLabel: "stop", command: cmd, timeoutSec: 600 }))
    .toBe(expected("stop", cmd, 600));
});

test("state key format", () => {
  expect(hookStateKey("permission_request", 0, 0))
    .toMatch(/config\.toml:permission_request:0:0$/);
});

test("event labels", () => {
  expect(EVENT_LABELS.PermissionRequest).toBe("permission_request");
  expect(EVENT_LABELS.Stop).toBe("stop");
});

test("matches codex-generated golden (Stop, timeout 600)", () => {
  // Captured via cargo test print_golden against codex-rs (see plan Task 5).
  const GOLDEN = "sha256:90212406732a1d40436833400e267897c2f1992d67a3ce12f480303a256bbb9b";
  expect(
    computeCommandHookHash({ eventLabel: "stop", command: "node /tmp/notify-hook.js task_complete", timeoutSec: 600 }),
  ).toBe(GOLDEN);
});

// Finding 1 — matcher branch coverage
// Independent re-derivation: identity gains a top-level `matcher` field when
// present. Keys must be sorted (event_name < hooks < matcher) so the object
// literal is already ordered alphabetically — no sort call needed here.
test("hash includes matcher in identity when provided", () => {
  const cmd = "node /tmp/notify-hook.js task_complete";
  const timeoutSec = 600;
  const matcher = "^Bash$";
  // Sorted key order: event_name, hooks, matcher
  const identity = {
    event_name: "stop",
    hooks: [{ async: false, command: cmd, timeout: timeoutSec, type: "command" }],
    matcher,
  };
  const expectedHash =
    "sha256:" + createHash("sha256").update(JSON.stringify(identity), "utf8").digest("hex");
  expect(
    computeCommandHookHash({ eventLabel: "stop", command: cmd, timeoutSec, matcher }),
  ).toBe(expectedHash);
});

// Finding 1 — statusMessage branch coverage
// Independent re-derivation: handler gains `statusMessage` when set.
// Sorted key order in handler: async, command, statusMessage, timeout, type.
test("hash includes statusMessage in handler when provided", () => {
  const cmd = "node /tmp/notify-hook.js task_complete";
  const timeoutSec = 600;
  const statusMessage = "running";
  // Sorted key order in handler: async, command, statusMessage, timeout, type
  const identity = {
    event_name: "stop",
    hooks: [{ async: false, command: cmd, statusMessage, timeout: timeoutSec, type: "command" }],
  };
  const expectedHash =
    "sha256:" + createHash("sha256").update(JSON.stringify(identity), "utf8").digest("hex");
  expect(
    computeCommandHookHash({ eventLabel: "stop", command: cmd, timeoutSec, statusMessage }),
  ).toBe(expectedHash);
});

// Finding 2 — verify SessionFlags key_source sentinel against codex-rs reality.
// Captured via `cargo test -p codex-hooks print_session_flags_keysource -- --nocapture`
// run against codex-rs (discovery.rs:384, synthetic_layer_path("<session-flags>/config.toml"),
// base C:\ on Windows / / on unix). Sentinel matched exactly; no correction needed.
test("hookStateKey uses the exact codex SessionFlags key_source string", () => {
  if (process.platform === "win32") {
    // Verified: C:\<session-flags>\config.toml (cargo test output, 2026-06-26)
    expect(hookStateKey("stop", 0, 0)).toBe("C:\\<session-flags>\\config.toml:stop:0:0");
  } else {
    expect(hookStateKey("stop", 0, 0)).toBe("/<session-flags>/config.toml:stop:0:0");
  }
});
