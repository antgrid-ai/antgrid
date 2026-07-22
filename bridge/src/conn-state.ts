/**
 * Per-process stream-gating state, shared by every transport on a core.
 *
 * Two independent inputs gate the heavy stream via the derived `suppressed`:
 *   - `appFocusPaused` — set by `client:focus-state` when the app backgrounds.
 *   - `peerOnline` — the relay peer's socket presence; defaults true.
 *
 * Kept separate so a peer-offline window suppresses without clobbering focus;
 * peer-online then resumes the focus the phone declared. Emitters still bump
 * seq when suppressed so the next snapshot carries an accurate cutoff.
 */
export interface ConnState {
  /** The phone's last-declared focus state (set only by `client:focus-state`). */
  appFocusPaused: boolean;
  /** Whether the paired peer's relay socket is currently online. Defaults true. */
  peerOnline: boolean;
  /** Derived send gate: suppressed when the peer is gone OR the app backgrounded. */
  readonly suppressed: boolean;
  fileSeq: number;
  bumpTerminalSeq(terminalId: string): number;
  terminalSeq(terminalId: string): number;
  clearTerminal(terminalId: string): void;
  bumpFileSeq(): number;
}

export function createConnState(): ConnState {
  const seqs = new Map<string, number>();
  const state = {
    appFocusPaused: false,
    peerOnline: true,
    get suppressed(): boolean {
      return !state.peerOnline || state.appFocusPaused;
    },
    fileSeq: 0,
    bumpTerminalSeq(id: string): number {
      const next = (seqs.get(id) ?? 0) + 1;
      seqs.set(id, next);
      return next;
    },
    terminalSeq(id: string): number {
      return seqs.get(id) ?? 0;
    },
    clearTerminal(id: string): void {
      seqs.delete(id);
    },
    bumpFileSeq(): number {
      state.fileSeq += 1;
      return state.fileSeq;
    },
  };
  return state;
}
