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

  const num = (param: number | number[] | undefined): number =>
    typeof param === "number" ? param : (param?.[0] ?? 0);
  /** A query whose only legal parameter is 0 or omitted. */
  const isDefaulted = (params: (number | number[])[]): boolean =>
    params.length === 0 || num(params[0]) === 0;
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
      answer(`\x1b[?${num(params[0])}$p`);
      return true;
    }),
    // The guest's own mode changes, so DECRQM answers what it actually set.
    ...["h", "l"].map((final) =>
      term.parser.registerCsiHandler({ prefix: "?", final }, (params) => {
        bytes.feed(`\x1b[?${params.map(num).join(";")}${final}`);
        return false;
      })),
  ];
  return () => { for (const subscription of subscriptions) subscription.dispose(); };
}
