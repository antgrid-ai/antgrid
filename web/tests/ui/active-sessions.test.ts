import { describe, test, expect } from "bun:test";
import { ActiveSessionsCard } from "../../src/ui/active-sessions.js";
import type { UserSession } from "../../src/services/sessions.js";

const NOW = 1_000_000;
function session(p: Partial<UserSession> = {}): UserSession {
  return { deviceUuid: "uuid-a", projectId: "proj1", displayName: "My Mac", connectedAt: NOW - 5000, ...p };
}

describe("ActiveSessionsCard", () => {
  test("free tier renders an upsell linking to pricing, not a list", () => {
    const html = ActiveSessionsCard({ tier: "free", sessions: null, sessionLimit: 0, now: NOW }).toString();
    expect(html).toContain('href="/pricing"');
    expect(html).toContain("Upgrade to Pro");
    expect(html).not.toContain("<table");
  });

  test("pro tier with sessions renders a row per session", () => {
    const html = ActiveSessionsCard({
      tier: "pro",
      sessions: [session(), session({ projectId: "proj2", displayName: "Work PC" })],
      sessionLimit: 10,
      now: NOW,
    }).toString();
    expect(html).toContain("My Mac");
    expect(html).toContain("proj1");
    expect(html).toContain("Work PC");
    expect(html).toContain("proj2");
    expect(html).toContain("2 / 10 running");
  });

  test("pro tier with zero sessions renders the empty state", () => {
    const html = ActiveSessionsCard({ tier: "pro", sessions: [], sessionLimit: 10, now: NOW }).toString();
    expect(html).toContain("No agents running remotely");
  });

  test("null sessions (relay unreachable) renders the error state", () => {
    const html = ActiveSessionsCard({ tier: "pro", sessions: null, sessionLimit: 10, now: NOW }).toString();
    expect(html).toContain("reach the relay");
  });
});
