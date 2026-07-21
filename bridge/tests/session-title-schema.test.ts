import { describe, expect, test } from "bun:test";
import { SessionTitleSchema } from "../src/api-server";

describe("SessionTitleSchema", () => {
  test("accepts all known agents and titleOnly", () => {
    for (const agent of ["claude", "codex", "opencode", "github-copilot", "cursor"] as const) {
      const r = SessionTitleSchema.safeParse({
        terminalId: "t1",
        sessionId: "s1",
        agent,
        titleOnly: agent === "github-copilot" ? true : undefined,
      });
      expect(r.success).toBe(true);
    }
  });

  test("rejects an unknown agent", () => {
    const r = SessionTitleSchema.safeParse({ terminalId: "t1", sessionId: "s1", agent: "nope" });
    expect(r.success).toBe(false);
  });

  test("requires terminalId and sessionId", () => {
    expect(SessionTitleSchema.safeParse({ sessionId: "s1" }).success).toBe(false);
    expect(SessionTitleSchema.safeParse({ terminalId: "t1" }).success).toBe(false);
  });
});
