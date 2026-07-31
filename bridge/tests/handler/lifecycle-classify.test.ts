// bridge/tests/handler/lifecycle-classify.test.ts
import { describe, it, expect } from "bun:test";
import { classifyTurnEndError } from "../../src/handler/lifecycle-classify";
import type { AgentError } from "../../src/protocol";

const NOW = 1_700_000_000_000;

function err(category: AgentError["category"], extra: Partial<AgentError> = {}): AgentError {
  return { category, message: `${category} happened`, retryable: false, ...extra };
}

describe("classifyTurnEndError", () => {
  // Keyed by category rather than a list so a new AgentError category fails
  // typecheck here instead of silently falling through to null.
  const table: Record<AgentError["category"], "limit_hit" | "turn_failed" | null> = {
    rate_limited: "limit_hit",
    quota_exceeded: "limit_hit",
    server_error: "turn_failed",
    network: "turn_failed",
    auth: null,
    context_overflow: null,
    aborted: null,
    unknown: null,
  };

  for (const [category, expected] of Object.entries(table) as Array<
    [AgentError["category"], "limit_hit" | "turn_failed" | null]
  >) {
    it(`maps ${category} to ${expected ?? "null (plain turn_end stands)"}`, () => {
      const got = classifyTurnEndError(err(category), NOW);
      if (expected === null) expect(got).toBeNull();
      else expect(got?.event).toBe(expected);
    });
  }

  it("carries the category as the activity reason", () => {
    expect(classifyTurnEndError(err("server_error"), NOW)?.errorClass).toBe("server_error");
    expect(classifyTurnEndError(err("quota_exceeded"), NOW)?.errorClass).toBe("quota_exceeded");
  });

  it("turns retryAfterMs into an absolute wake time", () => {
    const got = classifyTurnEndError(err("rate_limited", { retryAfterMs: 60_000 }), NOW);
    expect(got?.resetsAt).toBe(NOW + 60_000);
  });

  it("leaves resetsAt absent when the driver captured no reset time", () => {
    const got = classifyTurnEndError(err("rate_limited"), NOW);
    expect(got?.event).toBe("limit_hit");
    expect(got?.resetsAt).toBeUndefined();
  });

  it("never attaches a wake time to a transient failure", () => {
    // Backoff for an outage is the engine's series, not the provider's hint.
    const got = classifyTurnEndError(err("server_error", { retryAfterMs: 5_000 }), NOW);
    expect(got?.event).toBe("turn_failed");
    expect(got?.resetsAt).toBeUndefined();
  });
});
