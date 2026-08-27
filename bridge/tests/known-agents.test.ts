import { describe, it, test, expect } from "bun:test";
import { mkdtempSync, readFileSync, existsSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  resolveAgent,
  resolveAgentEnv,
  listKnownTools,
  isOscTitleUnusable,
  titleSourceFor,
} from "../src/known-agents";
import { AGENTS } from "../src/agents/registry";

describe("known-agents registry", () => {
  it("exposes entries for the known coding agents", () => {
    expect(Object.keys(AGENTS).sort()).toEqual(
      [
        "antigravity",
        "claude-code",
        "codex",
        "cursor-agent",
        "github-copilot",
        "kilo",
        "kimi",
        "mistral-vibe",
        "opencode",
      ],
    );
  });

  it("resolves the new agents to their CLI bins", () => {
    expect(resolveAgent("kilo").bin).toBe("kilo");
    expect(resolveAgent("antigravity").bin).toBe("agy");
    expect(resolveAgent("kimi").bin).toBe("kimi");
    expect(resolveAgent("mistral-vibe").bin).toBe("vibe");
  });

  it("resolveAgent returns bin + hookDir for a known tool", () => {
    const r = resolveAgent("claude-code");
    expect(r.bin).toBe("claude");
    expect(r.hookDir).toMatch(/\.claude[/\\]hooks$/);
  });

  it("resolveAgent expands ~ in hookDir", () => {
    const r = resolveAgent("codex");
    expect(r.hookDir?.startsWith("~")).toBe(false);
  });

  it("resolveAgent throws on unknown tool", () => {
    expect(() => resolveAgent("nope")).toThrow(/unknown agent/i);
  });

  it("resolves github-copilot to the copilot bin", () => {
    expect(resolveAgent("github-copilot").bin).toBe("copilot");
  });

  it("lists github-copilot among known tools", () => {
    expect(listKnownTools()).toContain("github-copilot");
  });

  it("resolves antigravity as a plugin-tier registry entry", () => {
    expect(resolveAgent("antigravity").bin).toBe("agy");
    expect(AGENTS["antigravity"].notificationSource).toBe("plugin");
  });

  it("flags antigravity's OSC title as unusable, others as usable", () => {
    expect(isOscTitleUnusable("antigravity")).toBe(true);
    expect(isOscTitleUnusable("claude-code")).toBe(false);
    expect(isOscTitleUnusable("codex")).toBe(false);
    expect(isOscTitleUnusable(undefined)).toBe(false);
    expect(isOscTitleUnusable("not-a-real-agent")).toBe(false);
  });

  it("codex uses plugin hooks for notifications, not OSC9 terminal overrides", () => {
    // Notifications now arrive via injected codex hooks (buildCodexNotifyInjection),
    // so no OSC9-forcing -c flags are baked into the registry entry. The hook
    // injection happens at per-spawn time in agent-launch-augmenter.ts.
    const r = resolveAgent("codex");
    expect(r.args).toEqual([]);
    expect(r.args).not.toContain("tui.notification_method=osc9");
    expect(AGENTS["codex"].notificationSource).toBe("plugin");
  });

  it("agents without default flags resolve to empty args", () => {
    expect(resolveAgent("claude-code").args).toEqual([]);
    expect(resolveAgent("cursor-agent").args).toEqual([]);
  });

  it("titleSourceFor is structured for agents with a hook-derived title path", () => {
    // Deliberately NOT the same set as notificationSource "plugin": cursor-agent
    // has plugin notifications but no structured title resolver, and
    // github-copilot has a structured title resolver despite osc notifications.
    expect(titleSourceFor("claude-code")).toBe("structured");
    expect(titleSourceFor("codex")).toBe("structured");
    expect(titleSourceFor("opencode")).toBe("structured");
    expect(titleSourceFor("github-copilot")).toBe("structured");
  });

  it("titleSourceFor is osc for agents without a fail-open injection signal, or no structured resolver at all", () => {
    expect(titleSourceFor("cursor-agent")).toBe("osc");
    expect(titleSourceFor("kilo")).toBe("osc");
    expect(titleSourceFor("kimi")).toBe("osc");
    expect(titleSourceFor("mistral-vibe")).toBe("osc");
  });

  it("titleSourceFor defaults to osc for an unregistered tool", () => {
    expect(titleSourceFor("some-future-agent")).toBe("osc");
  });
});

