import { logger } from "./logger.js";

/**
 * A routing authorization between an agent (machine) and a phone. Pairing is no
 * longer a connection *state* — it is this durable *fact*: a frame from A to B
 * is forwarded iff a grant links their identities and B is connected. See
 * design §5.1.
 */
export interface Grant {
  agentDeviceId: string;
  /** Bookkeeping/display only — NOT the routing/auth key. */
  phoneDeviceId: string;
  /** The phone's authenticated CONNECTION key (its hello pubkey) — the auth
   *  anchor for app→agent routing. Deliberately NOT the pairing key the agent
   *  signs over in pair-approval: that one is a separate per-machine key the
   *  relay cannot verify and never sees on a routed frame. */
  phonePubkey: string;
  /** From the phone's own verified hello claims (design §5.1). */
  userId: string;
  /** Stamped from the agent connection at creation (license bookkeeping). */
  tier?: string;
  createdAt: number;
  lastUsedAt: number;
}

export type GrantRevokeReason = "PEER_REPLACED" | "REVOKED" | "STALE";

/** At most one coarse `lastUsedAt` write per grant per hour (design §13.3). */
const LAST_USED_REFRESH_MS = 60 * 60 * 1000;

function grantKey(agentDeviceId: string, phonePubkey: string): string {
  return `${agentDeviceId} ${phonePubkey}`;
}

export class Grants {
  private readonly grants = new Map<string, Grant>();

  /**
   * Create (or idempotently refresh) a grant, enforcing the one-active-phone
   * policy: any OTHER grant of the same agent is revoked. Returns the displaced
   * grants so the caller can notify their phones (`grant-revoked` PEER_REPLACED).
   */
  create(input: {
    agentDeviceId: string;
    phoneDeviceId: string;
    phonePubkey: string;
    userId: string;
    tier?: string;
  }): Grant[] {
    const key = grantKey(input.agentDeviceId, input.phonePubkey);
    const displaced: Grant[] = [];
    for (const [k, g] of this.grants) {
      if (g.agentDeviceId === input.agentDeviceId && k !== key) {
        this.grants.delete(k);
        displaced.push(g);
      }
    }
    const now = Date.now();
    const existing = this.grants.get(key);
    this.grants.set(key, {
      agentDeviceId: input.agentDeviceId,
      phoneDeviceId: input.phoneDeviceId,
      phonePubkey: input.phonePubkey,
      userId: input.userId,
      tier: input.tier,
      createdAt: existing?.createdAt ?? now,
      lastUsedAt: now,
    });
    logger.info("grant created", {
      agentDeviceId: input.agentDeviceId,
      phoneDeviceId: input.phoneDeviceId,
      displaced: displaced.length,
    });
    return displaced;
  }

  revoke(agentDeviceId: string, phonePubkey: string, reason: GrantRevokeReason): Grant | undefined {
    const key = grantKey(agentDeviceId, phonePubkey);
    const g = this.grants.get(key);
    if (!g) return undefined;
    this.grants.delete(key);
    logger.info("grant revoked", { agentDeviceId, phoneDeviceId: g.phoneDeviceId, reason });
    return g;
  }

  /**
   * Revoke a grant identified by the two device ids in either order (the
   * `grant-revoke` verb arrives from either side and names only the peer).
   */
  revokeByPeers(deviceIdA: string, deviceIdB: string, reason: GrantRevokeReason): Grant | undefined {
    for (const g of this.grants.values()) {
      const match =
        (g.agentDeviceId === deviceIdA && g.phoneDeviceId === deviceIdB) ||
        (g.agentDeviceId === deviceIdB && g.phoneDeviceId === deviceIdA);
      if (match) return this.revoke(g.agentDeviceId, g.phonePubkey, reason);
    }
    return undefined;
  }

  /** app→agent authorization: the phone's live connection key must match. */
  linked(agentDeviceId: string, phonePubkey: string): boolean {
    return this.grants.has(grantKey(agentDeviceId, phonePubkey));
  }

  /**
   * agent→app authorization by device ids — used when the phone may be offline
   * (no pubkey to anchor). Grant *existence* alone authorizes the send; the
   * caller still binds the delivered peer's live key with {@link linked}.
   */
  linkedByDevices(agentDeviceId: string, phoneDeviceId: string): boolean {
    for (const g of this.grants.values()) {
      if (g.agentDeviceId === agentDeviceId && g.phoneDeviceId === phoneDeviceId) return true;
    }
    return false;
  }

  /** All grants touching [deviceId] on either side (peer-online/offline fan-out). */
  peersOf(deviceId: string): Grant[] {
    const out: Grant[] = [];
    for (const g of this.grants.values()) {
      if (g.agentDeviceId === deviceId || g.phoneDeviceId === deviceId) out.push(g);
    }
    return out;
  }

  /** Coarse idle-touch on routed traffic; skips the write unless an hour elapsed. */
  refreshLastUsed(agentDeviceId: string, phonePubkey: string): void {
    const g = this.grants.get(grantKey(agentDeviceId, phonePubkey));
    if (g && Date.now() - g.lastUsedAt >= LAST_USED_REFRESH_MS) g.lastUsedAt = Date.now();
  }

  /** Remove grants idle longer than [days]; returns the removed grants. */
  sweepStale(days: number): Grant[] {
    const cutoff = Date.now() - days * 24 * 60 * 60 * 1000;
    const removed: Grant[] = [];
    for (const [k, g] of this.grants) {
      if (g.lastUsedAt < cutoff) {
        this.grants.delete(k);
        removed.push(g);
      }
    }
    if (removed.length > 0) logger.info("stale grants swept", { count: removed.length });
    return removed;
  }

  get size(): number {
    return this.grants.size;
  }

  clear(): void {
    this.grants.clear();
  }
}
