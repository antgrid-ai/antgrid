// The half of a watcher CLI that both `antgrid watch` and `antgrid calls` run
// on. Driven directly rather than through either command: everything here is
// about the dead man's switch and about what the stream's control frames mean,
// and reaching it through a CLI would make each assertion depend on that
// command's flags, its host and its rendering as well.
import { describe, expect, it } from "bun:test";
import {
  CaptureArms,
  heartbeatFor,
  replayGaps,
  shedCount,
} from "../src/cli/watch-transport";

describe("heartbeatFor", () => {
  it("renews well inside the window rather than near its edge", () => {
    // The cadence is what makes a single dropped or slow re-arm cost nothing.
    // Drifted toward the window, one missed renewal lets the host's capture
    // lapse mid-run — and for modelwatch a lapse does not merely stop recording,
    // it PURGES the text already in the ring, so the operator loses the capture
    // they are in the middle of reading with no error anywhere.
    expect(heartbeatFor(300_000)).toBe(120_000);
    expect(heartbeatFor(60_000)).toBe(24_000);
  });

  it("keeps a floor under a window short enough to renew in a loop", () => {
    // A host free to clamp to something tiny must not turn this into a spin.
    expect(heartbeatFor(1_000)).toBe(1_000);
    expect(heartbeatFor(0)).toBe(1_000);
  });
});

describe("CaptureArms", () => {
  /** An arm that records what it was asked to do and grants a window short
   *  enough that a renewal would land inside a test's patience. */
  function recordingArm(calls: boolean[], ttlMs = 2_500) {
    return {
      what: "a capture",
      set: async (enabled: boolean): Promise<{ error: string | null; ttlMs: number }> => {
        calls.push(enabled);
        return { error: null, ttlMs };
      },
    };
  }

  it("takes its timer with it, not only the arms it was holding", async () => {
    const first: boolean[] = [];
    const second: boolean[] = [];
    const arms = new CaptureArms(() => {});
    const { error, ttlMs } = await arms.arm(recordingArm(first));
    expect(error).toBeNull();
    arms.pace(ttlMs);
    arms.start();

    await arms.stop();
    expect(first).toEqual([true, false]);

    // `stop` empties the held list before it returns, so an interval that
    // survived it renews nothing for the run that started it — which is exactly
    // what makes the missing `clearInterval` invisible from that run's own
    // output. What a survivor does is outlive the run, holding the event loop
    // open and adopting whatever is held next: this second arm was never
    // `start`ed and must therefore never be renewed.
    await arms.arm(recordingArm(second));
    await Bun.sleep(2_500);

    expect(second).toEqual([true]);
    await arms.stop();
  });

  it("disarms only what the host actually armed", async () => {
    const armed: boolean[] = [];
    const refused: boolean[] = [];
    const arms = new CaptureArms(() => {});
    await arms.arm(recordingArm(armed));
    // A run that armed one capture and failed to arm a second still owes the
    // first a disarm, and must not send one for a window it never got.
    await arms.arm({
      what: "a refused capture",
      set: async (enabled: boolean) => {
        refused.push(enabled);
        return { error: "refused", ttlMs: 0 };
      },
    });

    await arms.stop();

    expect(armed).toEqual([true, false]);
    expect(refused).toEqual([true]);
  });

  it("keeps no interval at all when nothing was armed", async () => {
    const arms = new CaptureArms(() => {});
    arms.start();
    // Nothing to renew, so an unarmed run must not hold the process open to
    // renew it. Reaching `stop` at all is the assertion: an interval here would
    // outlive the run with no arm behind it.
    await arms.stop();
  });
});

describe("capture-stream control frames", () => {
  const meta = (over: Record<string, number>): string =>
    JSON.stringify({ recorded: 10, evicted: 0, buffered: 10, replayed: 10, ...over });

  it("names an eviction and a short replay separately, in the watcher's noun", () => {
    // Two different blind spots with two different remedies: history the ring no
    // longer holds, against history it holds and `--limit` would have asked for.
    expect(replayGaps(meta({ evicted: 4 }), "records")).toEqual([
      "4 older records already evicted",
    ]);
    expect(replayGaps(meta({ replayed: 6 }), "events")).toEqual([
      "4 buffered events not replayed — raise --limit",
    ]);
    expect(replayGaps(meta({ evicted: 4, replayed: 6 }), "records")).toHaveLength(2);
  });

  it("says nothing when the replay was complete", () => {
    expect(replayGaps(meta({}), "records")).toEqual([]);
  });

  it("survives a frame it cannot read rather than taking the run with it", () => {
    // The decoder runs inside the reader's loop, where a throw would lose the
    // closing tally the run exists to print.
    expect(replayGaps("not json", "records")).toEqual([]);
    expect(shedCount("not json")).toBe(0);
    expect(shedCount("{}")).toBe(0);
  });

  it("reads the count the host shed for this reader", () => {
    expect(shedCount(JSON.stringify({ dropped: 12 }))).toBe(12);
  });
});
