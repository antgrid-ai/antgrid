import { describe, it, expect, beforeEach } from "bun:test";
import { ConnState, createConnState } from "../src/conn-state";

describe("ConnState", () => {
  let state: ConnState;
  beforeEach(() => { state = createConnState(); });

  it("starts unsuppressed (focused + peer online) with zero seq", () => {
    expect(state.appFocusPaused).toBe(false);
    expect(state.peerOnline).toBe(true);
    expect(state.suppressed).toBe(false);
    expect(state.fileSeq("any")).toBe(0);
    expect(state.terminalSeq("any")).toBe(0);
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

  it("bumpFileSeq counts each watched root independently", () => {
    expect(state.bumpFileSeq("/a")).toBe(1);
    expect(state.bumpFileSeq("/a")).toBe(2);
    // A sibling worktree's churn must not advance this root's revision: that
    // is the whole reason a resuming client's "still at 2?" can match on an
    // idle checkout of a project whose other checkouts are busy.
    expect(state.bumpFileSeq("/b")).toBe(1);
    expect(state.fileSeq("/a")).toBe(2);
    expect(state.fileSeq("/b")).toBe(1);
    expect(state.fileSeq("/never-watched")).toBe(0);
  });

  it("clearTerminal removes a terminal's seq state", () => {
    state.bumpTerminalSeq("t1");
    state.bumpTerminalSeq("t1");
    state.clearTerminal("t1");
    expect(state.terminalSeq("t1")).toBe(0);
  });
});
