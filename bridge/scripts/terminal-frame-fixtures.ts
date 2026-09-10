import { TerminalFrameSource } from "../src/experimental/terminal-frame-source";
import type { Terminal } from "@xterm/headless";

const cases = [
  { name: "fullscreen link and color", data: "\x1b[?1049h\x1b[2;3H\x1b]8;;https://example.com/report\x1b\\\x1b[38;2;20;100;200mOpen report\x1b]8;;\x1b\\\x1b[0m\x1b[5;9H", link: { row: 1, col: 2, uri: "https://example.com/report" } },
  { name: "wide Unicode", data: "wide 界 😀 ✅ end\r\nsecond row", link: null },
  { name: "wide hyperlink", data: "\x1b]8;;https://example.com/wide\x1b\\界😀link\x1b]8;;\x1b\\ done", link: { row: 0, col: 0, uri: "https://example.com/wide" } },
  { name: "wrapped rows", data: "x".repeat(79) + "\r\nprompt> ", link: null },
];
const fixtures = [];
for (const entry of cases) {
  const source = new TerminalFrameSource(40, 6);
  try {
    source.feed(entry.data);
    await source.settle();
    const buffer = (source as unknown as { term: Terminal }).term.buffer.active;
    fixtures.push({ name: entry.name, frame: source.capture(0),
      lines: source.visibleLines().map((line) => line.trimEnd()), link: entry.link,
      cursor: { row: buffer.cursorY, col: buffer.cursorX } });
  } finally { source.dispose(); }
}
console.log(JSON.stringify(fixtures));
