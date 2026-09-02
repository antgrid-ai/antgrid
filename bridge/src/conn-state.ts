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

export function createConnState(opts: { fileSeqBase?: number } = {}): ConnState {
  const seqs = new Map<string, number>();
  const state = {
    appFocusPaused: false,
    peerOnline: true,
    get suppressed(): boolean {
      return !state.peerOnline || state.appFocusPaused;
    },
    // Seeded per process, not from 0: the app hands its last snapshot seq back
    // (`file:tree:snapshot:request.sinceSeq`) to ask whether its tree is still
    // current, and a counter restarting at 0 on every bridge life would
    // re-reach a value the app remembers from the previous one — answering
    // "unchanged" for a tree that is not, with nothing left to correct it.
    fileSeq: opts.fileSeqBase ?? Math.floor(Math.random() * 2 ** 40),
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
