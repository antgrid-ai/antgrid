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
  // No slash or backslash after the leading one: a POSIX absolute path
  // (`/etc/hosts`) and a Windows-style one are not slash verbs, and padding
  // them would append a space to a line the user typed as a bare argument.
  return /^\/[^\s/\\]+$/.test(line) ? `${line} ` : line;
}

/**
 * DECSET 2004's paste delimiters.
 *
 * A guest with the mode on takes everything between them as literal text,
 * newlines included, and only the CR that follows submits. A guest WITHOUT it
 * sees two escape sequences and reads every newline as Enter — which is why
 * choosing this path is the caller's job and requires having watched the guest
 * turn the mode on (`TerminalModeTracker`), never an assumption about it.
 */
export const PASTE_START = "\x1b[200~";
export const PASTE_END = "\x1b[201~";

/** Everything a paste body must not carry: every C0 control and DEL except the
 *  newlines and tabs that are the block's shape. ESC above all — an embedded
 *  {@link PASTE_END} would close the paste and put the remainder back on the
 *  keystroke path, one line per newline. */
const PASTE_UNSAFE = /[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]/g;

/**
 * Collapse a block onto the one line a keystroke channel can carry.
 *
 * The fallback for a guest that never announced bracketed paste. Losing the
 * block's line breaks costs readability; keeping them costs a submit per line,
 * so an agent handed a 20-line prompt would answer the first line and act on the
 * rest as 19 separate turns.
 */
export function flattenForSubmit(text: string): string {
  return text.replace(PASTE_UNSAFE, "").replace(/\s+/g, " ").trim();
}

/**
 * How one submit has to reach the guest.
 *
 * A PTY is a keystroke channel: a newline in the text is Enter, so a block
 * handed over whole submits its first line and leaves the rest arriving as
 * separate turns. Bracketed paste is the only framing that carries the newlines
 * as text, and it needs the guest to have ANNOUNCED the mode — hence the
 * caller-supplied answer rather than a guess. Pure, so the routing is pinnable
 * without a live terminal.
 */
export function submitPlan(line: string, bracketedPaste: boolean): { paste: boolean; text: string } {
  if (!/[\r\n]/.test(line)) return { paste: false, text: line };
  return bracketedPaste ? { paste: true, text: line } : { paste: false, text: flattenForSubmit(line) };
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
      const sleep = this.deps.sleep ?? defaultSleep;
      this.deps.write(line);
      await sleep(SUBMIT_CR_GAP_MS);
      this.deps.write("\r");
      // The gap AFTER the CR matters as much as the one before it: the guest
      // tokenizes a read as a whole in both directions, so whatever is written
      // next — the user's own keystroke, a capability reply, a second submit —
      // would otherwise share this read and rob the CR of its own key event.
      await sleep(SUBMIT_CR_GAP_MS);
    });
  }

  /**
   * Submit a multi-line block as ONE prompt, framed as a bracketed paste.
   *
   * Only for a terminal whose guest has DECSET 2004 latched — see
   * {@link PASTE_START}. The body and its delimiters go in a single write so the
   * guest cannot see an unterminated paste, and the CR keeps its own read for
   * the same reason {@link submit}'s does.
   */
  submitPaste(text: string): void {
    // Stripped here rather than trusted from the caller: this is the only place
    // that knows the text is about to become a paste, and inside the brackets a
    // control character is literal text to a guest that honours the mode and a
    // live keystroke to one that half-does. Neither is content.
    const body = text.replace(/\r\n?/g, "\n").replace(PASTE_UNSAFE, "");
    this.chain(async () => {
      const sleep = this.deps.sleep ?? defaultSleep;
      this.deps.write(`${PASTE_START}${body}${PASTE_END}`);
      await sleep(SUBMIT_CR_GAP_MS);
      this.deps.write("\r");
      await sleep(SUBMIT_CR_GAP_MS);
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
