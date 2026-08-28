/** How a claimed attempt ended — see {@link TitleAttempts.settle}. */
export type TitleOutcome =
  /** A title was generated and applied. Nothing tries again. */
  | "named"
  /** The spawn ran and produced no usable title (signed-out CLI, timeout,
   *  rambling answer). Counts against the budget; a later turn may retry. */
  | "failed"
  /** Nothing installed can serve the call at all. Not this attempt's failure,
   *  so it does not count against the budget — it ends it. */
  | "unavailable"
  /** The generated title was thrown away for a reason unrelated to generating
   *  it: the user renamed the session mid-spawn, or the conversation moved on.
   *  Releases the claim and records nothing. */
  | "abandoned";

interface AttemptState {
  /** A spawn is running for this conversation right now. Mutual exclusion only;
   *  always cleared, however the spawn ends. */
  inFlight: boolean;
  /** Spawns that ran and produced no usable title. Bounded, because the cause
   *  is usually not transient at all and each attempt costs a ~45s budget. */
  failures: number;
  /** Named, or given up on. Terminal either way — only `forget` reopens it. */
  done: boolean;
}

/**
 * Whether a session may spend another title-generation spawn.
 *
 * Three fields rather than the single "already attempted" flag this replaces,
 * because that flag answered three questions with one bit and got two of them
 * wrong: a spawn that FAILED — a signed-out CLI, a timeout — marked the
 * conversation spent, so the session could never be named afterwards even once
 * the cause was fixed. Collapsing them back into a bare retry count
 * reintroduces the other half: a count cannot also exclude a second spawn while
 * the first is still running, and two turns ending at once both start one.
 *
 * Keyed by conversation within terminal, never by a flat `<terminal>:<conv>`
 * string: terminal ids contain colons of their own (`<checkoutId>:setup`), so
 * in a flat key space one terminal's release reaches another's entries by
 * prefix.
 */
export class TitleAttempts {
  private readonly byTerminal = new Map<string, Map<string, AttemptState>>();

  constructor(private readonly maxFailures = 2) {}

  /**
   * Whether a further spawn would be refused. Reads only, so it is safe as the
   * early-out on a hot path — every turn of every session posts a title, and
   * without it each one pays a transcript read only to be refused after it.
   */
  refused(terminalId: string, conversationId: string): boolean {
    const state = this.byTerminal.get(terminalId)?.get(conversationId);
    if (!state) return false;
    return state.done || state.inFlight || state.failures >= this.maxFailures;
  }

  /**
   * Claim the conversation for one spawn; false when it is refused.
   *
   * Check and set together and without an await between them, which is what
   * makes it exclusion rather than a hint: two turns can end while a first
   * spawn is still running, and a caller that re-read {@link refused} and then
   * claimed would let both through.
   *
   * Every true MUST be paired with a {@link settle} in a `finally` — a claim
   * that outlives its spawn is the permanent refusal this class exists to
   * remove.
   */
  begin(terminalId: string, conversationId: string): boolean {
    if (this.refused(terminalId, conversationId)) return false;
    let perTerminal = this.byTerminal.get(terminalId);
    if (!perTerminal) this.byTerminal.set(terminalId, (perTerminal = new Map()));
    const state = perTerminal.get(conversationId)
      ?? { inFlight: false, failures: 0, done: false };
    state.inFlight = true;
    perTerminal.set(conversationId, state);
    return true;
  }

  /** Release a claim and record how it ended. */
  settle(terminalId: string, conversationId: string, outcome: TitleOutcome): void {
    const state = this.byTerminal.get(terminalId)?.get(conversationId);
    if (!state) return;
    state.inFlight = false;
    if (outcome === "named" || outcome === "unavailable") state.done = true;
    else if (outcome === "failed") state.failures += 1;
  }

  /**
   * Released with the namer's buffered title, never separately. The two halves
   * answer the same question — has this slot been named — and a `forget` that
   * dropped only the rank left a session whose generated name the next
   * first-message read overwrote, with generation refused forever after. A
   * resume reuses the agent session id, so the key alone cannot tell the runs
   * apart.
   */
  forget(terminalId: string): void {
    this.byTerminal.delete(terminalId);
  }
}
