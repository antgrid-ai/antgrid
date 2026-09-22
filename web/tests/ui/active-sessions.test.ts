import { describe, test, expect } from "bun:test";
import { ActiveSessionsCard } from "../../src/ui/active-sessions.js";
import type { UserSession } from "../../src/services/sessions.js";

const NOW = 1_000_000;
function session(p: Partial<UserSession> = {}): UserSession {
  return { deviceUuid: "uuid-a", displayName: "My Mac", connectedAt: NOW - 5000, ...p };
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

  test("the header reports connected machines", () => {
    const html = ActiveSessionsCard({
      sessions: [session(), session({ deviceUuid: "uuid-b" })],
      now: NOW,
    }).toString();
    expect(html).toContain("2 connected");
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
