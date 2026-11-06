import { describe, expect, test } from "bun:test";
import { resolveMemoryCaller, type MemoryCallerDeps } from "../src/memory";
import type { SessionEntry } from "../src/protocol";

const session = (overrides: Partial<SessionEntry> = {}): SessionEntry => ({
  id: "session", name: "Work", createdAt: 1, lastUsedAt: 1, archived: false,
  running: true, mode: "terminal", approvalPolicy: "default", checkoutId: "checkout",
  ...overrides,
} as SessionEntry);

function deps(entry = session(), overrides: Partial<MemoryCallerDeps> = {}): MemoryCallerDeps {
  return {
    session: (id) => id === entry.id ? entry : undefined,
    isLiveRun: (id, run) => id === entry.id && run === "live-run",
    runAgent: () => "codex",
    checkoutExists: (id) => id === "checkout",
    ...overrides,
  };
}

describe("memory caller binding", () => {
  test("uses the durable session, actual checkout and launched agent", () => {
    expect(resolveMemoryCaller(deps(session({ tool: "claude-code", approvalPolicy: "default" })), "session", "live-run")).toEqual({
      session_id: "session", checkout_id: "checkout", agent_id: "codex", run_id: "live-run",
    });
  });

  test("approval policy does not govern memory", () => {
    const normal = resolveMemoryCaller(deps(), "session", "live-run");
    expect(resolveMemoryCaller(deps(session({ approvalPolicy: "bypass" })), "session", "live-run")).toEqual(normal);
  });

  test("rejects missing, stale, foreign and archived callers", () => {
    for (const [id, run] of [[undefined, "live-run"], ["session", undefined], ["session", ""], ["session", "old-run"], ["other", "live-run"]]) {
      expect(() => resolveMemoryCaller(deps(), id, run)).toThrow();
    }
    expect(() => resolveMemoryCaller(deps(session({ archived: true })), "session", "live-run")).toThrow();
    expect(() => resolveMemoryCaller(deps(session(), { isLiveRun: () => false }), "session", "live-run")).toThrow();
  });

  test("never falls back to main or invents an agent", () => {
    for (const d of [
      deps(session({ checkoutId: undefined })),
      deps(session(), { checkoutExists: () => false }),
      deps(session(), { runAgent: () => undefined }),
      deps(session({ mode: "chat" })),
      deps(session({ command: "custom" })),
    ]) expect(() => resolveMemoryCaller(d, "session", "live-run")).toThrow();
  });
});
