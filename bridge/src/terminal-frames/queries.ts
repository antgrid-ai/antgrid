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
 * WHEN a query is answered, never WHAT it is answered with. The one exception is
 * CPR, which is the reason a parser-position responder is worth having at all —
 * the byte responder runs no VT model and must guess `1;1R`, where this one
 * reads the real cursor.
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
  colors: TerminalQueryColors,
): () => void {
  const bytes = new VtCapabilityResponder(colors);
  /** Top scroll margin, 0-based. Tracked because CPR is DECOM-relative and no
   *  public xterm API exposes the margins. */
  let marginTop = 0;

  const num = (param: number | number[] | undefined): number =>
    typeof param === "number" ? param : (param?.[0] ?? 0);
  /** A query whose only legal parameter is 0 or omitted. */
  const isDefaulted = (params: (number | number[])[]): boolean =>
    params.length === 0 || num(params[0]) === 0;
  const answer = (query: string): void => {
    const out = bytes.feed(query);
    if (out) reply(out);
  };

  const cursorPosition = (): string => {
    const buffer = term.buffer.active;
    // A pending wrap parks the cursor at `cols`; a terminal reports the last
    // column until the wrap is taken. Writing a string and reading CPR back is
    // the standard grapheme-width probe, so an off-by-one here corrupts every
    // width the guest computes afterwards.
    const col = Math.min(buffer.cursorX, term.cols - 1) + 1;
    const row = term.modes.originMode ? buffer.cursorY - marginTop : buffer.cursorY;
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
      else if (request === 6) reply(cursorPosition());
      return true;
    }),
    term.parser.registerCsiHandler({ prefix: "?", final: "u" }, () => {
      reply(`\x1b[?${keyboardFlags()}u`);
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
    term.parser.registerCsiHandler({ final: "r" }, (params) => {
      // Mirrors xterm's own DECSTBM validity gate; an invalid region is ignored
      // by xterm, so tracking it would answer CPR against margins it never set.
      const top = num(params[0]) || 1;
      const requested = params.length < 2 ? 0 : num(params[1]);
      const bottom = requested === 0 || requested > term.rows ? term.rows : requested;
      if (bottom > top) marginTop = top - 1;
      return false;
    }),
    // Margins alone are re-derived here; DEC mode state is deliberately left to
    // the byte responder, so both paths answer a DECRQM identically after a RIS.
    term.parser.registerCsiHandler({ intermediates: "!", final: "p" }, () => {
      marginTop = 0;
      return false;
    }),
    term.parser.registerEscHandler({ final: "c" }, () => {
      marginTop = 0;
      return false;
    }),
    term.onResize(() => { marginTop = 0; }),
  ];
  return () => { for (const subscription of subscriptions) subscription.dispose(); };
}
