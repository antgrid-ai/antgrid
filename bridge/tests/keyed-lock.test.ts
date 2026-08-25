// The mechanism that keeps a checkout's runtime build from interleaving with
// its teardown. That interleave is what strands an isolated session
// undeletable: a start resuming from a suspension arms a watcher inside the
// directory `git worktree remove` is sweeping, and the runtime is out of the
// registry by then, so nothing can ever close that handle again.
import { describe, expect, test } from "bun:test";
import { createKeyedLock } from "../src/keyed-lock";

const tick = (ms = 0) => new Promise((resolve) => setTimeout(resolve, ms));

describe("createKeyedLock", () => {
  test("operations sharing a key never overlap", async () => {
    const withLock = createKeyedLock();
    const order: string[] = [];
    const op = (name: string, ms: number) => withLock("k", async () => {
      order.push(`${name}:start`);
      await tick(ms);
      order.push(`${name}:end`);
    });
    // Second queued while the first is mid-suspension — the delete-during-start
    // shape exactly. Slowest first, so a broken lock interleaves visibly.
    await Promise.all([op("build", 30), op("teardown", 0)]);
    expect(order).toEqual(["build:start", "build:end", "teardown:start", "teardown:end"]);
  });

  test("a rejected operation still serializes the next one, and only its own caller sees the error", async () => {
    const withLock = createKeyedLock();
    const order: string[] = [];
    const failing = withLock("k", async () => {
      order.push("fail:start");
      await tick(20);
      order.push("fail:end");
      throw new Error("teardown exploded");
    });
    const next = withLock("k", async () => { order.push("next:start"); });
    // The failure belongs to whoever asked for it. A delete that throws must
    // not reject the rebuild queued behind it.
    await expect(failing).rejects.toThrow("teardown exploded");
    await next;
    expect(order).toEqual(["fail:start", "fail:end", "next:start"]);
  });

  test("different keys do not wait on each other", async () => {
    const withLock = createKeyedLock();
    const order: string[] = [];
    await Promise.all([
      withLock("a", async () => { order.push("a:start"); await tick(30); order.push("a:end"); }),
      withLock("b", async () => { order.push("b:start"); await tick(0); order.push("b:end"); }),
    ]);
    // b must finish inside a's window — one checkout's delete cannot be made to
    // wait on another checkout's build.
    expect(order).toEqual(["a:start", "b:start", "b:end", "a:end"]);
  });

  test("a queued operation is not skipped when the one ahead of it settles", async () => {
    const withLock = createKeyedLock();
    const order: string[] = [];
    // Three deep: the chain entry is replaced twice, so a cleanup that deletes
    // the map key unconditionally lets the third start early.
    const ops = ["one", "two", "three"].map((name) =>
      withLock("k", async () => { order.push(`${name}:start`); await tick(10); order.push(`${name}:end`); }));
    await Promise.all(ops);
    expect(order).toEqual([
      "one:start", "one:end", "two:start", "two:end", "three:start", "three:end",
    ]);
  });

  test("the chain map does not grow once work has drained", async () => {
    const withLock = createKeyedLock();
    for (let i = 0; i < 5; i++) await withLock(`k${i}`, async () => { await tick(0); });
    // Nothing is queued, so a later caller for a used key must start straight
    // away rather than chain onto a settled promise that was never released.
    let started = false;
    const run = withLock("k0", async () => { started = true; });
    await tick(0);
    expect(started).toBe(true);
    await run;
  });
});
