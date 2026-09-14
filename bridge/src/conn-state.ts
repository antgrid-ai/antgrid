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
  /** The file-tree revision the watcher rooted at [watchRoot] is at. Counted
   *  per root rather than once for the core: every checkout runs its own
   *  watcher over its own worktree, so a single counter let one worktree's
   *  churn advance the number every sibling's tree is stamped with — and the
   *  "is my tree still current?" comparison a resuming client makes against it
   *  would then almost never match on a project with worktrees. Keyed by the
   *  watched root, not a checkoutId, so the only caller that can name a scope
   *  is the watcher that owns it. */
  fileSeq(watchRoot: string): number;
  bumpTerminalSeq(terminalId: string): number;
  terminalSeq(terminalId: string): number;
  clearTerminal(terminalId: string): void;
  bumpFileSeq(watchRoot: string): number;
}

export function createConnState(): ConnState {
  const seqs = new Map<string, number>();
  const fileSeqs = new Map<string, number>();
  const state = {
    appFocusPaused: false,
    peerOnline: true,
    get suppressed(): boolean {
      return !state.peerOnline || state.appFocusPaused;
    },
    fileSeq(watchRoot: string): number {
      return fileSeqs.get(watchRoot) ?? 0;
    },
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
    bumpFileSeq(watchRoot: string): number {
      const next = (fileSeqs.get(watchRoot) ?? 0) + 1;
      fileSeqs.set(watchRoot, next);
      return next;
    },
  };
  return state;
}
