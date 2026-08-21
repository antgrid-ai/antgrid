/**
 * Latches the DEC private modes a PTY program has turned on, so a reconnecting
 * app can be told what state the terminal is actually in.
 *
 * The app rebuilds its VT engine from scratch on every attach and feeds it
 * nothing but the `ScrollbackBuffer` tail. Modes a TUI sets once at startup —
 * mouse tracking above all — scroll out of that window within about a second of
 * redraws, so the app's engine never learns mouse reporting is on and drops
 * every click before encoding it. Modes re-emitted per frame (cursor
 * visibility, synchronised output) survive by accident; the startup-only ones
 * cannot. Replaying a latched prelude ahead of the scrollback is what closes
 * that gap.
 */

/**
 * Modes worth restoring: they change how INPUT is encoded (mouse, cursor keys,
 * bracketed paste, focus) or which screen the replay lands on.
 *
 * Deliberately NOT tracked: 2026 (synchronised output). It brackets a single
 * frame, and replaying its "set" half would leave the app holding a frame that
 * never ends.
 */
const TRACKED_MODES: ReadonlySet<number> = new Set([
  1, // DECCKM — application cursor keys (changes arrow-key encoding)
  25, // cursor visibility
  1000, 1001, 1002, 1003, // mouse tracking
  1004, // focus in/out reporting
  1005, 1006, 1015, 1016, // mouse coordinate encodings
  1049, // alternate screen
  2004, // bracketed paste
]);

/** Longest incomplete DECSET prefix worth holding onto (`ESC [ ? 1000;1002;` and friends). */
const MAX_CARRY = 64;

/** An `ESC`, or an `ESC [` that could still grow into a DEC private mode set/reset. */
const INCOMPLETE_DECSET = /^\x1b(\[[?0-9;]*)?$/;

const DECSET = /\x1b\[\?([0-9;]*)([hl])/g;

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
      const set = m[2] === "h";
      for (const param of m[1].split(";")) {
        if (param === "") continue;
        const mode = Number(param);
        if (TRACKED_MODES.has(mode)) this.latched.set(mode, set);
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
   * The observed mode state as escape sequences, to be replayed BEFORE the
   * scrollback text. Anything the tail sets again lands after this and wins,
   * so the prelude can only ever restore state the window has since lost.
   */
  prelude(): string {
    if (this.latched.size === 0) return "";

    const parts: string[] = [];
    const emit = (mode: number) => {
      const set = this.latched.get(mode);
      if (set !== undefined) parts.push(`\x1b[?${mode}${set ? "h" : "l"}`);
    };

    // Alt-screen first: it swaps buffers and saves the cursor, so every other
    // mode — and the replayed text — must land on the screen the program is
    // actually drawing to.
    emit(1049);
    for (const mode of [...this.latched.keys()].sort((a, b) => a - b)) {
      if (mode !== 1049) emit(mode);
    }
    return parts.join("");
  }
}
