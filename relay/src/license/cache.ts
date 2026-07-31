export interface LicenseCacheEntry {
  jti: string;
  deviceId: string;
  userId: string;
  tier: "free" | "trial" | "pro";
  pk: string;
  revoked?: boolean;
}

interface LicenseCacheOptions {
  maxEntries: number;
}

/**
 * In-memory cache of successfully verified device JWTs, keyed by deviceId
 * (`sub`). The JWT's own `exp` claim drives expiry — every cache hit still
 * runs verifyDeviceToken at the gate, which fails on expired tokens. Revoked
 * entries are kept (`revoked = true`) so a re-presented revoked token is
 * blocked without re-verifying.
 */
export class LicenseCache {
  private readonly entries = new Map<string, LicenseCacheEntry>();
  private readonly maxEntries: number;

  constructor(opts: LicenseCacheOptions) {
    this.maxEntries = opts.maxEntries;
  }

  set(entry: LicenseCacheEntry): void {
    if (!this.entries.has(entry.deviceId) && this.entries.size >= this.maxEntries) {
      const oldest = this.entries.keys().next();
      if (!oldest.done) this.entries.delete(oldest.value);
    }
    this.entries.set(entry.deviceId, { ...entry, revoked: entry.revoked ?? false });
  }

  get(deviceId: string): LicenseCacheEntry | undefined {
    return this.entries.get(deviceId);
  }

  markRevoked(deviceId: string): void {
    const entry = this.entries.get(deviceId);
    if (entry) entry.revoked = true;
  }

  dropByUser(userId: string): string[] {
    const ids: string[] = [];
    for (const entry of this.entries.values()) {
      if (entry.userId === userId) {
        entry.revoked = true;
        ids.push(entry.deviceId);
      }
    }
    return ids;
  }

  destroy(): void {
    this.entries.clear();
  }
}
