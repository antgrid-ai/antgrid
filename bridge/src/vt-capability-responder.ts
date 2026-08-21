/**
 * Answers the capability queries a TUI emits at startup, on behalf of the PTY.
 *
 * The bridge is the SOLE responder. The app's VT engine (libghostty) answers
 * DA1/DA2/DA3/XTVERSION/DSR/DECRQM/kitty itself, so the app suppresses those
 * while parsing guest output (`forwardGuestQueryReplies: false` on the
 * controller's external transport). Two responders is not a redundancy — the
 * app's reply costs a relay round-trip, and terminal query protocols are FIFO,
 * so a late duplicate is matched against whatever query is pending by then.
 *
 * Answering at all is not optional either: with no viewer attached there is no
 * engine, and a TUI that gets no answer degrades. opencode falls back to a
 * "diff/economy" rendering strategy that leaks popup-bg attributes into cells
 * the popup vacated; Claude Code's fullscreen renderer never reaches its first
 * frame, and its second such launch disables fullscreen for that version.
 *
 * Deliberately NOT answered, because the reply depends on screen state this
 * side has no model of: DECRQSS (current SGR) and OSC 4 (palette). Both are
 * paired with DA1 as a barrier by every TUI that sends them, so an unanswered
 * one costs a missing optimization and never a hang.
 */

/** Longest prefix of an in-flight escape sequence carried between chunks. */
const MAX_CARRY = 256;

/**
 * DEC private modes we admit to recognising. A DECRQM for anything outside
 * this set is answered 0 ("not recognised"), which is the honest answer and
 * the one that makes a TUI use its fallback rather than trust a mode nothing
 * on this path implements.
 */
const RECOGNIZED_DEC_MODES = new Set([
  1, // DECCKM   application cursor keys
  7, // DECAWM   autowrap
  12, // cursor blink
  25, // DECTCEM  cursor visible
  47, 1047, 1048, 1049, // alternate screen
  1000, 1002, 1003, 1006, 1015, 1016, // mouse tracking + encodings
  1004, // focus in/out events
  2004, // bracketed paste
  2026, // synchronised output
  2027, // grapheme-cluster width
  2031, // color-scheme change notifications
]);

/** Modes a terminal comes up with already set. */
const DEFAULT_SET_DEC_MODES = [7, 25];

/**
 * One complete query, matched in stream order so a DA1 and a DA2 in the same
 * chunk are told apart by WHICH alternative matched rather than by a
 * chunk-wide "does a DA2 appear anywhere" test — that test suppressed the DA1
 * reply whenever a TUI batched both into one write, which is the common case.
 * Order matters: the `>`/`=` forms must be tried before bare DA1.
 */
const QUERY = new RegExp(
  [
    "\\x1b\\]([0-9]+);\\?(\\x07|\\x1b\\\\)", // 1,2  OSC n ; ? — colour query
    "\\x1b\\[>(0?)c", //                        3     DA2
    "\\x1b\\[=(0?)c", //                        4     DA3
    "\\x1b\\[(0?)c", //                         5     DA1
    "\\x1b\\[>(0?)q", //                        6     XTVERSION
    "\\x1b\\[\\?([0-9]+)\\$p", //               7     DECRQM
    "\\x1b\\[6n", //                                  DSR — cursor position
    "\\x1b\\[5n", //                                  DSR — operating status
    "\\x1b\\[\\?u", //                                kitty keyboard flags
  ].join("|"),
  "g",
);

