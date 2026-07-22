import { logger } from "./logger.js";

interface ReplayCacheOptions {
  ttlMs: number;
  /** Hard ceiling on retained `(deviceId, nonce)` pairs before oldest-eviction. */
  maxEntries?: number;
}

const DEFAULT_MAX_ENTRIES = 50_000;

/**
 * Remembers recently-seen `(deviceId, nonce)` hello pairs so a captured hello
 * cannot be replayed within its clock-skew window. The signed `ts`+nonce make a
 * replay only possible inside the ±skew window anyway; a TTL a few multiples of
 * that window is sufficient and keeps the map bounded.
 *
 * Insertion order in a JS Map is stable, so the first key is the oldest — used
 * for O(1) overflow eviction. Expiry is lazy (checked per lookup) plus a coarse
 * sweep, so a low-traffic relay never accumulates dead rows.
 */
export class ReplayCache {
  private readonly seen = new Map<string, number>();
  private readonly ttlMs: number;
  private readonly maxEntries: number;
  private readonly sweepTimer: ReturnType<typeof setInterval>;

  constructor(opts: ReplayCacheOptions) {
    this.ttlMs = opts.ttlMs;
    this.maxEntries = opts.maxEntries ?? DEFAULT_MAX_ENTRIES;
    this.sweepTimer = setInterval(() => this.sweep(), Math.max(this.ttlMs, 1_000));
    this.sweepTimer.unref?.();
  }

  /**
   * Records the pair and returns `true` if it was unseen (accept the hello),
   * `false` if a live entry already exists (reject as replay). A record whose
   * TTL has elapsed is treated as unseen and refreshed.
   */
  checkAndRecord(deviceId: string, nonce: string): boolean {
    const key = `${deviceId} ${nonce}`;
    const now = Date.now();
    const prev = this.seen.get(key);
    if (prev !== undefined && now - prev < this.ttlMs) {
      return false;
    }
    // Re-insert so the key moves to the tail (freshest) for oldest-eviction.
    this.seen.delete(key);
    if (this.seen.size >= this.maxEntries) {
      const oldest = this.seen.keys().next();
      if (!oldest.done) this.seen.delete(oldest.value);
    }
    this.seen.set(key, now);
    return true;
  }

  private sweep(): void {
    const cutoff = Date.now() - this.ttlMs;
    let removed = 0;
    for (const [k, ts] of this.seen) {
      if (ts < cutoff) {
        this.seen.delete(k);
        removed++;
      } else {
        // Insertion order is age order, so the first live entry ends the sweep.
        break;
      }
    }
    if (removed > 0) logger.debug("replay cache swept", { removed, remaining: this.seen.size });
  }

  destroy(): void {
    clearInterval(this.sweepTimer);
    this.seen.clear();
  }
}
