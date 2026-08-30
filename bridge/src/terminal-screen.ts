/**
 * A headless VT per PTY, so a (re)attaching app can be handed a SCREEN rather
 * than a slice of the byte stream that produced one.
 *
 * `ScrollbackBuffer` keeps a tail of the raw output, which is what the handler's
 * LLM context and the local API want. It is the wrong thing to replay into an
 * emulator: a TUI paints its chrome once and thereafter rewrites only the rows
 * that changed, so a suffix of that diff stream can address a handful of rows
 * and leaves the rest of the screen blank. No window size fixes that — the
 * window would have to reach back to the last full repaint, which for a
 * long-running agent is unbounded. Emulating the stream and serializing the
 * resulting grid is the only reconstruction that does not depend on how long
 * ago the program last redrew everything.
 */

import { Terminal } from "@xterm/headless";
import { SerializeAddon } from "@xterm/addon-serialize";
import { logger } from "./logger";

const log = logger.child({ component: "terminal-screen" });

/**
 * The emulator's OWN history depth, and the ceiling on what a COLD attach can
 * hand back. A warm attach ships the visible screen and nothing above it, so for
 * that path these rows exist only so a shrink/grow resize pair has something to
 * pull back — without them the screen handed out has blank rows across the top
 * where the app's own (far deeper) history would have shown content.
 */
export const SCREEN_SCROLLBACK_LINES = 200;

/**
 * Ceiling on the grid this will allocate. Comfortably past any real display —
 * a 5K panel at the smallest usable font is around 850x240 — and it exists
 * because the numbers arrive from a CLIENT.
 *
 * `terminal:resize` is validated as nothing more than a positive integer, which
 * was sufficient while the pair only ever reached the OS PTY, whose own resize
 * either succeeds or fails harmlessly. This VT allocates cells from it in the
 * bridge's own heap: 100000x5000 measured at 4.35 GB and no throw. Clamped here
 * rather than at the wire because this class is what allocates, and because the
 * PTY still deserves the geometry the client actually asked for.
 */
const MAX_SCREEN_COLS = 1000;
const MAX_SCREEN_ROWS = 500;

const clampCols = (cols: number) => Math.min(Math.max(Math.floor(cols) || 1, 1), MAX_SCREEN_COLS);
const clampRows = (rows: number) => Math.min(Math.max(Math.floor(rows) || 1, 1), MAX_SCREEN_ROWS);

/**
 * Blob size worth a log line. NOT a ceiling: there is nothing left to shed.
 * Truncating would hand the app a half-drawn screen, which is worse than a large
 * frame, so this bounds nothing and gates no send.
 *
 * Calibrated on the screen-only body, where the only shape that reaches it is
 * distinct truecolor fg+bg on every cell. A `history` body carries
 * `SCREEN_SCROLLBACK_LINES` more rows and can pass it on ordinary output, so the
 * line names which kind it measured rather than implying the pathological one.
 */
export const MAX_ATTACH_BLOB = 256_000;

