// The declarations every hook profile now carries — `posts` and
// `turnBoundaryEvents` — and the two cross-agent answers derived from them.
// Pinned per agent because the whole point of pushing them into the profiles is
// that a per-agent change cannot silently move a cross-agent verdict.
import { describe, expect, test } from "bun:test";
import { AGENTS, handlerObservable, needsKeystrokeTurnStart } from "../src/agents/registry";
import { injectsHookAliveProbe } from "../src/agent-launch-augmenter";
import type { AgentKey } from "../src/agents/types";

const AGENT_KEYS = [
  "claude-code", "codex", "opencode", "cursor-agent",
  "github-copilot", "kilo", "kimi", "mistral-vibe",
] as const;

/** Compile-time completeness: a table missing a key fails to typecheck. */
type PerAgent<T> = Record<AgentKey, T>;

describe("hook profile declarations", () => {
  test("every declared turn boundary is an event the agent actually dispatches", () => {
    for (const key of AGENT_KEYS) {
      const hooks = AGENTS[key].hooks;
      if (!hooks) continue;
      for (const event of [...hooks.turnBoundaryEvents.start, ...hooks.turnBoundaryEvents.end]) {
        expect(hooks.events).toContain(event);
      }
    }
  });

  test("only the agents with an installed integration declare posts", () => {
    const expected: PerAgent<readonly string[] | null> = {
      "claude-code": ["/session-title", "/turn-start", "/notify", "/handler-event"],
      codex: ["/session-title", "/handler-event", "/notify", "/hook-alive"],
      // Posted from inside opencode's own runtime, so this list is deliberately
      // NOT derivable from its (empty) `events`.
      opencode: ["/session-title", "/notify", "/handler-event"],
      "cursor-agent": ["/session-title", "/notify"],
      "github-copilot": ["/session-title"],
      kilo: null,
      kimi: null,
      "mistral-vibe": null,
    };
    for (const key of AGENT_KEYS) {
      expect(AGENTS[key].hooks?.posts ?? null).toEqual(expected[key] as never);
    }
  });

  test("copilot alone declares the api.port fallback", () => {
    for (const key of AGENT_KEYS) {
      expect(AGENTS[key].hooks?.portFileFallback).toBe(
        key === "github-copilot" ? true : (undefined as never),
      );
    }
  });
});

describe("needsKeystrokeTurnStart", () => {
  test("true only for agents that report turn ends and no turn start", () => {
    const expected: PerAgent<boolean> = {
      "claude-code": false,
      codex: true,
      opencode: false,
      "cursor-agent": true,
      "github-copilot": true,
      kilo: false,
      kimi: false,
      "mistral-vibe": false,
    };
    for (const key of AGENT_KEYS) expect(needsKeystrokeTurnStart(key)).toBe(expected[key]);
  });

  test("an unknown tool and an unnamed one both decline the inference", () => {
    expect(needsKeystrokeTurnStart("some-shell")).toBe(false);
    expect(needsKeystrokeTurnStart(undefined)).toBe(false);
  });
});

describe("injectsHookAliveProbe", () => {
  test("codex alone probes the hook channel at session start", () => {
    for (const key of AGENT_KEYS) expect(injectsHookAliveProbe(key)).toBe(key === "codex");
    expect(injectsHookAliveProbe("some-shell")).toBe(false);
  });
});

describe("handlerObservable", () => {
  test("terminal mode needs an integration that posts /handler-event", () => {
    const expected: PerAgent<boolean> = {
      "claude-code": true,
      codex: true,
      opencode: true,
      "cursor-agent": false,
      "github-copilot": false,
      kilo: false,
      kimi: false,
      "mistral-vibe": false,
    };
    for (const key of AGENT_KEYS) expect(handlerObservable(key, "terminal")).toBe(expected[key]);
  });

  test("chat mode needs only a driver — the engine taps its frames in-process", () => {
    const expected: PerAgent<boolean> = {
      "claude-code": true,
      codex: true,
      opencode: true,
      "cursor-agent": false,
      "github-copilot": false,
      kilo: false,
      kimi: false,
      "mistral-vibe": false,
    };
    for (const key of AGENT_KEYS) expect(handlerObservable(key, "chat")).toBe(expected[key]);
  });

  test("an unknown tool and an unnamed one are unobservable in both modes", () => {
    for (const mode of ["terminal", "chat"] as const) {
      expect(handlerObservable("some-shell", mode)).toBe(false);
      expect(handlerObservable(undefined, mode)).toBe(false);
    }
  });
});
