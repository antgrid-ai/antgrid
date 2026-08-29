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
 * The emulator's OWN history depth. It is never serialized — an attach ships
 * the visible screen and nothing above it — but a shrink/grow resize pair still
 * needs rows to pull back, or the screen this hands out has blank rows across
 * the top where the app's own (far deeper) history would have shown content.
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
 * Blob size worth a log line. NOT a ceiling: there is nothing left to shed. The
 * body is already the visible grid alone, and the only shape that reaches this
 * number — distinct truecolor fg+bg on every cell — has no compressible part.
 * Truncating it would hand the app a half-drawn screen, which is worse than a
 * large frame, so this bounds nothing and gates no send.
 */
export const MAX_ATTACH_BLOB = 256_000;

/**
 * Puts the app's engine into the state `serialize()` assumes before its bytes
 * land: back on the PRIMARY buffer (`?1049l`), full-height scroll margins
 * (`[r`), the visible screen wiped (`2J`), cursor home, SGR reset.
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
 * The middle run defaults exactly the modes `_serializeModes` can emit but has
 * no clearing form for — `?7h` autowrap, `[4l` insert, `?6l` origin, `?45l`
 * reverse-wrap, `?66l` keypad, `?9l` X10 mouse. The serializer writes the SET
 * half only, so without this a mode the guest has since turned off stays on in
 * the app's tab-lifetime engine forever: `?7l` from an ncurses `rmam` breaks
 * wrapping for good, and a stale `[4h` insert-shifts every later repaint.
 * Defaulting them here and letting the body's own set-half put back whatever the
 * guest actually holds makes the pair bidirectional, which neither is alone.
 * `?6l` in particular must precede `[H`, or the home is region-relative.
 *
 * `TerminalModeTracker` covers the rest — the input-encoding modes, which the
 * serializer cannot express at all — and only those. Defaulting a mode here that
 * the supplement also restates is redundant, not wrong; defaulting one NEITHER
 * can put back would strip state off a live guest.
 */
const ATTACH_PREAMBLE =
  "\x1b[?1049l\x1b[r\x1b[?7h\x1b[4l\x1b[?6l\x1b[?45l\x1b[?66l\x1b[?9l\x1b[2J\x1b[H\x1b[0m";

export class TerminalScreen {
  private readonly term: Terminal;
  private readonly addon: SerializeAddon;
  private disposed = false;

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
    try {
      this.term.write(data);
    } catch (err) {
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
  serializeNow(): string {
    // `scrollback: 0` — the visible grid alone — is a correctness requirement,
    // not a size choice. History the app already holds must not be erased to
    // make room for the bridge's much shorter copy, and history it does NOT
    // hold cannot be sent without erasing first: a body taller than the screen
    // scrolls its own opening rows into the buffer above, stacking a fresh copy
    // there on every re-attach.
    const body = this.addon.serialize({ scrollback: 0 });
    if (body.length > MAX_ATTACH_BLOB) {
      log.warn("attach blob %d bytes, past the %d mark", body.length, MAX_ATTACH_BLOB);
    }
    return ATTACH_PREAMBLE + body;
  }

  /** `settle()` then `serializeNow()`, for callers with nothing to re-check between. */
  async snapshot(): Promise<string> {
    await this.settle();
    return this.serializeNow();
  }

  dispose(): void {
    this.disposed = true;
    this.term.dispose();
  }
}