test("opencode env points OPENCODE_TUI_CONFIG at an attention-enabled config file", () => {
  const base = mkdtempSync(join(tmpdir(), "ab-known-agents-"));
  const env = resolveAgentEnv("opencode", base);

  const path = env.OPENCODE_TUI_CONFIG;
  expect(path).toBeTruthy();
  expect(existsSync(path!)).toBe(true);

  const cfg = JSON.parse(readFileSync(path!, "utf8"));
  expect(cfg.attention.enabled).toBe(true);
});

test("opencode env writer is idempotent", () => {
  const base = mkdtempSync(join(tmpdir(), "ab-known-agents-"));
  const a = resolveAgentEnv("opencode", base);
  const b = resolveAgentEnv("opencode", base);
  expect(a.OPENCODE_TUI_CONFIG).toBe(b.OPENCODE_TUI_CONFIG);
});

// Antgrid manages the session lifecycle; a self-backgrounded claude leaves the
// slot resuming an id a job outside this bridge still holds.
test("claude env disables claude's own background agent view", () => {
  const base = mkdtempSync(join(tmpdir(), "ab-known-agents-"));
  expect(resolveAgentEnv("claude-code", base).CLAUDE_CODE_DISABLE_AGENT_VIEW).toBe("1");
});

test("kilo env points KILO_TUI_CONFIG at an attention-enabled config file", () => {
  const base = mkdtempSync(join(tmpdir(), "ab-known-agents-"));
  const env = resolveAgentEnv("kilo", base);

  const path = env.KILO_TUI_CONFIG;
  expect(path).toBeTruthy();
  expect(existsSync(path!)).toBe(true);

  const cfg = JSON.parse(readFileSync(path!, "utf8"));
  expect(cfg.attention.enabled).toBe(true);
});

test("entry-only agents get no extra launch env", () => {
  const base = mkdtempSync(join(tmpdir(), "ab-known-agents-"));
  // These notify by default (or via the focus-routing default-blur) so they
  // need no injected config — only a registry entry. claude-code is absent
  // deliberately: its launch env pins a behaviour switch, not notifications.
  expect(resolveAgentEnv("kimi", base)).toEqual({});
  expect(resolveAgentEnv("mistral-vibe", base)).toEqual({});
  expect(resolveAgentEnv("codex", base)).toEqual({});
  expect(resolveAgentEnv("antigravity", base)).toEqual({});
});

test("honors a user-set config env var instead of clobbering it", () => {
  const base = mkdtempSync(join(tmpdir(), "ab-known-agents-"));
  const prev = process.env.OPENCODE_TUI_CONFIG;
  process.env.OPENCODE_TUI_CONFIG = "/home/me/my-tui.json";
  try {
    // User already pointed the var at their own file — we must not override it.
    expect(resolveAgentEnv("opencode", base)).toEqual({});
  } finally {
    if (prev === undefined) delete process.env.OPENCODE_TUI_CONFIG;
    else process.env.OPENCODE_TUI_CONFIG = prev;
  }
});

test("degrades to no env when the config file can't be written", () => {
  // Use a regular file as the abDir so mkdir/write of <file>/agents fails.
  const fileAsDir = join(mkdtempSync(join(tmpdir(), "ab-known-agents-")), "not-a-dir");
  writeFileSync(fileAsDir, "x");
  const prev = process.env.OPENCODE_TUI_CONFIG;
  delete process.env.OPENCODE_TUI_CONFIG;
  try {
    // Spawn must still proceed (empty env), not throw.
    expect(resolveAgentEnv("opencode", fileAsDir)).toEqual({});
  } finally {
    if (prev !== undefined) process.env.OPENCODE_TUI_CONFIG = prev;
  }
});
