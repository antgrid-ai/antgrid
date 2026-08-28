import { describe, expect, test } from "bun:test";

import { pickHeadless, resolveHeadless } from "../src/agents/headless";
import { AGENTS, judgeCapable } from "../src/agents/registry";
import { pickHeadlessFrom, type AgentKey, type AgentSpec } from "../src/agents/types";

const cmd = (label: string) => ({
  cmd: () => [label],
  noHistory: "flag" as const,
});

describe("reach selection", () => {
  // "none" takes the tightest available; "repo" cannot take a sealed argv at all,
  // because reading the working tree is the work it exists to do.
  test("a need takes the tightest entry that can serve it", () => {
    const all: AgentSpec["headless"] = {
      sealed: cmd("sealed"), readonly: cmd("readonly"), transcript: cmd("transcript"),
    };
    expect(pickHeadlessFrom(all, "none")?.reach).toBe("sealed");
    expect(pickHeadlessFrom(all, "repo")?.reach).toBe("readonly");
    expect(pickHeadlessFrom({ transcript: cmd("t") }, "repo")?.reach).toBe("transcript");
    expect(pickHeadlessFrom({ readonly: cmd("r") }, "none")?.reach).toBe("readonly");
  });

  test("a sealed-only agent can be named but can never judge", () => {
    const sealedOnly: AgentSpec["headless"] = { sealed: cmd("sealed") };
    expect(pickHeadlessFrom(sealedOnly, "none")).not.toBeNull();
    expect(pickHeadlessFrom(sealedOnly, "repo")).toBeNull();
  });

  test("no headless block at all serves neither need", () => {
    expect(pickHeadlessFrom(undefined, "none")).toBeNull();
    expect(pickHeadlessFrom(undefined, "repo")).toBeNull();
  });
});

// The predicate that gates the Handler, pinned against the registry itself: an
// agent becomes judge-capable by declaring an argv that reaches the repo, never
// by merely being able to answer a question (see AgentSpec.headless).
describe("judgeCapable", () => {
  test("is exactly 'declares a non-sealed entry', for every agent", () => {
    for (const key of Object.keys(AGENTS) as AgentKey[]) {
      const h = AGENTS[key].headless;
      expect([key, judgeCapable(key)]).toEqual(
        [key, h?.readonly !== undefined || h?.transcript !== undefined],
      );
    }
  });

  test("an unknown tool is not judge-capable", () => {
    expect(judgeCapable("not-an-agent")).toBe(false);
  });
});

// A registry agent that declares no headless entry at all. Each test asserts
// that precondition, so giving it one fails here rather than quietly turning
// these into assertions about nothing.
const NO_HEADLESS = "kimi";

describe("resolveHeadless", () => {
  test("prefers the session's own agent", () => {
    const picked = resolveHeadless("codex", "none", ["claude-code", "codex"]);
    expect(picked?.tool).toBe("codex");
  });

  // An agent whose argv nobody has verified still gets named, by whichever
  // installed agent can serve the call — the whole job is inlined in the prompt.
  test("borrows an installed agent for a 'none' call", () => {
    expect(AGENTS[NO_HEADLESS].headless).toBeUndefined();
    expect(resolveHeadless(NO_HEADLESS, "none", ["claude-code"])?.tool).toBe("claude-code");
    expect(resolveHeadless(NO_HEADLESS, "none", [])).toBeNull();
  });

  // Borrowing a judge would arm a supervisor the user never chose, over their
  // working tree, on an account they did not pick.
  test("never borrows for a 'repo' call", () => {
    expect(pickHeadless(NO_HEADLESS, "repo")).toBeNull();
    expect(resolveHeadless(NO_HEADLESS, "repo", ["claude-code"])).toBeNull();
  });

  test("an unknown tool borrows nothing", () => {
    expect(resolveHeadless("not-an-agent", "none", ["claude-code"])).toBeNull();
  });
});
