import type { Terminal } from "@xterm/headless";
import { VtCapabilityResponder } from "../vt-capability-responder";

export interface TerminalQueryColors {
  foreground: string;
  background: string;
  cursor: string;
}

/**
 * Answers capability queries at the PARSER position, so a query observes the
 * output that preceded it rather than later bytes in the same PTY chunk.
 *
 * Every byte comes from `VtCapabilityResponder`, which stays the single audited
 * source of truth for what this machine claims to be: the handlers below decide
 * WHEN a query is answered, never WHAT it is answered with. Two replies are
 * exceptions, and for the same reason — the byte responder runs no VT model and
 * has to guess where this one can read the answer. CPR is why a parser-position
 * responder is worth having at all, since the guess there is `1;1R`. The Kitty
 * keyboard flags are the second: the byte responder cannot see the push/pop
 * stack, so its `0` is a guess in exactly the same sense.
 *
 * WHEN follows xterm's own rule — a query is answered whenever its leading
 * parameter is absent or 0, whatever follows it — which is wider than the byte
 * responder's whole-string match. The forms the two disagree on are pinned in
 * `bridge/tests/terminal-frame-queries.test.ts`.
 *
 * Nothing subscribes to `term.onData`. xterm answers a wider and different set
 * of queries than this bridge has audited (DECRQSS with a fabricated SGR, DA1 as
 * a VT100, DECXCPR), so a blanket forward would put un-audited bytes on the PTY
 * under xterm's identity. Anything not registered here is deliberately
 * unanswered, and an unanswered query costs a TUI a fallback, never a hang.
 *
 * OSC 10/11/12 are NOT answered here even though the byte responder answers
 * them: `registerOscHandler` surfaces the payload only, never the ST-vs-BEL
 * terminator the guest used, and a guest reading until BEL never sees one.
 * Those three stay with the byte-level responder, which sees raw bytes.
 */
