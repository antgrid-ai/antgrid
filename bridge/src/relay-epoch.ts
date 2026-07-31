import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { logger } from "./logger";
const log = logger.child({ component: "relay-epoch" });

/**
 * Connection-instance epoch for v3 hello arbitration (design §6.3/§13.2).
 *
 * Computed once per process as `max(stored + 1, unixSeconds)` and persisted
 * back before returning: the wall-clock floor makes a storage wipe / reinstall
 * a non-event (a fresh install still out-epochs any zombie connection whose
 * counter came from a sane past), while the `stored + 1` term guarantees strict
 * monotonicity across quick restarts within the same second. The relay only
 * ever compares a device against its own previous live value, so a single
 * machine-wide counter is sufficient.
 */
export function nextEpoch(abDir: string): number {
  const path = join(abDir, "relay-epoch");
  let stored = 0;
  try {
    if (existsSync(path)) {
      const parsed = Number.parseInt(readFileSync(path, "utf8").trim(), 10);
      if (Number.isFinite(parsed) && parsed >= 0) stored = parsed;
    }
  } catch (err) {
    // A corrupt/unreadable counter falls back to the wall-clock floor below —
    // never fail closed, an epoch is only a monotonic tiebreaker.
    log.warn("relay-epoch: failed to read %s: %s", path, err instanceof Error ? err.message : String(err));
  }
  const epoch = Math.max(stored + 1, Math.floor(Date.now() / 1000));
  try {
    mkdirSync(dirname(path), { recursive: true });
    writeFileSync(path, String(epoch));
  } catch (err) {
    // Persist failure only risks a non-monotonic epoch after a same-second
    // restart. The relay treats an equal epoch under the same key as a redial
    // and lets the newest socket win, so the restarted process still admits;
    // only a lower epoch is rejected — not a correctness hazard.
    log.warn("relay-epoch: failed to persist %s: %s", path, err instanceof Error ? err.message : String(err));
  }
  return epoch;
}
