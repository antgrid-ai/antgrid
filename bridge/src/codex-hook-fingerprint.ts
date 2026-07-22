import { createHash } from "node:crypto";

// Mirrors codex's hook trust fingerprint so we can pre-seed trusted_hash via -c.
// SOURCE OF TRUTH (codex-rs, pinned — see docs): fingerprint.rs version_for_toml
// + canonical_json, hook_config.rs MatcherGroup/HookHandlerConfig, lib.rs
// hook_event_key_label/hook_key. ANY codex change to these silently breaks the
// hash -> hooks go Untrusted -> skipped. The /hook-alive probe (Task 8) is the
// drift guard.

export const EVENT_LABELS = {
  PermissionRequest: "permission_request",
  Stop: "stop",
  SessionStart: "session_start",
} as const;

// Recursively sort object keys (codex canonical_json) and emit compact JSON
// (serde_json::to_vec default = no whitespace). Arrays keep order.
function canonicalize(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(canonicalize);
  if (value && typeof value === "object") {
    const out: Record<string, unknown> = {};
    for (const key of Object.keys(value as Record<string, unknown>).sort()) {
      out[key] = canonicalize((value as Record<string, unknown>)[key]);
    }
    return out;
  }
  return value;
}

export interface CommandHookHashInput {
  eventLabel: string;
  matcher?: string;
  command: string;
  timeoutSec: number;
  async?: boolean;
  statusMessage?: string;
}

export function computeCommandHookHash(input: CommandHookHashInput): string {
  // Normalized handler: commandWindows dropped, timeout always present, async
  // always present, statusMessage only if set. (codex normalizes before hashing.)
  const handler: Record<string, unknown> = {
    type: "command",
    command: input.command,
    timeout: input.timeoutSec,
    async: input.async ?? false,
  };
  if (input.statusMessage !== undefined) handler.statusMessage = input.statusMessage;

  // NormalizedHookIdentity = { event_name, ...flatten(MatcherGroup) }.
  // MatcherGroup.matcher omitted when None (toml skips None); hooks = [handler].
  const identity: Record<string, unknown> = {
    event_name: input.eventLabel,
    hooks: [handler],
  };
  if (input.matcher !== undefined) identity.matcher = input.matcher;

  const json = JSON.stringify(canonicalize(identity));
  return "sha256:" + createHash("sha256").update(json, "utf8").digest("hex");
}

// SessionFlags synthetic source path — mirrors codex discovery.rs:384:
//   ConfigLayerSource::SessionFlags => synthetic_layer_path("<session-flags>/config.toml")
// synthetic_layer_path resolves the relative path against base "C:\" (win) or "/" (unix),
// so display() yields "C:\<session-flags>\config.toml" on Windows.
// Verified 2026-06-26 via cargo test print_session_flags_keysource (value matched exactly).
export function sessionFlagsKeySource(): string {
  return process.platform === "win32"
    ? "C:\\<session-flags>\\config.toml"
    : "/<session-flags>/config.toml";
}

export function hookStateKey(eventLabel: string, group: number, handler: number): string {
  return `${sessionFlagsKeySource()}:${eventLabel}:${group}:${handler}`;
}