export function installTerminalQueries(
  term: Terminal,
  reply: (data: string) => void,
  keyboardFlags: () => number,
  /** The ACTIVE buffer's top scroll margin, 0-based, for the DECOM-relative half
   *  of CPR. Supplied rather than tracked from the parser: margins are per
   *  buffer and each buffer's survive a switch away and back, so one scalar
   *  maintained here answers against the other buffer's region after every
   *  alternate-screen switch. */
  regionTop: () => number,
  colors: TerminalQueryColors,
): () => void {
  const bytes = new VtCapabilityResponder(colors);
  // Private xterm state with no public accessor — same caution as
  // `XtermFrameAdapter`: read defensively, through `typeof` guards below,
  // never assumed. A shape miss falls back to `undefined`, which is exactly
  // what these two modes already answered before this reads them at all —
  // the byte responder's scan, unimproved but never broken by an upgrade.
  const core = (term as unknown as {
    _core?: {
      coreService?: { isCursorHidden?: boolean };
      coreMouseService?: { activeEncoding?: string };
    };
  })._core;
  const mouseEncoding = (): string | undefined => core?.coreMouseService?.activeEncoding;

  const num = (param: number | number[] | undefined): number =>
    typeof param === "number" ? param : (param?.[0] ?? 0);
  /** A query whose only legal parameter is 0 or omitted. */
  const isDefaulted = (params: (number | number[])[]): boolean =>
    params.length === 0 || num(params[0]) === 0;
  /**
   * Real state for the DEC private modes xterm's own `Terminal` tracks,
   * read fresh for every DECRQM rather than from the byte responder's scan of
   * the guest's set/reset bytes below. That scan never observes DECSTR or
   * RIS — neither emits the `CSI ? Pm h|l` it watches for — so a query
   * answered from its tracked state alone kept reporting a mode the guest had
   * set long after one of those silently turned it back off. `undefined` for
   * a mode xterm's model does not expose; that scan is still what answers
   * those, unchanged.
   */
  const liveDecMode = (mode: number): boolean | undefined => {
    switch (mode) {
      case 1: return term.modes.applicationCursorKeysMode;
      case 7: return term.modes.wraparoundMode;
      case 25: return typeof core?.coreService?.isCursorHidden === "boolean"
        ? !core.coreService.isCursorHidden : undefined;
      case 1000: return term.modes.mouseTrackingMode === "vt200";
      case 1002: return term.modes.mouseTrackingMode === "drag";
      case 1003: return term.modes.mouseTrackingMode === "any";
      // xterm tracks one ACTIVE mouse encoding rather than three independent
      // bits, so these read as mutually exclusive — matching what the guest's
      // own last `h` actually selected in this engine, which is the same
      // ground truth every other case here reads from. 1015 (urxvt) is NOT
      // one of them: measured against the real engine (`_encodings` lists
      // only DEFAULT/SGR/SGR_PIXELS), enabling it moves nothing this can
      // read, so claiming a live answer for it would be a confident WRONG one
      // where the byte scan below is at least right until the guest's next
      // DECSTR/RIS — left unhandled here on purpose.
      case 1006: { const enc = mouseEncoding(); return enc === undefined ? undefined : enc === "SGR"; }
      case 1016: { const enc = mouseEncoding(); return enc === undefined ? undefined : enc === "SGR_PIXELS"; }
      case 1004: return term.modes.sendFocusMode;
      case 47: case 1047: case 1049: return term.buffer.active.type === "alternate";
      case 2004: return term.modes.bracketedPasteMode;
      case 2026: return term.modes.synchronizedOutputMode;
      default: return undefined;
    }
  };
  /**
   * Handlers run inside xterm's parse loop, which retires neither the escape
   * being answered nor the chunk carrying it until the handler returns — so a
   * throw out of `reply` leaves the write buffer undrained and the terminal
   * parses nothing for the rest of the process. A PTY that has gone away is not
   * a parse failure, and the guest's next query is answered normally.
   */
  const send = (data: string): void => {
    try { reply(data); } catch { /* the PTY is gone; the parser is not */ }
  };
  const answer = (query: string): void => {
    const out = bytes.feed(query);
    if (out) send(out);
  };

  const cursorPosition = (): string => {
    const buffer = term.buffer.active;
    // A pending wrap parks the cursor at `cols`; a terminal reports the last
    // column until the wrap is taken. Writing a string and reading CPR back is
    // the standard grapheme-width probe, so an off-by-one here corrupts every
    // width the guest computes afterwards.
    const col = Math.min(buffer.cursorX, term.cols - 1) + 1;
    const row = term.modes.originMode ? buffer.cursorY - regionTop() : buffer.cursorY;
    return `\x1b[${Math.max(row + 1, 1)};${col}R`;
  };

  const subscriptions = [
    term.parser.registerCsiHandler({ final: "c" }, (params) => {
      if (isDefaulted(params)) answer("\x1b[c");
      return true;
    }),
    term.parser.registerCsiHandler({ prefix: ">", final: "c" }, (params) => {
      if (isDefaulted(params)) answer("\x1b[>c");
      return true;
    }),
    term.parser.registerCsiHandler({ prefix: "=", final: "c" }, (params) => {
      if (isDefaulted(params)) answer("\x1b[=c");
      return true;
    }),
    term.parser.registerCsiHandler({ prefix: ">", final: "q" }, (params) => {
      if (isDefaulted(params)) answer("\x1b[>0q");
      return true;
    }),
    term.parser.registerCsiHandler({ final: "n" }, (params) => {
      const request = num(params[0]);
      if (request === 5) answer("\x1b[5n");
      else if (request === 6) send(cursorPosition());
      return true;
    }),
    term.parser.registerCsiHandler({ prefix: "?", final: "u" }, () => {
      send(`\x1b[?${keyboardFlags()}u`);
      return true;
    }),
    term.parser.registerCsiHandler({ prefix: "?", intermediates: "$", final: "p" }, (params) => {
      const mode = num(params[0]);
      const live = liveDecMode(mode);
      // Sync the byte responder's tracked state to reality for a mode xterm
      // exposes directly, immediately before it formats the reply from that
      // state — DECSTR and RIS reach it no other way.
      if (live !== undefined) bytes.feed(`\x1b[?${mode}${live ? "h" : "l"}`);
      answer(`\x1b[?${mode}$p`);
      return true;
    }),
    // The guest's own mode changes, so DECRQM answers what it actually set.
    ...["h", "l"].map((final) =>
      term.parser.registerCsiHandler({ prefix: "?", final }, (params) => {
        bytes.feed(`\x1b[?${params.map(num).join(";")}${final}`);
        return false;
      })),
    // RIS returns every DEC private mode to its power-on default. The modes
    // above answer from xterm's own live state regardless of this, but the
    // ones `liveDecMode` returns `undefined` for have no live state to fall
    // back on except this scan, and a scan never observes an ESC sequence —
    // without this it would keep reporting whatever the guest set before the
    // reset forever. A second, independent handler for the same final byte:
    // `TerminalFrameSource`'s own (source.ts) clears history and mode-tracker
    // state; this clears the byte responder's, and xterm dispatches both.
    term.parser.registerEscHandler({ final: "c" }, () => {
      bytes.reset();
      return false;
    }),
  ];
  return () => { for (const subscription of subscriptions) subscription.dispose(); };
}
