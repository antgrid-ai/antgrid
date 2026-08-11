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

  /**
   * [userId] scopes the flip to one account. Entries are keyed by deviceId
   * alone, but a deviceId is only unique WITHIN an account (`[userId,
   * deviceId]` on the device row), so two accounts on the same physical device
   * share this slot — and whoever verified last owns it. Flipping it
   * unconditionally makes one account's revoke reject the other's next hello.
   * Omit it only for a caller that genuinely means "this deviceId, whoever
   * holds it".
   */
  markRevoked(deviceId: string, userId?: string): void {
    const entry = this.entries.get(deviceId);
    if (!entry) return;
    if (userId !== undefined && entry.userId !== userId) return;
    entry.revoked = true;
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
