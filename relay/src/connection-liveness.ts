export interface ConnectionLiveness {
  connectedAt: number;
  protocolPongAt?: number;
  applicationPingAt?: number;
  authenticatedInboundAt: number;
}

export interface LivenessAges {
  connectionAgeMs: number;
  protocolPongAgeMs: number | null;
  applicationPingAgeMs: number | null;
  authenticatedInboundAgeMs: number;
}

/** Outbound bytes still queued for a socket beyond which its inbound traffic
 * stops counting as liveness. An authenticated frame proves the peer is up
 * and sending; that it is also READING is proved by our sends draining. A
 * backlog this deep, sampled on a sweep that already found no pong for a whole
 * window, is a reader that stopped, whatever its uplink is still saying. */
export const INBOUND_LIVENESS_MAX_BACKLOG_BYTES = 1_048_576;

/** Per-socket relay liveness. Device ids are deliberately absent: a late
 * callback from a superseded socket must be unable to refresh its successor. */
export class ConnectionLivenessTracker {
  private readonly state = new Map<string, ConnectionLiveness>();

  add(connectionId: string, now: number): void {
    this.state.set(connectionId, {
      connectedAt: now,
      authenticatedInboundAt: now,
    });
  }

  remove(connectionId: string): void {
    this.state.delete(connectionId);
  }

  noteProtocolPong(connectionId: string, now: number): void {
    const state = this.state.get(connectionId);
    if (!state) return;
    state.protocolPongAt = now;
  }

  noteApplicationPing(connectionId: string, now: number): void {
    const state = this.state.get(connectionId);
    if (!state) return;
    state.applicationPingAt = now;
    state.authenticatedInboundAt = now;
  }

  noteAuthenticatedInbound(connectionId: string, now: number): void {
    const state = this.state.get(connectionId);
    if (state) state.authenticatedInboundAt = now;
  }

  /** `outboundBacklogBytes` is what we still hold unsent for the socket at
   * this moment (Bun's `getBufferedAmount()`). */
  isTimedOut(
    connectionId: string,
    now: number,
    windowMs: number,
    outboundBacklogBytes = 0,
  ): boolean {
    const state = this.state.get(connectionId);
    if (!state) return false;
    const duplexAt = Math.max(
      state.connectedAt,
      state.protocolPongAt ?? 0,
      state.applicationPingAt ?? 0,
    );
    if (now - duplexAt <= windowMs) return false;
    // A pong is answered in order behind whatever the peer already queued on
    // the same TCP stream, so a bridge pushing a multi-megabyte reply up a
    // slow link answers late while being as alive as a socket gets. Its
    // routed frames arriving is that proof; a bounded backlog on our side is
    // the proof it still reads.
    return (
      outboundBacklogBytes > INBOUND_LIVENESS_MAX_BACKLOG_BYTES ||
      now - state.authenticatedInboundAt > windowMs
    );
  }

  ages(connectionId: string, now: number): LivenessAges | undefined {
    const state = this.state.get(connectionId);
    if (!state) return undefined;
    return {
      connectionAgeMs: now - state.connectedAt,
      protocolPongAgeMs: state.protocolPongAt == null ? null : now - state.protocolPongAt,
      applicationPingAgeMs: state.applicationPingAt == null ? null : now - state.applicationPingAt,
      authenticatedInboundAgeMs: now - state.authenticatedInboundAt,
    };
  }
}
