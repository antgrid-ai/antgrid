import { TerminalFrameSource } from "../src/terminal-frames/source";
import type { Terminal } from "@xterm/headless";

const cases = [
  { name: "fullscreen link and color", data: "\x1b[?1049h\x1b[2;3H\x1b]8;;https://example.com/report\x1b\\\x1b[38;2;20;100;200mOpen report\x1b]8;;\x1b\\\x1b[0m\x1b[5;9H", link: { row: 1, col: 2, uri: "https://example.com/report" } },
  { name: "wide Unicode", data: "wide 界 😀 ✅ end\r\nsecond row", link: null },
  { name: "wide hyperlink", data: "\x1b]8;;https://example.com/wide\x1b\\界😀link\x1b]8;;\x1b\\ done", link: { row: 0, col: 0, uri: "https://example.com/wide" } },
  { name: "wrapped rows", data: "x".repeat(79) + "\r\nprompt> ", link: null },
  { name: "combining characters", data: "e\u0301 a\u0308 o\u0302\r\ncombined", link: null },
  { name: "alternate buffer returns to normal", data: "normal\x1b[?1049h\x1b[2Jalternate\x1b[?1049l", link: null },
  { name: "erased hyperlink", data: "\x1b]8;;https://example.com/erased\x1b\\erase me\x1b]8;;\x1b\\\r\x1b[2Kplain", link: { row: 0, col: 0, uri: null } },
  { name: "split escape sequences", data: ["\x1b[38;2;", "80;140;200mcolored\x1b[", "0m\r\n\x1b]8;;https://example.com/split\x1b", "\\split link\x1b]8;;\x1b\\"], link: { row: 1, col: 0, uri: "https://example.com/split" } },
];
const fixtures = [];
for (const entry of cases) {
  const source = new TerminalFrameSource(40, 6);
  try {
    for (const chunk of Array.isArray(entry.data) ? entry.data : [entry.data]) source.feed(chunk);
    await source.settle();
    const buffer = (source as unknown as { term: Terminal }).term.buffer.active;
    fixtures.push({ name: entry.name, frame: source.capture(0),
      lines: source.visibleLines().map((line) => line.trimEnd()), links: entry.link ? [entry.link] : [],
      cursor: { row: buffer.cursorY, col: buffer.cursorX } });
  } finally { source.dispose(); }
}
console.log(JSON.stringify(fixtures));
