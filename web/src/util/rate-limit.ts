type Bucket = { tokens: number; lastRefill: number };

export type RateLimiter = (key: string) => boolean;

const MAX_BUCKETS = 10_000;

/**
 * Token-bucket limiter. Allows `capacity` requests, refilled at `refillPerSec`.
 * Safe for single-process use. Swap for Redis in multi-node.
 *
 * Existing buckets that refill back to capacity are evicted after the
 * decrement — their state is then indistinguishable from a freshly-created
 * bucket, so dropping them bounds memory without changing behaviour.
 * MAX_BUCKETS is a hard ceiling against adversarial key rotation.
 */
export function tokenBucket(capacity: number, refillPerSec: number): RateLimiter {
  const buckets = new Map<string, Bucket>();
  return (key) => {
    const now = Date.now();
    const existing = buckets.get(key);
    if (!existing) {
      if (buckets.size >= MAX_BUCKETS) {
        const first = buckets.keys().next().value;
        if (first !== undefined) buckets.delete(first);
      }
      buckets.set(key, { tokens: capacity - 1, lastRefill: now });
      return true;
    }
    const elapsed = (now - existing.lastRefill) / 1000;
    existing.tokens = Math.min(capacity, existing.tokens + elapsed * refillPerSec);
    existing.lastRefill = now;
    if (existing.tokens < 1) return false;
    const refilledToFull = existing.tokens >= capacity;
    existing.tokens -= 1;
    if (refilledToFull) buckets.delete(key);
    return true;
  };
}
