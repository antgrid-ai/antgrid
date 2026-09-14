import { describe, expect, test } from "bun:test";
import {
  ConnectionLivenessTracker,
  INBOUND_LIVENESS_MAX_BACKLOG_BYTES,
} from "../src/connection-liveness.js";

describe("ConnectionLivenessTracker", () => {
  test("application ping and protocol pong are duplex liveness", () => {
    const tracker = new ConnectionLivenessTracker();
    tracker.add("c1", 1_000);

    expect(tracker.isTimedOut("c1", 3_001, 2_000)).toBe(true);
    tracker.noteApplicationPing("c1", 3_001);
    expect(tracker.isTimedOut("c1", 5_001, 2_000)).toBe(false);
    tracker.noteProtocolPong("c1", 5_002);
    expect(tracker.isTimedOut("c1", 7_002, 2_000)).toBe(false);
  });

  test("routed traffic keeps a pong-less socket alive while its outbound drains", () => {
    const tracker = new ConnectionLivenessTracker();
    tracker.add("c1", 1_000);
    tracker.noteAuthenticatedInbound("c1", 2_900);

    expect(tracker.isTimedOut("c1", 3_001, 2_000)).toBe(false);
    expect(tracker.isTimedOut("c1", 3_001, 2_000, INBOUND_LIVENESS_MAX_BACKLOG_BYTES)).toBe(false);
    // The frames age out like a pong would.
    expect(tracker.isTimedOut("c1", 4_901, 2_000)).toBe(true);
    expect(tracker.ages("c1", 3_001)).toEqual({
      connectionAgeMs: 2_001,
      protocolPongAgeMs: null,
      applicationPingAgeMs: null,
      authenticatedInboundAgeMs: 101,
    });
  });

  test("routed traffic cannot mask a reader that stopped", () => {
    const tracker = new ConnectionLivenessTracker();
    tracker.add("c1", 1_000);
    tracker.noteAuthenticatedInbound("c1", 2_900);

    expect(
      tracker.isTimedOut("c1", 3_001, 2_000, INBOUND_LIVENESS_MAX_BACKLOG_BYTES + 1),
    ).toBe(true);
    // A pong is duplex proof on its own, backlog or not.
    tracker.noteProtocolPong("c1", 3_000);
    expect(
      tracker.isTimedOut("c1", 3_001, 2_000, INBOUND_LIVENESS_MAX_BACKLOG_BYTES + 1),
    ).toBe(false);
  });

  test("late callbacks from a removed socket cannot refresh its replacement", () => {
    const tracker = new ConnectionLivenessTracker();
    tracker.add("old", 1_000);
    tracker.remove("old");
    tracker.add("replacement", 2_000);

    tracker.noteProtocolPong("old", 3_900);
    expect(tracker.isTimedOut("replacement", 4_001, 2_000)).toBe(true);
    expect(tracker.ages("replacement", 4_001)?.protocolPongAgeMs).toBeNull();
  });
});
