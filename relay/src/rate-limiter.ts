export function pairKey(a: string, b: string): string {
  return a < b ? `${a}:${b}` : `${b}:${a}`;
}

interface WindowEntry {
  count: number;
  windowStart: number;
}

/** Cap on distinct live keys. No key family has explicit removal — a pair key
 *  outlives the disconnect that ended the pair, and per-device push keys are
 *  never cleaned — so both limiters bound their map defensively, evicting
 *  entries indistinguishable from a fresh one when it overflows. */
const MAX_KEYS = 10_000;

/**
 * Fixed 1-second window. Guards push delivery, where the budget is a flat
 * per-agent ceiling and burst tolerance would only widen a fan-out to
 * third-party providers. Traffic with a bursty shape (routed frames) uses
 * [TokenBucketRateLimiter] instead — a fixed window cannot absorb a burst
 * that is legitimate in aggregate.
 */
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

  destroy(): void {
    this.windows.clear();
  }
}

interface Bucket {
  tokens: number;
  lastRefill: number;
}

/**
 * Per-key token bucket: a sustained `refillPerSec` with a `burst` allowance, so
 * traffic that is bursty by nature never trips on its shape alone while a
 * sustained flood is still throttled. Guards both JSON control messages
 * (keyed per connection) and routed binary frames (keyed per device pair AND
 * channel, so a preview page load cannot starve terminal output or vice versa).
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
