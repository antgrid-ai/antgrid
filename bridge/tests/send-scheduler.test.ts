import { describe, expect, it } from "bun:test";
import { SEAL_OVERHEAD_BYTES, WINDOW_RESYNC_AGE_MS } from "antgrid-wire";
import { SendScheduler, type QueuedAppFrame } from "../src/send-scheduler";
import type { Channel } from "../src/message-bus";

/** Sealed length is plaintext + the AES-GCM overhead, exactly as the real sink
 *  reports it, so window arithmetic here is the arithmetic in production. */
function makeScheduler(): {
  s: SendScheduler;
  wire: QueuedAppFrame[];
  logs: string[];
} {
  const wire: QueuedAppFrame[] = [];
  const logs: string[] = [];
  const s = new SendScheduler(
    { send: (f) => { wire.push(f); return f.plaintextBytes + SEAL_OVERHEAD_BYTES; } },
    (m) => logs.push(m),
  );
  return { s, wire, logs };
}

function frame(
  channel: Channel,
  bytes: number,
  opts: { streamId?: string; type?: string } = {},
): QueuedAppFrame {
  return {
    channel,
    streamId: opts.streamId ?? "0",
    plaintext: "x".repeat(bytes),
    plaintextBytes: bytes,
    type: opts.type ?? "app",
  };
}

const sealed = (bytes: number) => bytes + SEAL_OVERHEAD_BYTES;