/**
 * Puts the app's engine into the state `serialize()` assumes before its bytes
 * land: back on the PRIMARY buffer (`?1049l`), full-height scroll margins
 * (`[r`), SGR reset, the visible screen wiped (`2J`), cursor home.
 *
 * The SGR reset precedes the erase, and the order is load-bearing: `ED` honours
 * background-colour-erase, so an erase run under a latched non-default
 * background paints every cell the body does not overwrite in that colour.
 * `?1049l` RESTORES the attributes the matching `?1049h` saved — which is
 * exactly a TUI that set a background and then took the alternate screen — so
 * the engine reaches the erase holding one, and the tab came back fully
 * coloured behind the restored screen.
 *
 * The margin reset is the one the body cannot survive without. The app's engine
 * outlives every attach — one controller per tab, for the tab's whole life — so
 * a DECSTBM an earlier guest set is still latched in it, and the body places
 * rows with CR/LF and relative moves, every one of which is region-sensitive:
 * inside a stale band the whole restore collapses into a few rows. A region the
 * CURRENT guest still wants is deliberately not put back, and is not reachable
 * from here anyway — the body ends in a relative cursor placement, so nothing
 * may be inserted before it. Programs that use margins re-issue DECSTBM as part
 * of the scroll it exists for, so dropping one costs at most a misplaced scroll,
 * where a stale one costs the whole screen on every attach.
 *
 * Deliberately NOT `3J`. That erases the app's own primary scrollback — the
 * user's history, ten thousand lines of it — and this blob carries no history
 * that could put it back. Repeated attaches stay idempotent without it because
 * the body is exactly one screen: painted from home it fills the rows `2J` just
 * cleared and scrolls nothing into the buffer above.
 *
 * It is also NOT a reset — no RIS, no DECSTR — because a reset takes the guest's
 * startup-only modes (mouse tracking above all) with it and nothing on this path
 * could put them back.
 *
 * The middle run defaults every mode `_serializeModes` writes ONE half of and
 * `TerminalModeTracker` does not own: `[4l` insert, `?6l` origin, `?45l`
 * reverse-wrap, `?66l` keypad and `?9l` X10 mouse, which it can only turn ON —
 * and `?7h` autowrap, the one it can only turn OFF (it emits `[?7l` for a guest
 * with wrapping disabled and nothing at all otherwise). Without this, a mode the
 * guest has since changed stays as the app's tab-lifetime engine last saw it
 * forever: `?7l` from an ncurses `rmam` breaks wrapping for good, and a stale
 * `[4h` insert-shifts every later repaint. Defaulting them here and letting the
 * body's own half put back whatever the guest actually holds makes the pair
 * bidirectional, which neither is alone. `?6l` in particular must precede `[H`,
 * or the home is region-relative.
 *
 * The modes `TerminalModeTracker` owns are absent whether or not the serializer
 * can express them (`?1`, `?2004`, `?1004` and the `?1000` family it can; the
 * coordinate encodings it cannot). The supplement restates BOTH halves of those
 * after the body, so defaulting one here would be a second driver of state that
 * already has an owner — and defaulting one NEITHER can put back would strip
 * state off a live guest.
 */
const ATTACH_PREAMBLE =
  "\x1b[?1049l\x1b[r\x1b[?7h\x1b[4l\x1b[?6l\x1b[?45l\x1b[?66l\x1b[?9l\x1b[0m\x1b[2J\x1b[H";

/**
 * The COLD variant, for an engine that has rendered nothing for this terminal.
 *
 * Identical but for the leading `3J`, which the warm preamble deliberately
 * omits. A history body is taller than the screen by construction, so painting
 * it scrolls its own opening rows into the buffer above — which is the whole
 * point when the app has no history, and is what stacks a second copy on every
 * repeat. Erasing first makes the paint idempotent, and costs nothing precisely
 * because the caller has declared there is nothing there to erase. Sending this
 * to an engine that DOES hold history would destroy it, which is why the choice
 * is the app's: it is the only side that knows.
 */
const COLD_ATTACH_PREAMBLE =
  "\x1b[?1049l\x1b[r\x1b[?7h\x1b[4l\x1b[?6l\x1b[?45l\x1b[?66l\x1b[?9l\x1b[0m\x1b[3J\x1b[2J\x1b[H";

export class TerminalScreen {
  private readonly term: Terminal;
  private readonly addon: SerializeAddon;
  private disposed = false;

  /**
   * Chunks written but not yet parsed into the grid, oldest first.
   *
   * `settle()` is a weaker barrier than it looks: xterm fires a write's
   * callback from inside `_innerWrite`'s own loop and then keeps parsing the
   * writes queued behind it for the rest of its 12 ms slice, while that
   * callback has done nothing but queue a microtask. So a chunk that arrives
   * while a snapshot is pending is USUALLY in the serialized screen already,
   * and a caller replaying everything it watched arrive paints those bytes
   * twice. Only xterm can say which chunks it has consumed, and the per-write
   * callback is how it says so.
   */
  private readonly unparsed: string[] = [];

  constructor(cols: number, rows: number) {
    this.term = new Terminal({
      cols: clampCols(cols),
      rows: clampRows(rows),
      scrollback: SCREEN_SCROLLBACK_LINES,
      allowProposedApi: true,
    });
    this.addon = new SerializeAddon();
    this.term.loadAddon(this.addon);
  }

