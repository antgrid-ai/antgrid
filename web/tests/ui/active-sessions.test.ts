import { describe, test, expect } from "bun:test";
import { ActiveSessionsCard } from "../../src/ui/active-sessions.js";
import type { UserSession } from "../../src/services/sessions.js";

const NOW = 1_000_000;
function session(p: Partial<UserSession> = {}): UserSession {
  return { deviceUuid: "uuid-a", displayName: "My Mac", connectedAt: NOW - 5000, openStreamCount: 1, ...p };
}

describe("ActiveSessionsCard", () => {
  // Free gained remote control with the worker cap, so the card no longer
  // branches on tier at all — gating this list would contradict the entitlement.
  test("renders the list, never an upsell", () => {
    const html = ActiveSessionsCard({ sessions: [session()], now: NOW }).toString();
    expect(html).toContain("My Mac");
    expect(html).not.toContain('href="/pricing"');
    expect(html).not.toContain("Upgrade to Pro");
  });

  test("renders a row per machine", () => {
    const html = ActiveSessionsCard({
      sessions: [session(), session({ deviceUuid: "uuid-b", displayName: "Work PC" })],
      now: NOW,
    }).toString();
    expect(html).toContain("My Mac");
    expect(html).toContain("Work PC");
  });

  // The header tracks the relay's stream count, not the row count, or a
  // two-machine user running four projects reads as "2 running".
  test("the running count sums open streams, not machines", () => {
    const html = ActiveSessionsCard({
      sessions: [session({ openStreamCount: 3 }), session({ deviceUuid: "uuid-b", openStreamCount: 1 })],
      now: NOW,
    }).toString();
    expect(html).toContain("4 running");
  });

  // Streams stopped being the paid axis when the worker cap replaced
  // sessionLimit — a denominator here would imply a quota that no longer exists.
  test("the running count carries no denominator", () => {
    const html = ActiveSessionsCard({
      sessions: [session({ openStreamCount: 3 })],
      now: NOW,
    }).toString();
    expect(html).toContain("3 running");
    expect(html).not.toContain("/ 10");
    expect(html).not.toMatch(/\d+\s*\/\s*\d+\s*running/);
  });

  test("a connected machine with no open stream shows as idle", () => {
    const html = ActiveSessionsCard({
      sessions: [session({ openStreamCount: 0 })],
      now: NOW,
    }).toString();
    expect(html).toContain("My Mac");
    expect(html).toContain("idle");
    expect(html).toContain("0 running");
  });

  test("zero sessions renders the empty state", () => {
    const html = ActiveSessionsCard({ sessions: [], now: NOW }).toString();
    expect(html).toContain("No agents running remotely");
  });

  test("null sessions (relay unreachable) renders the error state", () => {
    const html = ActiveSessionsCard({ sessions: null, now: NOW }).toString();
    expect(html).toContain("reach the relay");
  });
});