describe("SendScheduler queueing and priority", () => {
  it("drains FIFO within a channel and control ahead of preview", () => {
    const { s, wire } = makeScheduler();
    s.hold = true;
    s.enqueue([frame("preview", 10, { type: "p1" })]);
    s.enqueue([frame("preview", 10, { type: "p2" })]);
    s.enqueue([frame("control", 10, { type: "c1" })]);

    s.hold = false;
    expect(s.drain()).toBe("idle");
    expect(wire.map((f) => f.type)).toEqual(["c1", "p1", "p2"]);
  });

  it("hold parks the drain and nothing is written", () => {
    const { s, wire } = makeScheduler();
    s.hold = true;
    s.enqueue([frame("preview", 10), frame("preview", 10), frame("preview", 10)]);

    expect(s.drain()).toBe("held");
    expect(wire).toEqual([]);
    expect(s.queued("preview").frames).toBe(3);
  });

  it("window-blocks one channel without blocking the other", () => {
    const { s, wire } = makeScheduler();
    s.limits.window = 1000;
    // Each enqueue drains, the way the owning client uses it.
    s.enqueue([frame("preview", 600, { type: "p1" })]);
    s.drain();
    s.enqueue([frame("preview", 600, { type: "p2" })]);
    expect(s.drain()).toBe("blocked");
    s.enqueue([frame("control", 100, { type: "c1" })]);
    expect(s.drain()).toBe("blocked");

    expect(wire.map((f) => f.type)).toEqual(["p1", "c1"]);
    expect(s.unacked("preview")).toBe(sealed(600));
    expect(s.blockedSince.preview).toBeGreaterThan(0);
  });

  it("releases exactly the delta on a credit; stale and duplicate credits are no-ops; over-credit clamps to sent", () => {
    const { s, wire } = makeScheduler();
    s.limits.window = 1000;
    s.enqueue([frame("preview", 600, { type: "p1" })]);
    s.drain();
    s.enqueue([frame("preview", 600, { type: "p2" })]);
    s.drain();
    expect(wire).toHaveLength(1);

    // A credit that advances but not far enough leaves the head where it is.
    s.credit("preview", 100);
    expect(s.drain()).toBe("blocked");
    expect(wire).toHaveLength(1);

    expect(s.credit("preview", sealed(600))).toBe(true);
    s.drain();
    expect(wire.map((f) => f.type)).toEqual(["p1", "p2"]);

    expect(s.credit("preview", sealed(600))).toBe(false);
    expect(wire).toHaveLength(2);

    // Credit beyond what was ever sent is discarded, not banked: the next
    // charge is fully in flight again.
    s.credit("preview", 10_000);
    expect(s.unacked("preview")).toBe(0);
    s.charge("preview", 500);
    expect(s.unacked("preview")).toBe(500);
  });

  it("sends a frame larger than the window when nothing is unacked", () => {
    const { s, wire } = makeScheduler();
    s.limits.window = 100;
    s.enqueue([frame("preview", 5000, { type: "big1" })]);
    s.drain();
    expect(wire.map((f) => f.type)).toEqual(["big1"]);

    s.enqueue([frame("preview", 5000, { type: "big2" })]);
    expect(s.drain()).toBe("blocked");
    expect(wire).toHaveLength(1);
  });

  it("bounds both channels together with the socket cap while control keeps flowing", () => {
    const { s, wire } = makeScheduler();
    s.limits.window = 2000;
    s.limits.socketCap = 3000;

    s.enqueue([frame("preview", 1000, { type: "p1" })]);
    s.drain();
    s.enqueue([frame("preview", 900, { type: "p2" })]);
    s.drain();
    expect(wire.map((f) => f.type)).toEqual(["p1", "p2"]);
    expect(s.unacked("preview")).toBe(sealed(1000) + sealed(900));

    // Preview is effectively full; control still has window and cap headroom.
    s.enqueue([frame("preview", 100, { type: "p3" })]);
    s.enqueue([frame("control", 900, { type: "c1" })]);
    expect(s.drain()).toBe("blocked");
    expect(wire.map((f) => f.type)).toEqual(["p1", "p2", "c1"]);

    // Blocked by the socket cap rather than by its own window.
    s.enqueue([frame("control", 200, { type: "c2" })]);
    expect(s.drain()).toBe("blocked");
    expect(s.unacked("control") + sealed(200)).toBeLessThanOrEqual(s.limits.window);
    expect(s.totalUnacked() + sealed(200)).toBeGreaterThan(s.limits.socketCap);

    s.credit("preview", sealed(1000) + sealed(900));
    s.drain();
    expect(wire.map((f) => f.type)).toEqual(["p1", "p2", "c1", "c2", "p3"]);
  });

  it("enqueues all-or-nothing against the queue cap", () => {
    const { s } = makeScheduler();
    s.hold = true;
    s.limits.maxQueuedBytes = 1000;

    expect(s.enqueue([frame("preview", 600), frame("preview", 600)])).toBe(false);
    expect(s.queued("preview").frames).toBe(0);
    expect(s.enqueue([frame("preview", 600)])).toBe(true);
    expect(s.queued("preview").bytes).toBe(600);
  });

  it("drops only one stream's frames on dropStream, and everything on clear", () => {
    const { s } = makeScheduler();
    s.hold = true;
    s.enqueue([frame("control", 10, { streamId: "a", type: "a1" })]);
    s.enqueue([frame("control", 10, { streamId: "b", type: "b1" })]);
    s.enqueue([frame("preview", 10, { streamId: "a", type: "a2" })]);
    s.enqueue([frame("control", 10, { streamId: "b", type: "b2" })]);

    const droppedA = s.dropStream("a");
    expect(droppedA.map((f) => f.type)).toEqual(["a1", "a2"]);
    expect(s.queued("control")).toEqual({ frames: 2, bytes: 20 });
    expect(s.queued("preview")).toEqual({ frames: 0, bytes: 0 });

    const rest = s.clear();
    expect(rest.map((f) => f.type)).toEqual(["b1", "b2"]);
    expect(s.queued("control")).toEqual({ frames: 0, bytes: 0 });
  });

  it("resetWindows forgets the counters but keeps the queue", () => {
    const { s } = makeScheduler();
    s.limits.window = 1000;
    s.enqueue([frame("preview", 600)]);
    s.drain();
    s.hold = true;
    s.enqueue([frame("control", 10)]);
    expect(s.unacked("preview")).toBe(sealed(600));

    s.resetWindows();

    expect(s.unacked("preview")).toBe(0);
    expect(s.totalUnacked()).toBe(0);
    expect(s.queued("control").frames).toBe(1);
  });

  it("reopens a window the relay's drops closed when it un-charges them", () => {
    const { s, wire } = makeScheduler();
    s.limits.window = 1000;
    s.enqueue([frame("preview", 900, { type: "p1" })]);
    s.drain();
    expect(s.unacked("preview")).toBe(sealed(900));

    s.enqueue([frame("preview", 900, { type: "p2" })]);
    expect(s.drain()).toBe("blocked");

    s.uncharge("preview", 900);
    s.drain();
    expect(wire.map((f) => f.type)).toEqual(["p1", "p2"]);
  });

  it("presumes bytes lost once a credit two ticks on still has not counted them", () => {
    const { s, wire, logs } = makeScheduler();
    const resyncs = () => logs.filter((l) => l.includes("window resync on preview"));
    let clock = 1_000;
    s.now = () => clock;
    s.limits.window = 1000;
    s.enqueue([frame("preview", 900, { type: "p1" })]);
    s.drain();
    s.enqueue([frame("preview", 500, { type: "p2" })]);
    expect(s.drain()).toBe("blocked");

    // The anchor: 928 bytes written, none counted. Not conclusive on its own.
    expect(s.credit("preview", 0)).toBe(false);
    clock += WINDOW_RESYNC_AGE_MS - 1;
    expect(s.credit("preview", 0)).toBe(false);
    expect(wire).toHaveLength(1);

    clock += 1;
    expect(s.credit("preview", 0)).toBe(true);
    expect(s.unacked("preview")).toBe(0);
    s.drain();
    expect(wire.map((f) => f.type)).toEqual(["p1", "p2"]);
    expect(resyncs()).toHaveLength(1);
    expect(resyncs()[0]).toContain("928");

    // Only what the old anchor saw can be presumed lost: p2's bytes were
    // written after it, and the credits that would count them are still due.
    clock += 10;
    expect(s.credit("preview", 0)).toBe(false);
    expect(s.unacked("preview")).toBe(528);
    expect(resyncs()).toHaveLength(1);

    // A credit that counts the bytes in time leaves nothing to presume.
    clock += WINDOW_RESYNC_AGE_MS;
    expect(s.credit("preview", 1456)).toBe(true);
    clock += WINDOW_RESYNC_AGE_MS;
    expect(s.credit("preview", 1456)).toBe(false);
    expect(resyncs()).toHaveLength(1);
  });

  it("does not presume a reported drop lost a second time", () => {
    const { s, logs } = makeScheduler();
    let clock = 1_000;
    s.now = () => clock;
    s.limits.window = 1000;
    s.enqueue([frame("preview", 900, { type: "p1" })]);
    s.drain();
    expect(s.credit("preview", 0)).toBe(false);

    // The relay reports p1 discarded: the anchor must shrink with `sent`, or
    // the resync would un-charge p1 again on top of the report.
    s.uncharge("preview", 928);
    s.enqueue([frame("preview", 500, { type: "p2" })]);
    s.drain();
    clock += WINDOW_RESYNC_AGE_MS;
    expect(s.credit("preview", 0)).toBe(false);
    expect(s.unacked("preview")).toBe(528);
    expect(logs.filter((l) => l.includes("window resync"))).toHaveLength(0);
  });

  it("counts session bytes toward the gate without gating them", () => {
    const { s, wire } = makeScheduler();
    s.limits.window = 1000;

    s.charge("control", 990);
    s.enqueue([frame("control", 100, { type: "c1" })]);
    expect(s.drain()).toBe("blocked");
    expect(wire).toEqual([]);

    s.credit("control", 990);
    s.drain();
    expect(wire.map((f) => f.type)).toEqual(["c1"]);
  });
});
