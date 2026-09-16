import { expect, test } from "bun:test";
import { createAgentRunScope } from "../src/run-scope";

test("cleanup can reenter disposal without replacing its completion", async () => {
  const scope = createAgentRunScope({ runId: "one", isCurrent: () => true, emit: () => {} });
  let reentered: Promise<void> | undefined;
  const cleanup = () => { reentered = scope.dispose(); };
  scope.registerCleanup(cleanup);
  scope.registerCleanup(cleanup);
  const done = scope.dispose();
  expect(reentered).toBe(done);
  await done;
});

test("cancellation rejects stale events and attempts every cleanup in reverse order", async () => {
  const events: string[] = [];
  const released: number[] = [];
  const scope = createAgentRunScope<string>({ runId: "one", isCurrent: () => true, emit: (e) => events.push(e) });
  scope.registerCleanup(() => { released.push(1); });
  scope.registerCleanup(() => { released.push(2); throw new Error("held"); });
  scope.emit("ready");
  scope.cancel();
  scope.emit("late");
  await expect(scope.dispose()).rejects.toThrow("Agent resource release failed");
  expect(released).toEqual([2, 1]);
  expect(events).toEqual(["ready"]);
});

test("late acquisition cleanup remains part of disposal", async () => {
  let acquire!: () => void;
  let release!: () => void;
  let disposed = false;
  const scope = createAgentRunScope({ runId: "one", isCurrent: () => true, emit: () => {} });
  const acquisition = new Promise<void>((resolve) => { acquire = resolve; });
  scope.track(acquisition.then(() => scope.registerCleanup(() => new Promise<void>((resolve) => { release = resolve; }))));
  const done = scope.dispose().then(() => { disposed = true; });
  acquire();
  await acquisition;
  await Promise.resolve();
  expect(disposed).toBe(false);
  release();
  await done;
  expect(scope.dispose()).toBe(scope.dispose());
});
