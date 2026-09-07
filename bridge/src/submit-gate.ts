// bridge/src/submit-gate.ts

// Holding a submit until the guest is reading. A leaf module: the rules below
// are about a PTY's buffering and a TUI's startup, not about the bridge's own
// plumbing, and `terminal-manager.ts` owns everything they are applied to.

/**
 * How long a submit waits for the guest to announce itself before going anyway.
 *
 * Generous on purpose: an agent CLI cold-starting a runtime on Windows takes
 * seconds, and the cost of the two outcomes is asymmetric. Waiting too long
 * delays a line nobody is reading yet; giving up too early is the bug this
 * module exists to fix. The bound exists only so a guest that never announces
 * an input mode submits the way it always did rather than never submitting.
 */
export const SUBMIT_READY_TIMEOUT_MS = 15_000;

/**
 * Holds an agent's submits until its TUI is reading.
 *
 * A PTY write lands in a buffer whether or not the guest is reading, and a guest
 * that is not reading gets the whole buffer in ONE read once it starts — the
 * line and its submitting CR together, which is the case `SUBMIT_CR_GAP_MS`
 * cannot cover: that gap is on the WRITER's side and produces no boundary in a
 * read the guest has not taken yet. The line is typed into the composer and
 * never sent, and two cards written seconds apart arrive welded onto one line.
 *
 * The window that matters is the agent's own startup — a session is started and
 * a queued session-bus card, a launch prompt, or a Handler reply drains into it
 * a moment later, long before the TUI has attached its reader. `initialPromptArgv`
 * exists because argv never races this; everything arriving afterwards has to
 * wait for the guest instead.
 *
 * Readiness is the guest ANNOUNCING an input mode: a TUI sets those as it takes
 * over the terminal, which is the same act as attaching its reader. That is
 * evidence rather than proof, hence the bound.
 */
export class SubmitGate {
  private readonly ready = new Set<string>();
  private readonly waiters = new Map<string, (() => void)[]>();
  private readonly chains = new Map<string, Promise<void>>();
  /** How many guests this id has had. Captured when a submit is ASKED FOR and
   *  compared when it is about to wait, which is a microtask later: without it a
   *  reset landing in that window releases nothing, because the waiter it would
   *  release does not exist yet, and the submit then waits out the full bound on
   *  a guest that is already gone. Never deleted -- an id whose count went back
   *  to zero would match a submit captured under the first guest. */
  private readonly guests = new Map<string, number>();

  constructor(private readonly timeoutMs: number = SUBMIT_READY_TIMEOUT_MS) {}

  /** The guest announced an input mode. Idempotent — the caller sees every
   *  output chunk and cannot cheaply know which one first carried the mode. */
  markReady(terminalId: string): void {
    if (this.ready.has(terminalId)) return;
    this.ready.add(terminalId);
    this.release(terminalId);
  }

  /**
   * A fresh guest is about to occupy this id, or the old one is gone.
   *
   * Held submits are RELEASED rather than dropped: whether they still go
   * anywhere is the caller's decision (it holds the session identity), and a
   * waiter left holding the chain would strand every later submit to a same-id
   * respawn behind a promise nothing can ever resolve.
   */
  reset(terminalId: string): void {
    this.ready.delete(terminalId);
    this.guests.set(terminalId, this.guest(terminalId) + 1);
    this.release(terminalId);
  }

  /** Run `send` once the guest is reading, keeping this terminal's submits in
   *  the order they were asked for. */
  run(terminalId: string, send: () => void): void {
    // Synchronous once the guest has announced itself and nothing is held: the
    // steady-state path — a Handler reply, the `continue` nudge, a bus card into
    // a live agent — must not grow a scheduling hop, and a submit that jumped
    // ahead of one still waiting would reorder the two.
    if (this.ready.has(terminalId) && !this.chains.has(terminalId)) {
      send();
      return;
    }
    const guest = this.guest(terminalId);
    const prior = this.chains.get(terminalId) ?? Promise.resolve();
    // The catch matches `PtySubmitQueue.chain`'s and is load-bearing for the
    // same reason: a rejected tail would stall every later submit on this
    // terminal for the life of the session.
    const next = prior.then(() => this.whenReady(terminalId, guest)).then(send).catch(() => {});
    this.chains.set(terminalId, next);
    void next.then(() => {
      if (this.chains.get(terminalId) === next) this.chains.delete(terminalId);
    });
  }

  private guest(terminalId: string): number {
    return this.guests.get(terminalId) ?? 0;
  }

  private whenReady(terminalId: string, guest: number): Promise<void> {
    if (this.ready.has(terminalId) || this.guest(terminalId) !== guest) return Promise.resolve();
    return new Promise<void>((resolve) => {
      let done = false;
      const finish = (): void => {
        if (done) return;
        done = true;
        clearTimeout(timer);
        resolve();
      };
      const timer = setTimeout(finish, this.timeoutMs);
      // A bounded wait must not be a reason to stay alive: a bridge whose last
      // outstanding work is a submit into a guest that never announces should
      // still exit when everything else is done.
      timer.unref?.();
      const list = this.waiters.get(terminalId);
      if (list) list.push(finish);
      else this.waiters.set(terminalId, [finish]);
    });
  }

  private release(terminalId: string): void {
    const list = this.waiters.get(terminalId);
    if (!list) return;
    this.waiters.delete(terminalId);
    for (const resolve of list) resolve();
  }
}
