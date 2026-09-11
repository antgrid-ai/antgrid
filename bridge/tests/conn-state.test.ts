import { describe, it, expect, beforeEach } from "bun:test";
import { ConnState, createConnState } from "../src/conn-state";

describe("ConnState", () => {
  let state: ConnState;
  beforeEach(() => { state = createConnState(); });

  it("starts unsuppressed (focused + peer online) with zero terminal seq", () => {
    expect(state.appFocusPaused).toBe(false);
    expect(state.peerOnline).toBe(true);
    expect(state.suppressed).toBe(false);
    expect(state.terminalSeq("any")).toBe(0);
  });

  it("seeds each root's file seq on first touch so a restart never re-reaches an app's remembered one", () => {
    // Two lives of the bridge answering `sinceSeq` from the same 0 would call a
    // changed tree unchanged. Not pinned to any value — only to being an
    // integer the wire schema accepts and to differing across creations.
    const seeds = new Set(
      Array.from({ length: 8 }, () => createConnState().fileSeq("root")),
    );
    for (const seed of seeds) {
      expect(Number.isInteger(seed)).toBe(true);
      expect(seed).toBeGreaterThanOrEqual(0);
    }
    expect(seeds.size).toBeGreaterThan(1);
    expect(createConnState({ fileSeqBase: 7 }).fileSeq("root")).toBe(7);

    // A second root seeds independently of the first, and a repeat query
    // holds the same value rather than re-seeding on every call.
    const state = createConnState();
    const first = state.fileSeq("a");
    expect(state.fileSeq("a")).toBe(first);
    expect(state.fileSeq("b")).not.toBe(first);
  });

  it("focus pause suppresses and resumes independently of peer presence", () => {
    state.appFocusPaused = true;
    expect(state.suppressed).toBe(true);
    state.appFocusPaused = false;
    expect(state.suppressed).toBe(false);
  });

  it("peer-offline suppresses; peer-online restores the declared focus", () => {
    state.peerOnline = false;
    expect(state.suppressed).toBe(true);
    // Online resumes only if focused — the offline window must not clobber it.
    state.peerOnline = true;
    expect(state.suppressed).toBe(false);

    // A phone that was backgrounded stays suppressed across an offline blip.
    state.appFocusPaused = true;
    state.peerOnline = false;
    expect(state.suppressed).toBe(true);
    state.peerOnline = true;
    expect(state.suppressed).toBe(true);
  });

  it("bumpTerminalSeq increments per terminal id independently", () => {
    expect(state.bumpTerminalSeq("t1")).toBe(1);
    expect(state.bumpTerminalSeq("t1")).toBe(2);
    expect(state.bumpTerminalSeq("t2")).toBe(1);
    expect(state.terminalSeq("t1")).toBe(2);
    expect(state.terminalSeq("t2")).toBe(1);
  });

  it("bumpFileSeq counts each watched root independently, from its own seed", () => {
    const seeded = createConnState({ fileSeqBase: 0 });
    expect(seeded.bumpFileSeq("/a")).toBe(1);
    expect(seeded.bumpFileSeq("/a")).toBe(2);
    // A sibling worktree's churn must not advance this root's revision: that
    // is the whole reason a resuming client's "still at 2?" can match on an
    // idle checkout of a project whose other checkouts are busy.
    expect(seeded.bumpFileSeq("/b")).toBe(1);
    expect(seeded.fileSeq("/a")).toBe(2);
    expect(seeded.fileSeq("/b")).toBe(1);
    // Queried, never bumped: seeded on this first touch, same on every repeat.
    const neverBumped = seeded.fileSeq("/never-bumped");
    expect(seeded.fileSeq("/never-bumped")).toBe(neverBumped);
  });

  it("clearTerminal removes a terminal's seq state", () => {
    state.bumpTerminalSeq("t1");
    state.bumpTerminalSeq("t1");
    state.clearTerminal("t1");
    expect(state.terminalSeq("t1")).toBe(0);
  });
});
