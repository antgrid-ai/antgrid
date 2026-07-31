import type { ServerWebSocket } from "bun";
import { isSlotOf } from "antgrid-wire";
import { logger } from "./logger.js";

/**
 * Per-socket state stamped at HTTP upgrade and mutated once, when the socket
 * clears `hello`. `phase` gates the message dispatcher: only `ready` sockets may
 * send route frames or control verbs.
 */
export interface WsData {
  connectionId: string;
  ip: string;
  /**
   * Normalized `Host` header of the upgrade request (lowercased, scheme-default
   * port dropped). Rebuilt into the hello signature body server-side so a
   * cross-relay-replayed hello fails the signature (design §4.1 step 4).
   */
  relayHost: string;
  deviceId?: string;
  phase: "awaiting-hello" | "ready";
  /** License credential id (`azp`) — lets /internal/revoke find the socket. */
  jti?: string;
}

/** Verified identity carried by a live connection past hello. */
export interface ConnectionClaims {
  /** Account id (`claims.uid`) — the routing-authorization key (`mayRoute`). */
  uid: string;
  tier?: string;
  /** License credential id (`azp`) for revocation lookup. */
  jti?: string;
}

/** A live connection — an entry exists iff a socket is open and past hello. */
export interface Connection {
  connectionId: string;
  deviceId: string;
  deviceType: "agent" | "app";
  name: string;
  publicKey: string;
  epoch: number;
  /**
   * The `hello.nonce` that admitted this connection. Equal-epoch arbitration
   * compares it so a REPLAYED hello (byte-identical, hence same nonce) cannot
   * evict the live holder it originally admitted; a genuine redial mints a
   * fresh nonce. Defence in depth behind the replay cache, which is
   * capacity-bounded and does not survive a restart (design §6.3).
   */
  helloNonce: string;
  ws: ServerWebSocket<WsData>;
  ip: string;
  connectedAt: number;
  /** Transport diagnostics only — NEVER consulted for arbitration (design §6.3). */
  lastSeen: number;
  claims?: ConnectionClaims;
  /** Agents only: opaque stream ids, released wholesale when the entry drops. */
  openStreams: Set<string>;
}

/**
 * Identity-free row for the internal connections view (web enriches the rest).
 * Keep in lockstep with web's `src/relay/push.ts` ConnectionSummary.
 *
 * `openStreamCount` is liveness telemetry, not a billable quantity — an agent
 * registers under a bare `deviceUuid` and multiplexes every project as a sealed
 * stream. The COUNT is all that crosses: stream ids are opaque and the relay
 * cannot see the projectIds behind them.
 */
export interface ConnectionSummary {
  deviceId: string;
  deviceType: "agent" | "app";
  connectedAt: number;
  lastSeen: number;
  openStreamCount: number;
}

/**
 * The live-connection table. Replaces the v2 `DeviceRegistry`: no retained
 * disconnected tombstones, no symmetric pairing pointers, no state machine — an
 * entry exists exactly while its socket is open and past hello. Keyed twice: by
 * `connectionId` (the stable per-socket id, so a superseded socket's close
 * handler can tell it is no longer the live holder) and by `deviceId` (the one
 * live connection currently owning that identity).
 */
export class Connections {
  private readonly byConnectionId = new Map<string, Connection>();
  private readonly byDeviceId = new Map<string, Connection>();
  // Per-account index so same-account fan-out (presencePeers) is O(peers), not
  // an O(n) scan of every live connection on every hello/disconnect.
  private readonly byUid = new Map<string, Set<Connection>>();
  private readonly ipCounts = new Map<string, number>();

  insert(conn: Connection): void {
    this.byConnectionId.set(conn.connectionId, conn);
    this.byDeviceId.set(conn.deviceId, conn);
    const uid = conn.claims?.uid;
    if (uid !== undefined) {
      let set = this.byUid.get(uid);
      if (!set) {
        set = new Set<Connection>();
        this.byUid.set(uid, set);
      }
      set.add(conn);
    }
  }

