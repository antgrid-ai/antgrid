import { describe, expect, test } from "bun:test";

import { TitleAttempts } from "../src/agents/title-attempts";

const T = "term-1";
const C = "conv-1";

describe("mutual exclusion", () => {
  // The half a bare retry count cannot express: two turns ending at once must
  // not both spawn, and the second is refused while the first is still running
  // even though it has failed nothing.
  test("a claim excludes a second spawn until it settles", () => {
    const a = new TitleAttempts();
    expect(a.begin(T, C)).toBe(true);
    expect(a.begin(T, C)).toBe(false);
    expect(a.refused(T, C)).toBe(true);
    a.settle(T, C, "failed");
    expect(a.begin(T, C)).toBe(true);
  });

  test("a claim on one conversation leaves the others alone", () => {
    const a = new TitleAttempts();
    a.begin(T, C);
    expect(a.begin(T, "conv-2")).toBe(true);
    expect(a.begin("term-2", C)).toBe(true);
  });
});

describe("budget", () => {
  // The regression this class was written for: a spawn that failed used to mark
  // the conversation spent, so a session whose CLI was merely signed out could
  // never be named afterwards — not even once the user logged in.
  test("a failure is retriable, and the budget is bounded", () => {
    const a = new TitleAttempts(2);
    a.begin(T, C);
    a.settle(T, C, "failed");
    expect(a.refused(T, C)).toBe(false);

    a.begin(T, C);
    a.settle(T, C, "failed");
    expect(a.refused(T, C)).toBe(true);
    expect(a.begin(T, C)).toBe(false);
  });

  test("an unavailable verdict ends the budget outright", () => {
    // Nothing installed can serve the call, so a retry would re-read a
    // transcript every turn to reach the same refusal.
    const a = new TitleAttempts(2);
    a.begin(T, C);
    a.settle(T, C, "unavailable");
    expect(a.refused(T, C)).toBe(true);
  });

  test("a name is final", () => {
    const a = new TitleAttempts();
    a.begin(T, C);
    a.settle(T, C, "named");
    expect(a.refused(T, C)).toBe(true);
  });

  // A title discarded because the user renamed the session mid-spawn says
  // nothing about whether generation works, so it must not consume budget —
  // only release the claim.
  test("an abandoned attempt costs nothing", () => {
    const a = new TitleAttempts(2);
    for (let i = 0; i < 5; i++) {
      expect(a.begin(T, C)).toBe(true);
      a.settle(T, C, "abandoned");
    }
    expect(a.refused(T, C)).toBe(false);
  });
});

describe("forget", () => {
  test("clears a terminal's conversations, and only that terminal's", () => {
    const a = new TitleAttempts();
    a.begin(T, C);
    a.settle(T, C, "named");
    a.begin("term-2", C);
    a.settle("term-2", C, "named");

    a.forget(T);
    expect(a.refused(T, C)).toBe(false);
    expect(a.refused("term-2", C)).toBe(true);
  });

  // Terminal ids carry colons of their own (`<checkoutId>:setup`), which is why
  // the state is nested rather than held under a flat `<terminal>:<conv>` key —
  // in a flat key space this release would reach the other terminal by prefix.
  test("a release does not reach a terminal whose id extends it", () => {
    const a = new TitleAttempts();
    a.begin("chk", C);
    a.settle("chk", C, "named");
    a.begin("chk:setup", C);
    a.settle("chk:setup", C, "named");

    a.forget("chk");
    expect(a.refused("chk:setup", C)).toBe(true);
  });
});

describe("settle without a claim", () => {
  test("is a no-op rather than a phantom failure", () => {
    // forget() can land between a claim and its settle (terminal exit while a
    // spawn is in flight); the late settle must not resurrect the entry.
    const a = new TitleAttempts(1);
    a.begin(T, C);
    a.forget(T);
    a.settle(T, C, "failed");
    expect(a.refused(T, C)).toBe(false);
  });
});
