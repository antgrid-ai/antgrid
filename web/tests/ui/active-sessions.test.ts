import { describe, test, expect } from "bun:test";
import { ActiveSessionsCard } from "../../src/ui/active-sessions.js";
import type { UserSession } from "../../src/services/sessions.js";

const NOW = 1_000_000;
function session(p: Partial<UserSession> = {}): UserSession {
  return { deviceUuid: "uuid-a", displayName: "My Mac", connectedAt: NOW - 5000, openStreamCount: 1, ...p };
}

describe("ActiveSessionsCard", () => {
  test("free tier renders an upsell linking to pricing, not a list", () => {
    const html = ActiveSessionsCard({ tier: "free", sessions: null, sessionLimit: 0, now: NOW }).toString();
    expect(html).toContain('href="/pricing"');
    expect(html).toContain("Upgrade to Pro");
    expect(html).not.toContain("<table");
  });

  test("pro tier with sessions renders a row per machine", () => {
    const html = ActiveSessionsCard({
      tier: "pro",
      sessions: [session(), session({ deviceUuid: "uuid-b", displayName: "Work PC" })],
      sessionLimit: 10,
      now: NOW,
    }).toString();
    expect(html).toContain("My Mac");
    expect(html).toContain("Work PC");
  });

  // The header must track the relay's denominator (streams), not the row count,
  // or a two-machine user running four projects reads as "2 / 10".
  test("the running count sums open streams, not machines", () => {
    const html = ActiveSessionsCard({
      tier: "pro",
      sessions: [session({ openStreamCount: 3 }), session({ deviceUuid: "uuid-b", openStreamCount: 1 })],
      sessionLimit: 10,
      now: NOW,
    }).toString();
    expect(html).toContain("4 / 10 running");
  });

  test("a connected machine with no open stream shows as idle and costs no quota", () => {
    const html = ActiveSessionsCard({
      tier: "pro",
      sessions: [session({ openStreamCount: 0 })],
      sessionLimit: 10,
      now: NOW,
    }).toString();
    expect(html).toContain("My Mac");
    expect(html).toContain("idle");
    expect(html).toContain("0 / 10 running");
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
