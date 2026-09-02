// The governor is what keeps one flooding terminal from holding every other
// frame behind it on the machine's single FIFO uplink. Everything here runs on
// a fake clock and fake timers: the budget maths is the contract, and a real
// setTimeout would make "one screen per interval" a race.
import { describe, expect, test } from "bun:test";
import { OutputGovernor } from "../src/output-governor";
import { createMessage, type AbMessage } from "../src/protocol";
import { setLogLevel } from "../src/logger";

setLogLevel("error");

function output(terminalId: string, bytes: number, checkoutId?: string): AbMessage {
  const msg = createMessage("terminal:output", { terminalId, data: "x".repeat(bytes) });
  return checkoutId ? ({ ...msg, checkoutId } as AbMessage) : msg;
}

function harness(opts: { burst?: number; refillPerSec?: number; catchUpMs?: number; compose?: OutputGovernorLike["compose"] } = {}) {
  let now = 1_000;
  const timers: Array<{ fn: () => void; at: number; id: number }> = [];
  let nextTimer = 1;
  const sent: AbMessage[] = [];
  const composed: string[] = [];
  const governor = new OutputGovernor({
    compose: opts.compose ?? (async (terminalId, checkoutId) => {
      composed.push(`${checkoutId} ${terminalId}`);
      return createMessage("terminal:snapshot", { terminalId, scrollback: "SCREEN", seq: 1, composed: true });
    }),
    send: (msg) => sent.push(msg),
    now: () => now,
    setTimer: (fn, ms) => {
      const id = nextTimer++;
      timers.push({ fn, at: now + ms, id });
      return id;
    },
    clearTimer: (handle) => {
      const idx = timers.findIndex((t) => t.id === handle);
      if (idx >= 0) timers.splice(idx, 1);
    },
    burstBytes: opts.burst ?? 1000,
    refillBytesPerSec: opts.refillPerSec ?? 100,
    catchUpMs: opts.catchUpMs ?? 1000,
  });
  // Advance the clock and fire every timer that came due, in order. Timer
  // bodies are async (they await compose), so callers settle with `flush`.
  const advance = async (ms: number) => {
    now += ms;
    while (true) {
      const due = timers.filter((t) => t.at <= now).sort((a, b) => a.at - b.at)[0];
      if (!due) break;
      timers.splice(timers.indexOf(due), 1);
      due.fn();
      await flush();
    }
  };
  const flush = () => new Promise<void>((resolve) => setTimeout(resolve, 0));
  return { governor, sent, composed, timers, advance, flush };
}

type OutputGovernorLike = ConstructorParameters<typeof OutputGovernor>[0];

