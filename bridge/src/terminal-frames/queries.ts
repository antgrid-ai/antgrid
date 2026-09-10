import type { Terminal } from "@xterm/headless";

export interface TerminalQueryColors {
  foreground: string;
  background: string;
  cursor: string;
}

/** xterm dispatches handlers in parser order, so CPR and mode requests observe
 * preceding output even when a later command arrives in the same PTY chunk. */
export function installTerminalQueries(
  term: Terminal,
  reply: (data: string) => void,
  keyboardFlags: () => number,
  colors: TerminalQueryColors,
): () => void {
  const subscriptions = [
    term.onData(reply),
    term.parser.registerCsiHandler({ prefix: "?", final: "u" }, () => {
      reply(`\x1b[?${keyboardFlags()}u`);
      return true;
    }),
    term.parser.registerCsiHandler({ prefix: "=", final: "c" }, () => {
      reply("\x1bP!|00000000\x1b\\");
      return true;
    }),
    term.parser.registerCsiHandler({ prefix: ">", final: "q" }, () => {
      reply("\x1bP>|antgrid(1.0)\x1b\\");
      return true;
    }),
    ...([colors.foreground, colors.background, colors.cursor]).map((color, index) =>
      term.parser.registerOscHandler(10 + index, (data) => {
        if (data !== "?") return false;
        reply(`\x1b]${10 + index};${color}\x1b\\`);
        return true;
      })),
  ];
  return () => { for (const subscription of subscriptions) subscription.dispose(); };
}
