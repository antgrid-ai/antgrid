// bridge/src/pty-submit.ts

// Submitting a line into a coding-agent TUI. A leaf module with no imports:
// terminal-session.ts owns the PTY, and the rules below are about the guest's
// input tokenizer, not about any of the bridge's own plumbing.

/**
 * How long the submitting CR waits behind the line it submits.
 *
 * A TUI tokenizes a PTY read as a WHOLE: Claude Code emits a control character
 * as its own key event only while the entire read is under 64 characters. At or
 * above that the trailing CR is absorbed into the surrounding text run, arrives
 * as a nameless key event carrying the whole line, and is inserted into the
 * composer as literal text — the prompt is typed but never sent. A submitted
 * line therefore has to reach the guest in a read of its own.
 *
 * Claude Code's own programmatic reply path uses 10ms. This sits above it
 * because a ConPTY write crosses one more pipe hop than a POSIX pty does, and
 * the cost of being wrong in each direction is asymmetric: too short strands
 * the line in the composer, too long adds latency nobody can perceive.
 */
export const SUBMIT_CR_GAP_MS = 20;

/**
 * One trailing space on a bare slash verb, so it submits literally.
 *
 * With the CR in a read of its own, a fully-typed bare verb reaches Claude
 * Code's Enter handler while its suggestion list is still open and selection
 * has settled on the exact match, which routes Enter to accept-suggestion
 * rather than submit. That path can leave the composer set and send nothing
 * (a prompt command declaring `argNames`) or execute `suggestions[0]` instead
 * of the verb that was chosen. Any slash line containing a space clears the
 * list before Enter is read, so one trailing space restores a literal submit.
 * The space is inert for the agent, which trims its own command line.
 */
export function padBareVerb(line: string): string {
  return /^\/\S+$/.test(line) ? `${line} ` : line;
}

const defaultSleep = (ms: number): Promise<void> =>
  new Promise((resolve) => setTimeout(resolve, ms));

/**
 * Serializes one terminal's writes so a deferred CR keeps its read to itself.
 *
 * Once a CR is deferred, everything else written to that terminal — the next
 * user keystroke above all — has to queue behind it, or the key lands INSIDE
 * the injected line. That ordering is the whole reason this is a queue rather
 * than a `setTimeout` at the call site.
 */
export class PtySubmitQueue {
  private tail: Promise<void> | null = null;

  constructor(
    private readonly deps: {
      write: (data: string) => void;
      sleep?: (ms: number) => Promise<void>;
    },
  ) {}

  /** Raw pass-through. Stays synchronous while nothing is queued: the ordinary
   *  keystroke path must not grow a scheduling hop. */
  write(data: string): void {
    if (this.tail === null) {
      this.deps.write(data);
      return;
    }
    this.chain(() => this.deps.write(data));
  }

  /** Writes `line` and its submitting CR as two reads a gap apart — see
   *  {@link SUBMIT_CR_GAP_MS} for why the CR cannot share the line's read. */
  submit(line: string): void {
    this.chain(async () => {
      this.deps.write(line);
      await (this.deps.sleep ?? defaultSleep)(SUBMIT_CR_GAP_MS);
      this.deps.write("\r");
    });
  }

  private chain(step: () => void | Promise<void>): void {
    // The catch is load-bearing: a rejected tail would stall every later write
    // on this terminal for the life of the session, presenting as a terminal
    // that silently stops accepting input.
    const tail = (this.tail ?? Promise.resolve()).then(step).catch(() => {});
    this.tail = tail;
    // Identity check, not a bare null: only the LAST link may hand the queue
    // back to the synchronous fast path.
    void tail.then(() => {
      if (this.tail === tail) this.tail = null;
    });
  }
}
