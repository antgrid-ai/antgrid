// bridge/tests/handler/lifecycle.test.ts
import { test, expect, describe, it } from "bun:test";
import {
  LIMIT_FALLBACK_MS,
  TRANSIENT_CEILING,
  transientBackoffMs,
  defaultSchedule,
  TimerRegistry,
  type LifecycleDeps,
} from "../../src/handler/lifecycle";

interface FakeTimer { ms: number; fn: () => void; cancelled: number; }

function fakeScheduler() {
  const timers: FakeTimer[] = [];
  const schedule: LifecycleDeps["schedule"] = (ms, fn) => {
    const t: FakeTimer = { ms, fn, cancelled: 0 };
    timers.push(t);
    return () => { t.cancelled += 1; };
  };
  return { timers, deps: { now: () => 1_000, schedule } satisfies LifecycleDeps };
}

describe("constants", () => {
  it("holds the 30-minute limit fallback and a ceiling of 3", () => {
    expect(LIMIT_FALLBACK_MS).toBe(30 * 60_000);
    expect(TRANSIENT_CEILING).toBe(3);
  });
});

describe("transientBackoffMs", () => {
  it("runs 30s, 2m, 8m", () => {
    expect(transientBackoffMs(1)).toBe(30_000);
    expect(transientBackoffMs(2)).toBe(120_000);
    expect(transientBackoffMs(3)).toBe(480_000);
  });

  it("stays geometric past the ceiling so raising it extends the series", () => {
    expect(transientBackoffMs(4)).toBe(1_920_000);
  });
});

describe("TimerRegistry", () => {
  it("arms a timer with the requested delay", () => {
    const { timers, deps } = fakeScheduler();
    const reg = new TimerRegistry(deps);
    let fired = 0;
    reg.arm("t1", 30_000, () => { fired += 1; });

    expect(timers).toHaveLength(1);
    expect(timers[0]!.ms).toBe(30_000);
    timers[0]!.fn();
    expect(fired).toBe(1);
  });

  it("re-arming a key cancels the timer it replaces", () => {
    const { timers, deps } = fakeScheduler();
    const reg = new TimerRegistry(deps);
    reg.arm("t1", 30_000, () => {});
    reg.arm("t1", 120_000, () => {});

    expect(timers).toHaveLength(2);
    expect(timers[0]!.cancelled).toBe(1);
    expect(timers[1]!.cancelled).toBe(0);
  });

  it("keys are independent", () => {
    const { timers, deps } = fakeScheduler();
    const reg = new TimerRegistry(deps);
    reg.arm("t1", 30_000, () => {});
    reg.arm("t2", 30_000, () => {});
    reg.cancel("t1");

    expect(timers[0]!.cancelled).toBe(1);
    expect(timers[1]!.cancelled).toBe(0);
  });

  it("cancel is idempotent and safe on an unknown key", () => {
    const { timers, deps } = fakeScheduler();
    const reg = new TimerRegistry(deps);
    reg.arm("t1", 30_000, () => {});
    reg.cancel("t1");
    reg.cancel("t1");
    expect(() => reg.cancel("never-armed")).not.toThrow();
    expect(timers[0]!.cancelled).toBe(1);
  });

  it("a cancelled timer never fires", () => {
    const { timers, deps } = fakeScheduler();
    const reg = new TimerRegistry(deps);
    let fired = 0;
    reg.arm("t1", 30_000, () => { fired += 1; });
    reg.cancel("t1");
    expect(timers[0]!.cancelled).toBe(1);
    expect(fired).toBe(0);
  });

  it("cancelAll cancels every armed key", () => {
    const { timers, deps } = fakeScheduler();
    const reg = new TimerRegistry(deps);
    reg.arm("t1", 30_000, () => {});
    reg.arm("t2", 120_000, () => {});
    reg.arm("t3", 480_000, () => {});
    reg.cancelAll();

    expect(timers.map((t) => t.cancelled)).toEqual([1, 1, 1]);
    reg.cancel("t1");
    expect(timers[0]!.cancelled).toBe(1);
  });

  it("a fired timer drops its own entry, so a later cancel is a no-op", () => {
    const { timers, deps } = fakeScheduler();
    const reg = new TimerRegistry(deps);
    reg.arm("t1", 30_000, () => {});
    timers[0]!.fn();

    reg.cancel("t1");
    reg.cancelAll();
    expect(timers[0]!.cancelled).toBe(0);
  });

  it("a callback may re-arm its own key while firing", () => {
    const { timers, deps } = fakeScheduler();
    const reg = new TimerRegistry(deps);
    reg.arm("t1", 30_000, () => reg.arm("t1", 120_000, () => {}));
    timers[0]!.fn();

    expect(timers).toHaveLength(2);
    expect(timers[1]!.ms).toBe(120_000);
    expect(timers[0]!.cancelled).toBe(0); // the firing timer is not its own replacement's victim
    expect(timers[1]!.cancelled).toBe(0);
  });
});

describe("defaultSchedule", () => {
  it("unrefs the timer so a parked session cannot hold the process open", () => {
    const real = globalThis.setTimeout;
    let unrefs = 0;
    const handle = { unref: () => { unrefs += 1; return handle; } };
    (globalThis as unknown as { setTimeout: unknown }).setTimeout = () => handle;
    try {
      defaultSchedule(30_000, () => {});
    } finally {
      globalThis.setTimeout = real;
    }
    expect(unrefs).toBe(1);
  });

  it("fires after the delay and its cancel stops it", async () => {
    let fired = 0;
    defaultSchedule(1, () => { fired += 1; });
    const cancel = defaultSchedule(1, () => { fired += 10; });
    cancel();
    await new Promise((r) => setTimeout(r, 20));
    expect(fired).toBe(1);
  });
});
