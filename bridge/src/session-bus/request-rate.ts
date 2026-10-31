// A per-sender token bucket for requests another machine asks this one to
// answer. The sender is the machine the transport authenticated, so a bucket
// cannot be dodged by naming a different one, and a flood from one machine
// cannot spend what another is owed.
import { BUS_REQUESTS_PER_MIN_PER_MACHINE } from "./constants";

const MAX_BUCKETS = 256;

interface Bucket {
  tokens: number;
  at: number;
}

export class RequestRateLimiter {
  private readonly buckets = new Map<string, Bucket>();

  constructor(
    private readonly perMinute: number = BUS_REQUESTS_PER_MIN_PER_MACHINE,
    private readonly now: () => number = Date.now,
  ) {}

  /** Spends one token for `sender`; false when the bucket is empty. */
  take(sender: string): boolean {
    const t = this.now();
    const b = this.buckets.get(sender) ?? { tokens: this.perMinute, at: t };
    if (t > b.at) b.tokens = Math.min(this.perMinute, b.tokens + ((t - b.at) / 60_000) * this.perMinute);
    b.at = t;
    // Re-inserted so the map's order is least recently used first.
    this.buckets.delete(sender);
    this.buckets.set(sender, b);
    if (this.buckets.size > MAX_BUCKETS) {
      const oldest = this.buckets.keys().next().value;
      if (oldest !== undefined) this.buckets.delete(oldest);
    }
    if (b.tokens < 1) return false;
    b.tokens -= 1;
    return true;
  }
}