describe("OutputGovernor", () => {
  test("admits output while the burst budget lasts and drops once it is spent", () => {
    const { governor, timers } = harness({ burst: 1000 });
    expect(governor.admit(output("t", 600))).toBe(true);
    expect(governor.admit(output("t", 300))).toBe(true);
    // 100 left: this frame does not fit, and from here the terminal is lagging.
    expect(governor.admit(output("t", 200))).toBe(false);
    expect(governor.admit(output("t", 1))).toBe(false);
    expect(governor.laggingTerminals()).toEqual(["main t"]);
    expect(timers).toHaveLength(1);
  });

  test("frames that are not terminal output always pass, even from a lagging terminal", () => {
    const { governor } = harness({ burst: 10 });
    expect(governor.admit(output("t", 20))).toBe(false);
    expect(governor.admit(createMessage("pong", {}))).toBe(true);
    expect(governor.admit(createMessage("terminal:snapshot", { terminalId: "t", scrollback: "", seq: 1 }))).toBe(true);
    expect(governor.admit(createMessage("terminal:exited", { terminalId: "t", exitCode: 0 }))).toBe(true);
  });

  test("a lagging terminal gets ONE composed screen per interval in place of what was dropped", async () => {
    const { governor, sent, composed, advance } = harness({ burst: 100, refillPerSec: 10, catchUpMs: 1000 });
    expect(governor.admit(output("t", 90))).toBe(true);
    expect(governor.admit(output("t", 50))).toBe(false);
    expect(governor.admit(output("t", 50))).toBe(false);
    expect(sent).toEqual([]);

    await advance(1000);
    expect(composed).toEqual(["main t"]);
    expect(sent).toHaveLength(1);
    expect(sent[0]!.type).toBe("terminal:snapshot");

    // Still over budget (10 bytes/s refilled the 10 left to 20 of a 100 burst;
    // half is 50), and nothing else was dropped since: the interval re-arms but
    // no screen is owed, so none is composed.
    expect(governor.laggingTerminals()).toEqual(["main t"]);
    await advance(1000);
    expect(composed).toHaveLength(1);
    expect(sent).toHaveLength(1);

    // A drop during the interval owes the next one a screen.
    expect(governor.admit(output("t", 1))).toBe(false);
    await advance(1000);
    expect(composed).toHaveLength(2);
    expect(sent).toHaveLength(2);
  });

  test("output resumes once the bucket has refilled to half the burst", async () => {
    const { governor, advance } = harness({ burst: 1000, refillPerSec: 100, catchUpMs: 1000 });
    expect(governor.admit(output("t", 1000))).toBe(true);
    expect(governor.admit(output("t", 1))).toBe(false);

    // 4 catch-ups = 400 bytes refilled, under the 500 threshold.
    await advance(4000);
    expect(governor.laggingTerminals()).toEqual(["main t"]);
    expect(governor.admit(output("t", 1))).toBe(false);

    await advance(1000);
    expect(governor.laggingTerminals()).toEqual([]);
    expect(governor.admit(output("t", 100))).toBe(true);
  });

  test("terminals are budgeted independently, keyed by checkout AND id", () => {
    const { governor } = harness({ burst: 100 });
    expect(governor.admit(output("dev", 200, "wt-1"))).toBe(false);
    // Another checkout's `dev` is a different terminal and starts unshaped.
    expect(governor.admit(output("dev", 50, "wt-2"))).toBe(true);
    expect(governor.admit(output("dev", 50))).toBe(true);
    expect(governor.laggingTerminals()).toEqual(["wt-1 dev"]);
  });

  test("terminal:exited clears the budget and cancels the pending catch-up", async () => {
    const { governor, sent, composed, timers, advance } = harness({ burst: 100 });
    expect(governor.admit(output("t", 200))).toBe(false);
    expect(timers).toHaveLength(1);

    expect(governor.admit(createMessage("terminal:exited", { terminalId: "t", exitCode: 0 }))).toBe(true);
    expect(timers).toHaveLength(0);
    expect(governor.laggingTerminals()).toEqual([]);
    await advance(5000);
    expect(composed).toEqual([]);
    expect(sent).toEqual([]);

    // A restart under the same id starts with a full burst.
    expect(governor.admit(output("t", 100))).toBe(true);
  });

  test("dispose cancels every catch-up and admits everything after", async () => {
    const { governor, sent, timers, advance } = harness({ burst: 100 });
    expect(governor.admit(output("a", 200))).toBe(false);
    expect(governor.admit(output("b", 200))).toBe(false);
    expect(timers).toHaveLength(2);

    governor.dispose();
    expect(timers).toHaveLength(0);
    await advance(5000);
    expect(sent).toEqual([]);
    expect(governor.admit(output("a", 10_000))).toBe(true);
  });

  test("a screen composed for a terminal that exited or was disposed mid-compose is not sent", async () => {
    let release: (() => void) | null = null;
    const { governor, sent, advance, flush } = harness({
      burst: 100,
      compose: (terminalId) => new Promise((resolve) => {
        release = () => resolve(createMessage("terminal:snapshot", { terminalId, scrollback: "", seq: 1, composed: true }));
      }),
    });
    expect(governor.admit(output("t", 200))).toBe(false);
    await advance(1000);
    expect(release).not.toBeNull();

    governor.admit(createMessage("terminal:exited", { terminalId: "t", exitCode: 0 }));
    release!();
    await flush();
    expect(sent).toEqual([]);
  });

  test("a failed compose keeps the screen owed, so the next interval retries", async () => {
    let fail = true;
    const { governor, sent, composed, advance } = harness({
      burst: 100,
      refillPerSec: 1,
      compose: async (terminalId) => {
        composed.push(terminalId);
        if (fail) throw new Error("screen unavailable");
        return createMessage("terminal:snapshot", { terminalId, scrollback: "", seq: 1, composed: true });
      },
    });
    expect(governor.admit(output("t", 200))).toBe(false);
    await advance(1000);
    expect(composed).toEqual(["t"]);
    expect(sent).toEqual([]);

    fail = false;
    await advance(1000);
    expect(composed).toEqual(["t", "t"]);
    expect(sent).toHaveLength(1);
  });
});