/** DEC private mode set/reset in the guest's own output: CSI ? Pm ; Pm h|l */
const DEC_MODE_SET = /\x1b\[\?([0-9;]+)([hl])/g;

/**
 * Trailing bytes that could still grow into a query: a bare ESC, a CSI with
 * only parameter/intermediate bytes so far, or an unterminated OSC/DCS.
 */
const PARTIAL_TAIL =
  /^\x1b(?:\[[\x20-\x3f]*|\][^\x07\x1b]*|P[^\x1b]*|[\x20-\x2f]*)?$/;

export interface VtCapabilityResponderOptions {
  /** Default foreground, as an xterm OSC 10 `rgb:` value. */
  foreground: string;
  /** Default background, as an xterm OSC 11 `rgb:` value. */
  background: string;
  /** Cursor colour, as an xterm OSC 12 `rgb:` value. */
  cursor: string;
}

export class VtCapabilityResponder {
  private carry = "";
  private readonly decModes = new Map<number, boolean>();
  private readonly colors: Record<string, string>;

  constructor(opts: VtCapabilityResponderOptions) {
    this.colors = {
      "10": opts.foreground,
      "11": opts.background,
      "12": opts.cursor,
    };
    for (const mode of DEFAULT_SET_DEC_MODES) this.decModes.set(mode, true);
  }

  /**
   * Consumes one chunk of PTY output and returns the bytes to write back, or
   * `""`. Replies come out in the order their queries appeared.
   */
  feed(chunk: string): string {
    if (this.carry === "" && !chunk.includes("\x1b")) {
      return ""; // fast path: nothing here can be a query, nothing was pending
    }

    // A query split across two PTY writes is the norm under ConPTY, which
    // chunks on its own schedule and not on sequence boundaries. `carry` only
    // ever holds an INCOMPLETE sequence, so re-scanning it here cannot match
    // anything the previous pass already answered or counted.
    const buf = this.carry + chunk;
    this.carry = "";

    this.trackModeChanges(buf);

    const replies: string[] = [];
    QUERY.lastIndex = 0;
    let lastEnd = 0;
    for (let m = QUERY.exec(buf); m !== null; m = QUERY.exec(buf)) {
      lastEnd = m.index + m[0].length;
      const reply = this.answer(m);
      if (reply) replies.push(reply);
    }

    const escIdx = buf.lastIndexOf("\x1b");
    if (escIdx >= lastEnd) {
      const tail = buf.slice(escIdx);
      if (tail.length <= MAX_CARRY && PARTIAL_TAIL.test(tail)) {
        this.carry = tail;
      }
    }

    return replies.join("");
  }

  private answer(m: RegExpExecArray): string | null {
    const [full, oscWhich, oscTerm, da2, da3, da1, xtver, decrqm] = m;

    if (oscWhich !== undefined) {
      const rgb = this.colors[oscWhich];
      return rgb ? `\x1b]${oscWhich};${rgb}${oscTerm}` : null;
    }
    // DA2 — xterm-style: terminal id 1, version 1000, no cartridge ROM.
    if (da2 !== undefined) return "\x1b[>1;1000;0c";
    // DA3 — unit id, in the shape libghostty reports.
    if (da3 !== undefined) return "\x1bP!|00000000\x1b\\";
    // DA1 — the xterm VT420 feature set including ANSI colour (22).
    if (da1 !== undefined) return "\x1b[?64;1;2;6;9;15;18;21;22c";
    if (xtver !== undefined) return "\x1bP>|antgrid(1.0)\x1b\\";
    if (decrqm !== undefined) {
      const mode = Number(decrqm);
      // 0 = not recognised, 1 = set, 2 = reset. Reporting a mode SET that the
      // guest never enabled is a lie it can act on — a TUI told bracketed
      // paste is already on skips enabling it, and pastes then arrive raw.
      const state = !RECOGNIZED_DEC_MODES.has(mode)
        ? 0
        : this.decModes.get(mode)
          ? 1
          : 2;
      return `\x1b[?${mode};${state}$y`;
    }
    if (full === "\x1b[6n") {
      // Cursor position. This side runs no VT model, so 1;1 is a guess — but
      // it is now the ONLY answer the guest gets, where before it also got the
      // app engine's real one and had to pick between them.
      return "\x1b[1;1R";
    }
    if (full === "\x1b[5n") return "\x1b[0n"; // operating status: OK
    if (full === "\x1b[?u") return "\x1b[?0u"; // kitty kbd: no flags
    return null;
  }

  /** Follows the guest's own mode changes so DECRQM can answer truthfully. */
  private trackModeChanges(buf: string): void {
    if (!buf.includes("\x1b[?")) return;
    DEC_MODE_SET.lastIndex = 0;
    for (let m = DEC_MODE_SET.exec(buf); m !== null; m = DEC_MODE_SET.exec(buf)) {
      const set = m[2] === "h";
      for (const raw of m[1].split(";")) {
        if (raw === "") continue;
        this.decModes.set(Number(raw), set);
      }
    }
  }
}
