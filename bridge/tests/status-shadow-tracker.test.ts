import { describe, expect, test } from "bun:test";
import { MIN_TIMER_MS, StatusShadowTracker } from "../src/status-shadow-tracker";
import { DISAGREEMENT_GRACE_MS, TITLE_IDLE_DEBOUNCE_MS, type ShadowLine } from "../src/status-shadow";
import type { WorkStatus } from "../src/protocol";

const ID = "t1";

function rig(oldFn?: (id: string) => WorkStatus | undefined) {
  let clock = 0;
  let old: WorkStatus | undefined = "working";
  let oldCalls = 0;
  const lines: ShadowLine[] = [];
  const warns: Array<{ fields: Record<string, unknown>; msg: string }> = [];
  const timers = new Map<number, { fn: () => void; ms: number }>();
  let nextTimer = 1;
  const tracker = new StatusShadowTracker({
    oldStatusFor: (id) => {
      oldCalls++;
      return oldFn ? oldFn(id) : old;
    },
    now: () => clock,
    setTimer: (fn, ms) => {
      const h = nextTimer++;
      timers.set(h, { fn, ms });
      return h;
    },
    clearTimer: (h) => {
      timers.delete(h as number);
    },
    write: (l) => lines.push(l),
    warn: (fields, msg) => warns.push({ fields, msg }),
  });
  return {
    tracker,
    lines,
    warns,
    timers,
    setNow: (n: number) => (clock = n),
    setOld: (o: WorkStatus | undefined) => (old = o),
    oldCalls: () => oldCalls,
    fire: () => {
      const [h, t] = [...timers.entries()][0]!;
      timers.delete(h);
      t.fn();
    },
  };
}

