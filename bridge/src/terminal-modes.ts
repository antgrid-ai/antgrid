/**
 * Latches the DEC private modes a PTY program has turned on and off, so a
 * reconnecting app can be told what state the terminal is actually in.
 *
 * The app's VT engine OUTLIVES every attach, and the blob `TerminalScreen`
 * serializes can only ever turn a mode on: `@xterm/addon-serialize` emits the
 * "set" half and has no vocabulary for the other one. So the blob alone leaves
 * the app holding two kinds of wrong state — a mode it never learned (mouse
 * coordinate encoding above all, which a TUI sets once at startup and never
 * restates, and without which every click past column 95 is dropped before it
 * is encoded), and a mode it learned once and the guest has since turned OFF
 * behind a suppressed window. This tracker answers both by restating the whole
 * latched state after the blob.
 */

/**
 * Modes worth restoring: they change how INPUT is encoded (mouse, cursor keys,
 * bracketed paste, focus). 1049 is tracked but never replayed — see ALT_SCREEN.
 *
 * Deliberately NOT tracked: 2026 (synchronised output). It brackets a single
 * frame, and replaying its "set" half would leave the app holding a frame that
 * never ends.
 */
export const TRACKED_MODES: ReadonlySet<number> = new Set([
  1, // DECCKM — application cursor keys (changes arrow-key encoding)
  25, // cursor visibility
  1000, 1001, 1002, 1003, // mouse tracking
  1004, // focus in/out reporting
  1005, 1006, 1015, 1016, // mouse coordinate encodings
  1049, // alternate screen
  2004, // bracketed paste
]);

/** The only tracked mode whose reset state is ON. */
const CURSOR_VISIBLE = 25;

/**
 * The one tracked mode the supplement must never carry: the blob has already
 * switched to the alternate screen and filled it, and a second `?1049h` re-saves
 * the cursor and re-clears the buffer it just painted.
 */
const ALT_SCREEN = 1049;

/**
 * Where a terminal reset leaves each tracked mode. Cursor visibility is the one
 * whose default is ON; every other mode here is an opt-in the guest asks for.
 *
 * The defaults are LATCHED rather than forgotten, and that is the whole point.
 * The app's engine outlives the reset, so dropping the entries would leave it
 * holding the pre-reset state with nothing left to contradict it — the exact
 * failure the tracker exists to prevent, arrived at from the other direction.
 */
const RESET_STATE: ReadonlyMap<number, boolean> = new Map(
  [...TRACKED_MODES].map((mode) => [mode, mode === CURSOR_VISIBLE]),
);

/**
 * What DECSTR (a SOFT reset) leaves alone: mouse tracking and its coordinate
 * encoding. Measured against `@xterm/headless`, whose soft reset clears
 * `decPrivateModes` but not the separate mouse service — so a soft reset drops
 * DECCKM, focus reporting and bracketed paste while a TUI's mouse tracking
 * survives it. Latching the mouse family off here would turn every click in a
 * still-live TUI into nothing.
 */
const SOFT_RESET_PRESERVES: ReadonlySet<number> = new Set([
  1000, 1001, 1002, 1003, 1005, 1006, 1015, 1016, ALT_SCREEN,
]);

/** Longest incomplete prefix worth holding onto (`ESC [ ? 1000;1002;`, `ESC [ !` and friends). */
const MAX_CARRY = 64;

/** An `ESC`, or an `ESC [` that could still grow into one of the sequences below. */
const INCOMPLETE_DECSET = /^\x1b(\[[?!0-9;]*)?$/;

/**
 * DEC private set/reset, plus the two resets that silently invalidate every
 * latch: RIS (`ESC c`, what `reset`/`tput reset` sends) and DECSTR (`CSI ! p`).
 * Scanned by one regex so they are applied in STREAM order — a mode set after a
 * reset must survive it, and a separate pass could not tell which came first.
 */
const DECSET = /\x1b(?:\[\?([0-9;]*)([hl])|\[!p|c)/g;

export class TerminalModeTracker {
  private latched = new Map<number, boolean>();
  private carry = "";

  /**
   * Feeds one raw PTY chunk. Chunk boundaries are honoured: a sequence split
   * across two writes is carried and resolved on the next call, which matters
   * because a TUI's startup burst is exactly where these modes are set and
   * exactly where the PTY is most likely to fragment.
   */
  feed(data: string): void {
    if (this.carry === "" && !data.includes("\x1b")) return;

    const scanned = this.carry + data;
    this.carry = "";

    let consumed = 0;
    DECSET.lastIndex = 0;
    for (let m = DECSET.exec(scanned); m !== null; m = DECSET.exec(scanned)) {
      consumed = DECSET.lastIndex;
      if (m[2] === undefined) {
        this.applyReset(m[0] === "\x1bc");
        continue;
      }
      const set = m[2] === "h";
      for (const param of m[1].split(";")) {
        if (param === "") continue;
        const mode = Number(param);
        if (!TRACKED_MODES.has(mode)) continue;
        // Deleted before re-inserting so the map's iteration order is
        // LAST-WRITE order, which is what the supplement replays. Several of
        // these modes share one slot in a VT engine — `?1000`/`?1002`/`?1003`
        // are one tracking protocol and `?1005`/`?1006`/`?1015`/`?1016` one
        // encoding — so a guest that set `?1002h` and then `?1000h` ends on
        // VT200, and replaying them in numeric order would end on drag.
        this.latched.delete(mode);
        this.latched.set(mode, set);
      }
    }

    // Only the trailing bytes no complete match already claimed can still be a
    // split sequence.
    const tail = scanned.slice(Math.max(consumed, scanned.length - MAX_CARRY));
    const esc = tail.lastIndexOf("\x1b");
    if (esc !== -1 && INCOMPLETE_DECSET.test(tail.slice(esc))) {
      this.carry = tail.slice(esc);
    }
  }

  /**
   * A reset invalidates the latches wholesale, and it arrives as neither a set
   * nor a reset of any individual mode — so without this a plain `reset` leaves
   * the tracker restating the dead TUI's mouse tracking and bracketed paste
   * over the top of a serialization that correctly says neither is on, and the
   * app's tab keeps swallowing clicks at a bare shell until the agent restarts.
   * The supplement lands after the body, so the stale answer is the one that
   * wins.
   */
  private applyReset(hard: boolean): void {
    for (const [mode, value] of RESET_STATE) {
      if (!hard && SOFT_RESET_PRESERVES.has(mode)) continue;
      this.latched.delete(mode);
      this.latched.set(mode, value);
    }
  }

  /**
   * Every latched mode, set half and reset half alike, as escape sequences to
   * be appended AFTER the whole attach blob.
   *
   * The whole state rather than only what the serializer misses, because the
   * serializer has no reset half at all: a mode the guest turned OFF while the
   * app was away survives in the app's engine unless something restates it, and
   * the app is then left encoding clicks for a tracking mode the guest has
   * stopped reading (or wrapping a paste in brackets nothing will strip). The
   * overlap with what the blob already set is redundant, not harmful — these
   * are idempotent, and ours land last.
   *
   * Appending is only safe because every tracked mode changes input encoding or
   * cursor visibility and nothing about the grid: the blob ends in a relative
   * cursor restore, so a sequence that moved or painted would land the cursor
   * somewhere the source never had it.
   */
  supplementalPrelude(): string {
    const parts: string[] = [];
    for (const [mode, set] of this.latched) {
      if (mode === ALT_SCREEN) continue;
      parts.push(`\x1b[?${mode}${set ? "h" : "l"}`);
    }
    return parts.join("");
  }
}