  /**
   * Remove a connection from both indexes (used both on socket close and on
   * epoch supersession). Removing the entry drops its `openStreams` set, which
   * is how a superseded agent's streams are released before the successor is
   * inserted (design §6.3 / §7.3).
   */
  remove(conn: Connection): void {
    this.byConnectionId.delete(conn.connectionId);
    if (this.byDeviceId.get(conn.deviceId) === conn) {
      this.byDeviceId.delete(conn.deviceId);
    }
    const uid = conn.claims?.uid;
    if (uid !== undefined) {
      const set = this.byUid.get(uid);
      if (set) {
        set.delete(conn);
        if (set.size === 0) this.byUid.delete(uid);
      }
    }
  }

  getByConnectionId(connectionId: string): Connection | undefined {
    return this.byConnectionId.get(connectionId);
  }

  getByDeviceId(deviceId: string): Connection | undefined {
    return this.byDeviceId.get(deviceId);
  }

  /**
   * Every live connection belonging to ACCOUNT device [deviceId]: the exact
   * holder plus any per-machine app slot scoped under it (`<deviceId>#<machine>`).
   *
   * An agent registers under its bare `deviceUuid`, but an app registers one
   * slot per machine it holds open, so anything driven by an account device id
   * — revocation above all — must not stop at `getByDeviceId`. O(n) is fine:
   * the only caller is the internal revoke route.
   */
  getByAccountDevice(deviceId: string): Connection[] {
    const exact = this.byDeviceId.get(deviceId);
    const out: Connection[] = exact ? [exact] : [];
    for (const c of this.byDeviceId.values()) {
      if (c !== exact && isSlotOf(c.deviceId, deviceId)) out.push(c);
    }
    return out;
  }

  getConnectionsForUser(userId: string): Connection[] {
    const set = this.byUid.get(userId);
    return set ? [...set] : [];
  }

  /**
   * Count open streams across ALL live agent connections owned by [userId].
   *
   * No production caller: stream admission is uncapped and `/internal/connections`
   * builds each row from `c.openStreams.size` directly. It survives as the
   * assertion helper `tests/epochs.test.ts` uses to prove a superseded epoch
   * releases its streams. Do NOT delete it as dead, and do NOT re-introduce a
   * per-account stream cap against it — metering open streams taxes the fleet
   * view and warm-project LRU (see docs/plans/2026-07-30-worker-limit-pricing.md).
   */
  countOpenStreamsForUser(userId: string): number {
    let count = 0;
    for (const c of this.byDeviceId.values()) {
      if (c.deviceType !== "agent") continue;
      if (c.claims?.uid !== userId) continue;
      count += c.openStreams.size;
    }
    return count;
  }

  updateLastSeen(deviceId: string): void {
    const c = this.byDeviceId.get(deviceId);
    if (c) c.lastSeen = Date.now();
  }

  incrementIpCount(ip: string): number {
    const count = (this.ipCounts.get(ip) ?? 0) + 1;
    this.ipCounts.set(ip, count);
    return count;
  }

  decrementIpCount(ip: string): void {
    const count = this.ipCounts.get(ip) ?? 0;
    if (count <= 1) this.ipCounts.delete(ip);
    else this.ipCounts.set(ip, count - 1);
  }

  getConnectionCountByIp(ip: string): number {
    return this.ipCounts.get(ip) ?? 0;
  }

  getConnectionCount(): number {
    return this.byDeviceId.size;
  }

  private toSummary(c: Connection): ConnectionSummary {
    return {
      deviceId: c.deviceId,
      deviceType: c.deviceType,
      connectedAt: c.connectedAt,
      lastSeen: c.lastSeen,
      openStreamCount: c.openStreams.size,
    };
  }

  listConnections(): ConnectionSummary[] {
    return [...this.byDeviceId.values()].map((c) => this.toSummary(c));
  }

  listConnectionsForUser(userId: string): ConnectionSummary[] {
    const out: ConnectionSummary[] = [];
    for (const c of this.byDeviceId.values()) {
      if (c.claims?.uid === userId) out.push(this.toSummary(c));
    }
    return out;
  }

  clear(): void {
    this.byConnectionId.clear();
    this.byDeviceId.clear();
    this.byUid.clear();
    this.ipCounts.clear();
    logger.debug("connections cleared");
  }
}
