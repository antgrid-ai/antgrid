import { describe, expect, test } from "bun:test";
import { ConnectionLivenessTracker } from "../src/connection-liveness.js";

describe("ConnectionLivenessTracker", () => {
  test("application ping and protocol pong independently refresh liveness", () => {
    const tracker = new ConnectionLivenessTracker();
    tracker.add("c1", 1_000);

    expect(tracker.isTimedOut("c1", 3_001, 2_000)).toBe(true);
    tracker.noteApplicationPing("c1", 3_001);
    expect(tracker.isTimedOut("c1", 5_001, 2_000)).toBe(false);
    tracker.noteProtocolPong("c1", 5_002);
    expect(tracker.isTimedOut("c1", 7_002, 2_000)).toBe(false);
    expect(tracker.ages("c1", 7_002)).toEqual({
      connectionAgeMs: 6_002,
      protocolPongAgeMs: 2_000,
      applicationPingAgeMs: 4_001,
    });
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