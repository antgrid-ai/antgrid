import { describe, expect, test } from "bun:test";
import {
  CHECKOUT_MAX_TIER_INDEX,
  GIT_POLL_TIERS,
  MAIN_MAX_TIER_INDEX,
  createGitPollCadence,
  noteGitPollResult,
  resetGitPollCadence,
  shouldRunPollTick,
  type GitPollCadence,
} from "../src/git-poll-cadence";

/** Ticks the cadence `count` times and returns how many of them ran, folding
 *  each run's outcome back in exactly the way agent-core's interval does. */
function runTicks(
  cadence: GitPollCadence,
  count: number,
  outcome: { changed: boolean; attended: boolean; maxTierIndex: number },
): number {
  let ran = 0;
  for (let i = 0; i < count; i++) {
    if (!shouldRunPollTick(cadence)) continue;
    ran++;
    noteGitPollResult(cadence, outcome);
  }
  return ran;
}

const unattendedIdle = {
  changed: false,
  attended: false,
  maxTierIndex: CHECKOUT_MAX_TIER_INDEX,
};

describe("git poll cadence", () => {
  test("an unattended, unchanging checkout walks the whole ladder", () => {
    const cadence = createGitPollCadence();
    // The period each poll actually RAN at, i.e. the tier in force before its
    // own result stepped the ladder.
    const tiersSeen: number[] = [];
    for (let i = 0; i < 200; i++) {
      if (!shouldRunPollTick(cadence)) continue;
      tiersSeen.push(GIT_POLL_TIERS[cadence.tierIndex]!);
      noteGitPollResult(cadence, unattendedIdle);
    }
    expect(tiersSeen.slice(0, GIT_POLL_TIERS.length)).toEqual([...GIT_POLL_TIERS]);
  });

  test("the ladder CAPS — it is a slow poll, never a zero poll", () => {
    const cadence = createGitPollCadence();
    runTicks(cadence, 500, unattendedIdle);
    expect(cadence.tierIndex).toBe(CHECKOUT_MAX_TIER_INDEX);

    // A headless bridge (an eval, a CLI, a desktop driven from its own
    // terminal) sends no `session:focus` at all, so the slowest tier is the
    // cadence its Git view lives on forever. It has to keep running.
    const slowest = GIT_POLL_TIERS[CHECKOUT_MAX_TIER_INDEX]!;
    expect(runTicks(cadence, slowest * 10, unattendedIdle)).toBe(10);
  });

  test("shouldRunPollTick runs exactly once per tier period", () => {
    for (let tier = 0; tier < GIT_POLL_TIERS.length; tier++) {
      const cadence = createGitPollCadence();
      // Walk to `tier` and stop noting results, so the period under test is
      // the one this tier prescribes.
      while (cadence.tierIndex < tier) {
        if (shouldRunPollTick(cadence)) noteGitPollResult(cadence, unattendedIdle);
      }
      const period = GIT_POLL_TIERS[tier]!;
      let ran = 0;
      for (let i = 0; i < period; i++) if (shouldRunPollTick(cadence)) ran++;
      expect(ran).toBe(1);
    }
  });

  test("an attended checkout never leaves the base period", () => {
    const cadence = createGitPollCadence();
    const attendedIdle = { changed: false, attended: true, maxTierIndex: CHECKOUT_MAX_TIER_INDEX };
    expect(runTicks(cadence, 50, attendedIdle)).toBe(50);
    expect(cadence.tierIndex).toBe(0);
  });

  test("a change snaps back to the base period from the slowest tier", () => {
    const cadence = createGitPollCadence();
    runTicks(cadence, 500, unattendedIdle);
    expect(cadence.tierIndex).toBe(CHECKOUT_MAX_TIER_INDEX);

    noteGitPollResult(cadence, { changed: true, attended: false, maxTierIndex: CHECKOUT_MAX_TIER_INDEX });
    expect(cadence.tierIndex).toBe(0);
    expect(shouldRunPollTick(cadence)).toBe(true);
  });

  test("resetGitPollCadence clears a partially-served skip, mid-tier", () => {
    const cadence = createGitPollCadence();
    runTicks(cadence, 500, unattendedIdle);
    // Part-way through the slowest tier's run of skipped ticks.
    noteGitPollResult(cadence, unattendedIdle);
    expect(shouldRunPollTick(cadence)).toBe(false);
    expect(cadence.skipsLeft).toBeGreaterThan(0);

    resetGitPollCadence(cadence);
    expect(shouldRunPollTick(cadence)).toBe(true);
    expect(cadence.tierIndex).toBe(0);
  });

  test("main stops one tier short of the checkout ceiling", () => {
    const cadence = createGitPollCadence();
    runTicks(cadence, 500, { changed: false, attended: false, maxTierIndex: MAIN_MAX_TIER_INDEX });
    expect(cadence.tierIndex).toBe(MAIN_MAX_TIER_INDEX);
    expect(GIT_POLL_TIERS[MAIN_MAX_TIER_INDEX]!)
      .toBeLessThan(GIT_POLL_TIERS[CHECKOUT_MAX_TIER_INDEX]!);
  });
});
