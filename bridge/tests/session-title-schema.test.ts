import { describe, expect, test } from "bun:test";
import { NotifyBodySchema, SessionTitleSchema } from "../src/api-server";
import { AGENTS, BY_HOOK_NAME } from "../src/agents/registry";

// Every agent that posts under a hook name, taken from the registry rather than
// re-listed: a hand-written copy here would pass while the schema it guards
// rejected the very agent that was just added.
const HOOK_NAMES = Object.keys(BY_HOOK_NAME);

describe("SessionTitleSchema", () => {
  test("accepts every hook name in the registry", () => {
    expect(HOOK_NAMES.length).toBeGreaterThan(0);
    for (const agent of HOOK_NAMES) {
      const r = SessionTitleSchema.safeParse({
        terminalId: "t1",
        sessionId: "s1",
        agent,
        titleOnly: agent === "github-copilot" ? true : undefined,
      });
      expect(r.success).toBe(true);
    }
  });

  test("covers every agent that declares a hookName", () => {
    const declared = Object.values(AGENTS)
      .map((spec) => spec.hookName)
      .filter((name): name is string => name !== null);
    expect(new Set(HOOK_NAMES)).toEqual(new Set(declared));
  });

  test("rejects an unknown agent", () => {
    const r = SessionTitleSchema.safeParse({ terminalId: "t1", sessionId: "s1", agent: "nope" });
    expect(r.success).toBe(false);
  });

  test("NotifyBodySchema takes the same vocabulary", () => {
    for (const agent of HOOK_NAMES) {
      expect(NotifyBodySchema.safeParse({ type: "task_complete", agent }).success).toBe(true);
    }
    expect(NotifyBodySchema.safeParse({ type: "task_complete", agent: "nope" }).success).toBe(false);
  });

  test("requires terminalId and sessionId", () => {
    expect(SessionTitleSchema.safeParse({ sessionId: "s1" }).success).toBe(false);
    expect(SessionTitleSchema.safeParse({ terminalId: "t1" }).success).toBe(false);
  });
});