  /**
   * Feeds one raw PTY chunk. Fire-and-forget by design: xterm's write buffer is
   * asynchronous, and awaiting each 4 KB chunk costs a timer round-trip per
   * flush — two orders of magnitude off the throughput of writing straight
   * through. The parser carries its state across writes, so an escape split
   * across two PTY chunks still resolves as one sequence.
   *
   * Nothing above this may throw. `write()` raises once its unparsed backlog
   * passes xterm's own 50 MB ceiling — a guest that outruns the parser (`yes`,
   * a multi-MB build log) reaches it in milliseconds — and the only caller is
   * the PTY data callback, whose stack is a bare `setTimeout` flush. An
   * exception there is an `uncaughtException`, which this process answers by
   * shutting the whole host down: every project, every PTY, every agent on the
   * machine, because one terminal was noisy. The screen has already lost the
   * bytes xterm discarded and is stale until the guest repaints, which is a
   * wrong screen for one attach — a far smaller loss than the alternative.
   */
  feed(data: string): void {
    // A replaced generation's PTY keeps emitting until its tree is reaped, and
    // its spawn closure still holds THIS screen — writing into a disposed
    // terminal registers disposables on dead stores.
    if (this.disposed) return;
    this.unparsed.push(data);
    try {
      this.term.write(data, () => {
        // FIFO: xterm parses writes in order and fires their callbacks in the
        // same order, so the head is always the chunk this callback is for.
        this.unparsed.shift();
      });
    } catch (err) {
      // `write()` throws before it queues anything, so the chunk this call
      // just pushed is still the last one.
      this.unparsed.pop();
      log.warn("VT write dropped, screen is stale until the guest repaints: %s", err);
    }
  }

  resize(cols: number, rows: number): void {
    this.term.resize(clampCols(cols), clampRows(rows));
  }

  /** True once `dispose()` has run — a pending `settle()` still resolves after it. */
  get isDisposed(): boolean {
    return this.disposed;
  }

  /**
   * Whether anything written is still unparsed. Cheap enough to re-test between
   * settle rounds, which `pendingTail()` is not: the only way to reach a
   * non-empty tail is a guest outrunning the parser, and joining that is the
   * expensive part.
   */
  get hasPendingTail(): boolean {
    return this.unparsed.length > 0;
  }

  /**
   * Resolves once every chunk written so far has been parsed. An empty write's
   * callback is the only barrier the API offers against serializing a screen
   * that is still missing the last few frames.
   *
   * Separate from `serializeNow()` so a caller can re-test between them. This
   * is a real suspension point — the parser drains in 12 ms slices — and a
   * terminal can exit, be forgotten, or be respawned under the same id across
   * it.
   */
  settle(): Promise<void> {
    return new Promise<void>((resolve) => this.term.write("", () => resolve()));
  }

  /**
   * The complete byte sequence an attaching app applies verbatim: preamble,
   * then the serialized screen. Callers append nothing INSIDE it — the
   * serializer ends with a relative cursor restore, so anything inserted after
   * its content and before its tail lands the cursor somewhere else.
   *
   * Synchronous, and only valid on a live screen: serializing a disposed one
   * does not throw, it registers a disposable on a dead store and prints a raw
   * xterm leak stack. An exit during an attach is ordinary, not an error, so it
   * must not read like one — hence `isDisposed`, checked by the caller that
   * owns the barrier.
   */
  serializeNow(opts: { history?: boolean } = {}): string {
    // `scrollback: 0` — the visible grid alone — is the DEFAULT because history
    // the app already holds must not be erased to make room for the bridge's
    // much shorter copy: the app keeps thousands of lines, this keeps
    // `SCREEN_SCROLLBACK_LINES`.
    //
    // `history` inverts exactly that premise. It is set only by a caller whose
    // engine has rendered nothing for this terminal, where there is no deeper
    // copy to protect and one screen is a real loss — a scrolling build log
    // (the worktree setup transcript above all) re-opened on a second device
    // showed its last few rows and nothing else. Paired with
    // `COLD_ATTACH_PREAMBLE`, which erases first so the taller body may scroll
    // into the buffer above without stacking.
    const body = this.addon.serialize({
      scrollback: opts.history ? SCREEN_SCROLLBACK_LINES : 0,
    });
    if (body.length > MAX_ATTACH_BLOB) {
      log.warn(
        "%s attach blob %d bytes, past the %d mark",
        opts.history ? "cold" : "screen",
        body.length,
        MAX_ATTACH_BLOB,
      );
    }
    return (opts.history ? COLD_ATTACH_PREAMBLE : ATTACH_PREAMBLE) + body;
  }

  /**
   * The chunks a `serializeNow()` taken right now does NOT contain, in order:
   * what a caller must replay after the body for the pair to describe the same
   * instant its seq does. Read synchronously alongside the serialization —
   * nothing can arrive between two statements, so the two are atomic.
   */
  pendingTail(): string {
    return this.unparsed.join("");
  }

  /** `settle()` then `serializeNow()`, for callers with nothing to re-check between. */
  async snapshot(opts: { history?: boolean } = {}): Promise<string> {
    await this.settle();
    return this.serializeNow(opts);
  }

  dispose(): void {
    this.disposed = true;
    this.term.dispose();
  }
}
