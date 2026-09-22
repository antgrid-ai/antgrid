export interface ConnectionLiveness {
  connectedAt: number;
  protocolPongAt?: number;
  applicationPingAt?: number;
}

export interface LivenessAges {
  connectionAgeMs: number;
  protocolPongAgeMs: number | null;
  applicationPingAgeMs: number | null;
}

/** Per-socket relay liveness. Device ids are deliberately absent: a late
 * callback from a superseded socket must be unable to refresh its successor. */
export class ConnectionLivenessTracker {
  private readonly state = new Map<string, ConnectionLiveness>();

  add(connectionId: string, now: number): void {
    this.state.set(connectionId, { connectedAt: now });
  }

  remove(connectionId: string): void {
    this.state.delete(connectionId);
  }

  noteProtocolPong(connectionId: string, now: number): void {
    const state = this.state.get(connectionId);
    if (state) state.protocolPongAt = now;
  }

  noteApplicationPing(connectionId: string, now: number): void {
    const state = this.state.get(connectionId);
    if (state) state.applicationPingAt = now;
  }

  isTimedOut(connectionId: string, now: number, windowMs: number): boolean {
    const state = this.state.get(connectionId);
    if (!state) return false;
    const duplexAt = Math.max(
      state.connectedAt,
      state.protocolPongAt ?? 0,
      state.applicationPingAt ?? 0,
    );
    return now - duplexAt > windowMs;
  }

  ages(connectionId: string, now: number): LivenessAges | undefined {
    const state = this.state.get(connectionId);
    if (!state) return undefined;
    return {
      connectionAgeMs: now - state.connectedAt,
      protocolPongAgeMs: state.protocolPongAt == null ? null : now - state.protocolPongAt,
      applicationPingAgeMs: state.applicationPingAt == null ? null : now - state.applicationPingAt,
    };
  }
}