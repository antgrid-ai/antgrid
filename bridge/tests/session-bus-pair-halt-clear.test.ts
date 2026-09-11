// bridge/tests/session-bus-pair-halt-clear.test.ts
//
// A halt is per pair, and the pair keeps a mirror of it at each end
// (`pair-budget.ts`'s header). Lifting only the session a human happened to
// type in leaves the peer refusing every send on a pair that has been cleared —
// the asymmetry `PairBudgetStore.clearHalt` closes for both mirrors this
// machine holds.
import { test, expect } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { PairBudgetStore } from "../src/host-server";
import {
  budgetFor,
  emptyPairBudget,
  loadPairBudgets,
  noteExchange,
  pairKey,
  savePairBudgets,
  type PairBudgetState,
} from "../src/session-bus/pair-budget";
import { NO_PROGRESS_EXCHANGES } from "../src/session-bus/constants";

const T0 = 5_000_000;
const LOCAL = "m1";
const KEY = pairKey({ machineId: LOCAL, sessionId: "s1" }, { machineId: LOCAL, sessionId: "s2" });

function halted(key: string): PairBudgetState {
  let s = emptyPairBudget(key);
  for (let i = 0; i < NO_PROGRESS_EXCHANGES; i += 1) s = noteExchange(s, T0);
  return s;
}

function withStore(run: (store: PairBudgetStore, abDir: string) => void): void {
  const abDir = mkdtempSync(join(tmpdir(), "ab-bus-halt-clear-"));
  try {
    run(new PairBudgetStore(abDir, () => "p1", () => T0), abDir);
  } finally {
    rmSync(abDir, { recursive: true, force: true });
  }
}

test("clearing a halt in one session lifts the peer's mirror of the same pair", () => {
  withStore((store, abDir) => {
    savePairBudgets(abDir, "p1", "s1", [halted(KEY)]);
    savePairBudgets(abDir, "p1", "s2", [halted(KEY)]);

    store.clearHalt("s1");

    // On disk, because a halt "cleared only by a human" is written through
    // rather than left to a throttle window.
    for (const sessionId of ["s1", "s2"]) {
      const record = budgetFor(loadPairBudgets(abDir, "p1", sessionId, T0), KEY);
      expect(record.haltedAt).toBeNull();
      expect(record.exchangesSinceProgress).toBe(0);
    }
  });
});

test("only the cleared pair is lifted — another peer's halt in the same session stands", () => {
  withStore((store, abDir) => {
    const other = pairKey({ machineId: LOCAL, sessionId: "s2" }, { machineId: LOCAL, sessionId: "s3" });
    savePairBudgets(abDir, "p1", "s1", [halted(KEY)]);
    savePairBudgets(abDir, "p1", "s2", [halted(KEY), halted(other)]);

    store.clearHalt("s1");

    expect(budgetFor(loadPairBudgets(abDir, "p1", "s2", T0), KEY).haltedAt).toBeNull();
    // s2 is halted against s3 as well, and nothing about s1 says a human
    // cleared that one.
    expect(budgetFor(loadPairBudgets(abDir, "p1", "s2", T0), other).haltedAt).toBe(T0);
  });
});

test("a pair whose other end is on another machine clears what it can and touches nothing else", () => {
  withStore((store, abDir) => {
    const remote = pairKey({ machineId: LOCAL, sessionId: "s1" }, { machineId: "m2", sessionId: "far" });
    savePairBudgets(abDir, "p1", "s1", [halted(remote)]);

    store.clearHalt("s1");

    expect(budgetFor(loadPairBudgets(abDir, "p1", "s1", T0), remote).haltedAt).toBeNull();
    // The far end's mirror is unreachable from here — a human working in that
    // session is what lifts it — and no row is invented for it.
    expect(loadPairBudgets(abDir, "p1", "far", T0)).toEqual([]);
  });
});
