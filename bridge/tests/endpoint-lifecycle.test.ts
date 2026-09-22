import { expect, test } from "bun:test";
import { EndpointFailure, EndpointLifecycle } from "../src/peer/endpoint-lifecycle";
const flush = async () => { for (let i = 0; i < 20; i++) await Promise.resolve(); };
function fixture() {
  const callbacks: (() => void)[] = [], delays: number[] = [], retired: number[] = [];
  const events: Array<{ state: string; reason?: string; detail?: {
    attemptGeneration: number;
    retryReason?: string;
    retryDelayMs?: number;
    teardownReason?: string;
    teardownOutcome?: string;
  } }> = [];
  const listeners = new Map<number, ReturnType<typeof Promise.withResolvers<void>>>();
  let count = 0, now = 0, fail = false;
  const owner = new EndpointLifecycle<number>({
    create: async () => { if (fail) throw new Error("offline"); return ++count; },
    listen: async (id) => { const p = Promise.withResolvers<void>(); listeners.set(id, p); return p.promise; },
    retire: async (id) => { retired.push(id); listeners.get(id)?.resolve(); },
    terminal: (e) => e instanceof EndpointFailure && e.terminal,
    changed: (state, reason, detail) => { events.push({ state, reason, detail }); },
    now: () => now, random: () => 0,
    schedule: (fn, ms) => { callbacks.push(fn); delays.push(ms); return () => { const i = callbacks.indexOf(fn); if (i >= 0) callbacks.splice(i, 1); }; },
  });
  return { owner, callbacks, delays, retired, listeners, events,
    count: () => count, fail: (v: boolean) => fail = v, time: (v: number) => now = v };
}
test("transient startup recovers, healthy listeners reset backoff, stop cancels retry", async () => {
  const f = fixture(); f.fail(true); f.owner.start(); await flush();
  expect(f.owner.state).toBe("backoff"); expect(f.delays).toEqual([500]);
  expect(f.events.find((event) => event.state === "backoff")).toEqual({
    state: "backoff",
    reason: "ENDPOINT_UNAVAILABLE",
    detail: {
      attemptGeneration: 1,
      retryReason: "ENDPOINT_UNAVAILABLE",
      retryDelayMs: 500,
    },
  });
  f.fail(false); f.callbacks.shift()!(); await flush(); expect(f.owner.state).toBe("ready");
  f.listeners.get(1)!.reject(new Error("listener failed")); await flush();
  expect(f.retired).toEqual([1]); expect(f.delays).toEqual([500, 1000]);
  f.callbacks.shift()!(); await flush(); f.time(31_000); f.listeners.get(2)!.resolve(); await flush();
  expect(f.delays).toEqual([500, 1000, 500]);
  await f.owner.stop(); expect(f.callbacks).toHaveLength(0); expect(f.owner.state).toBe("stopped");
  expect(f.events.at(-1)?.detail).toMatchObject({
    teardownReason: "lifecycle-stop",
    teardownOutcome: "complete",
  });
});
test("stop fences late creation without starting a listener", async () => {
  const pending = Promise.withResolvers<number>(); let closed = 0, listening = 0;
  const owner = new EndpointLifecycle({ create: () => pending.promise, listen: async () => { listening++; },
    retire: async () => { closed++; }, terminal: () => false });
  owner.start(); owner.start();
  const stopped = owner.stop();
  expect(owner.stop()).toBe(stopped);
  let settled = false; void stopped.then(() => { settled = true; });
  await flush(); expect(settled).toBe(false);
  pending.resolve(1); await stopped;
  expect(closed).toBe(1); expect(listening).toBe(0); expect(owner.state).toBe("stopped");
});
test("restart retires previous listener before replacement and terminal failure blocks", async () => {
  const f = fixture(); f.owner.start(); await flush(); f.owner.restart(); await flush();
  expect(f.retired).toEqual([1]); expect(f.count()).toBe(2); expect(f.owner.state).toBe("ready");
  f.listeners.get(2)!.reject(new EndpointFailure("DENIED", true)); await flush();
  expect(f.owner.state).toBe("blocked"); expect(f.callbacks).toHaveLength(0);
  f.owner.retry(); await flush(); expect(f.count()).toBe(3); f.owner.stop(); await flush();
});
test("creation stays single-flight across restart", async () => {
  const pending = Promise.withResolvers<number>(); let calls = 0; const closed: number[] = [];
  const owner = new EndpointLifecycle({ create: () => { calls++; return calls === 1 ? pending.promise : Promise.resolve(2); },
    listen: () => new Promise<void>(() => {}), retire: async (id) => { closed.push(id); }, terminal: () => false });
  owner.start(); owner.restart(); owner.restart(); await flush(); expect(calls).toBe(1);
  pending.resolve(1); await flush(); expect(calls).toBe(2); expect(closed).toEqual([1]); owner.stop();
});
