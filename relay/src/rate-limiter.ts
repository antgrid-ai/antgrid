export function pairKey(a: string, b: string): string {
  return a < b ? `${a}:${b}` : `${b}:${a}`;
}

interface WindowEntry {
  count: number;
  windowStart: number;
}

/** Cap on distinct live keys. removePair() cleans pair keys on unpair, but other
 *  key families (e.g. per-device push) have no explicit removal, so bound the map
 *  defensively: when it overflows, drop windows already past their 1s span. */
const MAX_KEYS = 10_000;

export class MessageRateLimiter {
  private windows = new Map<string, WindowEntry>();
  private maxPerSec: number;
  private lastEvictAt = 0;

  constructor(maxPerSec: number) {
    this.maxPerSec = maxPerSec;
  }

  allow(key: string): boolean {
    const now = Date.now();
    const entry = this.windows.get(key);

    if (!entry || now - entry.windowStart >= 1000) {
      // At capacity every new key would trigger evictStale; if the map is full
      // of still-live windows the scan evicts nothing yet costs O(MAX_KEYS) per
      // request — a flood of distinct keys would pin the event loop. Cap the
      // scan to once/sec (a stale window is ≥1s old, so nothing evictable is
      // missed by waiting up to 1s).
      if (!entry && this.windows.size >= MAX_KEYS && now - this.lastEvictAt >= 1000) {
        this.evictStale(now);
        this.lastEvictAt = now;
      }
      this.windows.set(key, { count: 1, windowStart: now });
      return true;
    }

    entry.count++;
    return entry.count <= this.maxPerSec;
  }

  /** Drop entries whose 1s window has elapsed (they'd reset on next allow anyway).
   *  Keeps the map bounded without evicting keys still inside a live window. */
  private evictStale(now: number): void {
    for (const [k, e] of this.windows) {
      if (now - e.windowStart >= 1000) this.windows.delete(k);
    }
  }

  removePair(key: string): void {
    this.windows.delete(key);
  }

  destroy(): void {
    this.windows.clear();
  }
}

interface Bucket {
  tokens: number;
  lastRefill: number;
}

/**
 * Per-key token bucket for JSON control messages: a sustained
 * `refillPerSec` with a `burst` allowance so a legitimate pairing burst of a
 * few messages never trips, while a flood is throttled. The v2 fixed-window
 * `MessageRateLimiter` still guards binary route frames; this covers the JSON
 * channel it never did.
 */
export class TokenBucketRateLimiter {
  private readonly buckets = new Map<string, Bucket>();
  private readonly refillPerSec: number;
  private readonly burst: number;
  private lastEvictAt = 0;

  constructor(refillPerSec: number, burst: number) {
    this.refillPerSec = refillPerSec;
    this.burst = burst;
  }

  /** Consume one token; returns false (drop the message) when the bucket is dry. */
  allow(key: string): boolean {
    const now = Date.now();
    let bucket = this.buckets.get(key);
    if (!bucket) {
      if (this.buckets.size >= MAX_KEYS && now - this.lastEvictAt >= 1000) {
        this.evictFull(now);
        this.lastEvictAt = now;
      }
      bucket = { tokens: this.burst, lastRefill: now };
      this.buckets.set(key, bucket);
    } else {
      const refill = ((now - bucket.lastRefill) / 1000) * this.refillPerSec;
      if (refill > 0) {
        bucket.tokens = Math.min(this.burst, bucket.tokens + refill);
        bucket.lastRefill = now;
      }
    }
    if (bucket.tokens < 1) return false;
    bucket.tokens -= 1;
    return true;
  }

  remove(key: string): void {
    this.buckets.delete(key);
  }

  /** Drop fully-refilled (idle) buckets — indistinguishable from a fresh one. */
  private evictFull(now: number): void {
    for (const [k, b] of this.buckets) {
      const refill = ((now - b.lastRefill) / 1000) * this.refillPerSec;
      if (b.tokens + refill >= this.burst) this.buckets.delete(k);
    }
  }

  destroy(): void {
    this.buckets.clear();
  }
}