describe("StatusShadowTracker", () => {
  test("timer exists only while a deadline is pending, and firing emits the onset", () => {
    const r = rig();
    const src = {};
    r.tracker.track(ID, "claude-code", src);
    expect(r.timers.size).toBe(0);
    r.tracker.title(ID, src, "◐ x");
    r.setOld("done");
    r.tracker.reconcile();
    expect(r.timers.size).toBe(1);
    expect([...r.timers.values()][0]!.ms).toBe(DISAGREEMENT_GRACE_MS);
    r.setNow(DISAGREEMENT_GRACE_MS);
    r.fire();
    expect(r.lines).toHaveLength(1);
    expect(r.lines[0]!.msg).toBe("status shadow: disagreement");
    expect(r.timers.size).toBe(0);
  });

  test("a timer that fires early re-arms at the floor and still emits the onset", () => {
    const r = rig(() => "done");
    const src = {};
    r.tracker.track(ID, "claude-code", src);
    r.tracker.title(ID, src, "◐ x");
    r.setNow(DISAGREEMENT_GRACE_MS - 1);
    r.fire();
    expect(r.lines).toHaveLength(0);
    expect(r.timers.size).toBe(1);
    expect([...r.timers.values()][0]!.ms).toBe(MIN_TIMER_MS);
    r.setNow(DISAGREEMENT_GRACE_MS);
    r.fire();
    expect(r.lines).toHaveLength(1);
  });

  test("a compare that keeps throwing re-arms at the floor, never in a tight loop", () => {
    let broken = false;
    const r = rig(() => {
      if (broken) throw new Error("boom");
      return "working";
    });
    const src = {};
    r.tracker.track(ID, "claude-code", src);
    r.tracker.title(ID, src, "◐ x");
    r.tracker.title(ID, src, "✳ x");
    expect(r.timers.size).toBe(1);
    // The debounce deadline is now past due, and the compare that would drop it fails.
    broken = true;
    r.setNow(10 * TITLE_IDLE_DEBOUNCE_MS);
    for (let i = 0; i < 3; i++) {
      r.fire();
      const [t] = [...r.timers.values()];
      expect(t!.ms).toBe(MIN_TIMER_MS);
      expect(t!.ms).toBeGreaterThanOrEqual(100);
    }
  });

  test("the debounce deadline arms a timer that fires into reconcile", () => {
    const r = rig(() => "working");
    const src = {};
    r.tracker.track(ID, "claude-code", src);
    r.tracker.title(ID, src, "◐ x");
    r.setNow(100);
    r.tracker.title(ID, src, "✳ x");
    expect([...r.timers.values()][0]!.ms).toBe(TITLE_IDLE_DEBOUNCE_MS);
    const before = r.oldCalls();
    r.setNow(100 + TITLE_IDLE_DEBOUNCE_MS);
    r.fire();
    expect(r.oldCalls()).toBe(before + 1);
    // The expired debounce leaves old working against shadow idle, which opens a span.
    expect(r.timers.size).toBe(1);
    expect([...r.timers.values()][0]!.ms).toBe(DISAGREEMENT_GRACE_MS);
  });

  test("reset clears the timer", () => {
    const r = rig(() => "done");
    const src = {};
    r.tracker.track(ID, "claude-code", src);
    r.tracker.title(ID, src, "◐ x");
    expect(r.timers.size).toBe(1);
    r.tracker.reset();
    expect(r.timers.size).toBe(0);
  });

  test("titles from a stale source are ignored after a re-track", () => {
    const r = rig(() => "done");
    const first = {};
    const second = {};
    r.tracker.track(ID, "claude-code", first);
    r.tracker.track(ID, "claude-code", second);
    r.tracker.title(ID, first, "◐ x");
    expect(r.timers.size).toBe(0);
    r.tracker.title(ID, second, "◐ x");
    expect(r.timers.size).toBe(1);
  });

  test("errors never escape, warn once, and exit reports the exact count", () => {
    const r = rig(() => {
      throw new Error("boom");
    });
    const src = {};
    r.tracker.track(ID, "claude-code", src);
    expect(() => {
      r.tracker.title(ID, src, "◐ x");
      for (let i = 0; i < 49; i++) r.tracker.reconcile();
    }).not.toThrow();
    expect(r.warns).toHaveLength(1);
    expect(r.warns[0]!.msg).toBe("status shadow: dropped");
    r.tracker.exited(ID);
    // One throw from the title's compare plus one per reconcile.
    expect(r.lines.find((l) => l.msg === "status shadow: errors suppressed")!.fields.errors).toBe(50);
  });

  test("a burst of same-class titles makes no oldStatusFor calls", () => {
    const r = rig();
    const src = {};
    r.tracker.track(ID, "claude-code", src);
    r.tracker.title(ID, src, "◐ x");
    const before = r.oldCalls();
    for (let i = 0; i < 100; i++) r.tracker.title(ID, src, "◑ x");
    expect(r.oldCalls()).toBe(before);
  });

  test("input on an untracked id makes no calls", () => {
    const r = rig();
    r.tracker.input("nobody", "\x1b", "user");
    expect(r.oldCalls()).toBe(0);
    expect(r.timers.size).toBe(0);
  });

  test("input on a tracked id reaches the fold", () => {
    const r = rig(() => "working");
    const src = {};
    r.tracker.track(ID, "claude-code", src);
    r.tracker.title(ID, src, "◐ x");
    const before = r.oldCalls();
    r.tracker.input(ID, "\x1b", "user");
    expect(r.oldCalls()).toBeGreaterThan(before);
    const calls = r.oldCalls();
    r.tracker.input(ID, "zz", "user");
    expect(r.oldCalls()).toBe(calls);
  });

  test("titleQuietMs is on the onset line", () => {
    const r = rig(() => "done");
    const src = {};
    r.tracker.track(ID, "claude-code", src);
    r.tracker.title(ID, src, "◐ x");
    r.setNow(DISAGREEMENT_GRACE_MS);
    r.fire();
    expect(r.lines[0]!.fields.titleQuietMs).toBe(DISAGREEMENT_GRACE_MS);
  });

  test("exit resolves an emitted span with to: exit and drops the timer", () => {
    const r = rig(() => "done");
    const src = {};
    r.tracker.track(ID, "claude-code", src);
    r.tracker.title(ID, src, "◐ x");
    r.setNow(DISAGREEMENT_GRACE_MS);
    r.fire();
    r.tracker.exited(ID);
    expect(r.lines.at(-1)!.fields.to).toBe("exit");
    expect(r.timers.size).toBe(0);
    r.tracker.exited(ID);
  });
});
