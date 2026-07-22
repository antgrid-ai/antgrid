import { describe, expect, it } from "bun:test";
import { buildFragments } from "antgrid-wire";
import { FragReassembler } from "../src/frag-reassembler";

function mk(json: string, id: string) {
  return buildFragments(json, id, undefined, 1000);
}

describe("FragReassembler", () => {
  it("reassembles in-order fragments and dispatches the original JSON once", () => {
    const json = JSON.stringify({ type: "x", blob: "y".repeat(2500) });
    const done: string[] = [];
    const r = new FragReassembler({
      timeoutMs: 1000,
      globalBudgetBytes: 1e7,
      onComplete: (j) => done.push(j),
      onAbort: () => {},
      now: () => 0,
    });

    for (const f of mk(json, "t1")) expect(r.accept(f)).toBe(true);

    expect(done).toEqual([json]);
  });

  it("returns false for a non-fragment plaintext", () => {
    const r = new FragReassembler({
      timeoutMs: 1000,
      globalBudgetBytes: 1e7,
      onComplete: () => {},
      onAbort: () => {},
      now: () => 0,
    });

    expect(r.accept(JSON.stringify({ type: "file:content" }))).toBe(false);
  });

  it("consumes malformed marker JSON without completing", () => {
    const done: string[] = [];
    const r = new FragReassembler({
      timeoutMs: 1000,
      globalBudgetBytes: 1e7,
      onComplete: (j) => done.push(j),
      onAbort: () => {},
      now: () => 0,
    });

    expect(r.accept('{"__frag"')).toBe(true);
    expect(done).toEqual([]);
  });

  it("consumes invalid marker shape without completing", () => {
    const done: string[] = [];
    const r = new FragReassembler({
      timeoutMs: 1000,
      globalBudgetBytes: 1e7,
      onComplete: (j) => done.push(j),
      onAbort: () => {},
      now: () => 0,
    });

    expect(r.accept(JSON.stringify({ __frag: { id: "t1", i: 0 }, data: "x" }))).toBe(true);
    expect(done).toEqual([]);
  });

  it("rejects an envelope whose n exceeds MAX_FRAGMENT_COUNT without allocating", () => {
    const done: string[] = [];
    const r = new FragReassembler({
      timeoutMs: 1000,
      globalBudgetBytes: 1e7,
      onComplete: (j) => done.push(j),
      onAbort: () => {},
      now: () => 0,
    });

    const hostile = JSON.stringify({ __frag: { id: "h", i: 0, n: 1e9 }, data: "x" });
    expect(r.accept(hostile)).toBe(true);
    expect(done).toEqual([]);
  });

  it("handles out-of-order and duplicate fragments", () => {
    const json = JSON.stringify({ type: "x", blob: "z".repeat(2500) });
    const frames = mk(json, "t2");
    const done: string[] = [];
    const r = new FragReassembler({
      timeoutMs: 1000,
      globalBudgetBytes: 1e7,
      onComplete: (j) => done.push(j),
      onAbort: () => {},
      now: () => 0,
    });

    r.accept(frames[2]);
    r.accept(frames[0]);
    r.accept(frames[0]);
    r.accept(frames[1]);

    expect(done).toEqual([json]);
  });

  it("aborts a stalled partial on sweep, emitting the hint from a received fragment", () => {
    const json = JSON.stringify({ type: "file:content", path: "a.png", blob: "q".repeat(2500) });
    const frames = buildFragments(json, "t3", { type: "file:content", key: "a.png" }, 1000);
    const aborts: Array<{ type: string; key: string } | null> = [];
    let clock = 0;
    const r = new FragReassembler({
      timeoutMs: 1000,
      globalBudgetBytes: 1e7,
      onComplete: () => {},
      onAbort: (h) => aborts.push(h),
      now: () => clock,
    });

    r.accept(frames[1]);
    clock = 2000;
    r.sweep();

    expect(aborts).toEqual([{ type: "file:content", key: "a.png" }]);
  });
});
