import { resolve } from "node:path";
import { TerminalFrameSource } from "../src/terminal-frames/source";
import { encodePathLink } from "../src/terminal-links/grammar";
import { PathStatCache, type LinkFs, type LinkFsStats, type PathStatus } from "../src/terminal-links/stat-cache";
import type { Terminal } from "@xterm/headless";

/** Plain-text link detection for a case: what the fake filesystem holds, and
 *  the checkout root the source resolves relative paths against. */
interface LinkSetup { statuses: Record<string, PathStatus>; root: string }
interface Case {
  name: string;
  data: string | string[];
  link: { row: number; col: number; uri: string | null } | null;
  links?: LinkSetup;
}

const root = process.platform === "win32" ? "C:\\fixture-root" : "/fixture-root";

/** Every ancestor of a listed path is a directory, so the cache's component
 *  walk finds a real-looking tree. */
function fakeFs(statuses: Record<string, PathStatus>): LinkFs {
  const stats = (path: string): Promise<LinkFsStats> => {
    const sep = process.platform === "win32" ? "\\" : "/";
    const own = statuses[path];
    const kind = own === "file" || own === "dir" ? own
      : Object.keys(statuses).some((key) => key.startsWith(path + sep)) ? "dir" : undefined;
    if (!kind) return Promise.reject(new Error("ENOENT"));
    return Promise.resolve({ isFile: () => kind === "file", isDirectory: () => kind === "dir", isSymbolicLink: () => false });
  };
  return { lstat: stats, stat: stats, readlink: () => Promise.reject(new Error("EINVAL")) };
}

/** A printed path whose link URI is as long as one may be: Ghostty reads an OSC 8
 *  into a 2048-byte buffer, and the bridge's own cap leaves headroom under it. */
const longPath = (euros: number): string => `src/${"€".repeat(euros)}.ts`;
const longUri = (euros: number): string | undefined =>
  encodePathLink({ path: longPath(euros), base: "r", kind: "f" });

const cases: Case[] = [
  { name: "alternating background gray", data: "\x1b[?1049h\x1b[48;2;55;55;55m\x1b[2J\x1b[Hprompt\r\nrow\r\nrow\r\nrow\r\nrow\r\nstatus\x1b[0m", link: null },
  { name: "alternating background default", data: "\x1b[?1049h\x1b[48;2;55;55;55m\x1b[2J\x1b[Hprompt\r\nrow\r\nrow\x1b[0m\x1b[4;1H\x1b[Jrow\r\nrow\r\nstatus", link: null },
  { name: "alternating background gray again", data: "\x1b[?1049h\x1b[48;2;55;55;55m\x1b[2J\x1b[Hprompt\r\nrow\r\nrow\r\nrow\r\nrow\r\nstatus\x1b[0m", link: null },
  { name: "colored prompt erased to default", data: "\x1b[48;2;55;55;55m\x1b[2J\x1b[5;1H> old prompt\x1b[0m\r\x1b[2K> ", link: null },
  { name: "colored blank row with partial default erase", data: "\x1b[48;2;55;55;55m\x1b[2J\x1b[5;1H> \x1b[0m\x1b[5;20H\x1b[K", link: null },
  { name: "synchronized prompt redraw then idle", data: ["\x1b[?2026h\x1b[48;2;55;55;55m\x1b[2J\x1b[5;1H> old", "\x1b[0m\r\x1b[2K> \x1b[?2026l"], link: null },
  { name: "fullscreen link and color", data: "\x1b[?1049h\x1b[2;3H\x1b]8;;https://example.com/report\x1b\\\x1b[38;2;20;100;200mOpen report\x1b]8;;\x1b\\\x1b[0m\x1b[5;9H", link: { row: 1, col: 2, uri: "https://example.com/report" } },
  { name: "wide Unicode", data: "wide 界 😀 ✅ end\r\nsecond row", link: null },
  { name: "wide hyperlink", data: "\x1b]8;;https://example.com/wide\x1b\\界😀link\x1b]8;;\x1b\\ done", link: { row: 0, col: 0, uri: "https://example.com/wide" } },
  { name: "wrapped rows", data: "x".repeat(79) + "\r\nprompt> ", link: null },
  { name: "combining characters", data: "e\u0301 a\u0308 o\u0302\r\ncombined", link: null },
  { name: "alternate buffer returns to normal", data: "normal\x1b[?1049h\x1b[2Jalternate\x1b[?1049l", link: null },
  { name: "erased hyperlink", data: "\x1b]8;;https://example.com/erased\x1b\\erase me\x1b]8;;\x1b\\\r\x1b[2Kplain", link: { row: 0, col: 0, uri: null } },
  { name: "split escape sequences", data: ["\x1b[38;2;", "80;140;200mcolored\x1b[", "0m\r\n\x1b]8;;https://example.com/split\x1b", "\\split link\x1b]8;;\x1b\\"], link: { row: 1, col: 0, uri: "https://example.com/split" } },
  { name: "detected path link", data: "edit src/a.ts:12 now", link: { row: 0, col: 5, uri: "antgrid-path:?p=src%2Fa.ts&b=r&k=f&n=12" },
    links: { root, statuses: { [resolve(root, "src/a.ts")]: "file" } } },
  { name: "detected url link", data: "see https://example.com/a?b=1#c.", link: { row: 0, col: 4, uri: "antgrid-url:https://example.com/a?b=1#c" },
    links: { root, statuses: {} } },
  { name: "longest accepted link uri", data: longPath(217), link: { row: 0, col: 0, uri: longUri(217)! },
    links: { root, statuses: { [resolve(root, longPath(217))]: "file" } } },
];

/** The URI is 33 + 9N bytes, so 217 fits under the 2000-byte cap and 219 does not. */
if (longUri(217)?.length !== 1986) throw new Error("longest accepted link uri is not the expected 1986 bytes");
if (longUri(219) !== undefined) throw new Error("a 2004-byte link uri was accepted");

async function build(entry: { data: string | string[]; links?: LinkSetup }): Promise<TerminalFrameSource> {
  if (!entry.links) return new TerminalFrameSource(40, 6);
  const cache = new PathStatCache({ fs: fakeFs(entry.links.statuses), isLocalVolume: () => true });
  const source = new TerminalFrameSource(40, 6, undefined, { alternateScreen: true, cache, hostname: "test" });
  source.setLinkRoot(entry.links.root);
  await cache.prefetch(Object.keys(entry.links.statuses), 1000);
  return source;
}
const fixtures = [];
for (const entry of cases) {
  const source = await build(entry);
  try {
    for (const chunk of Array.isArray(entry.data) ? entry.data : [entry.data]) source.feed(chunk);
    await source.settle();
    const buffer = (source as unknown as { term: Terminal }).term.buffer.active;
    fixtures.push({ name: entry.name, frame: source.capture(0),
      lines: source.visibleLines().map((line) => line.trimEnd()), links: entry.link ? [entry.link] : [],
      cursor: { row: buffer.cursorY, col: buffer.cursorX },
      backgrounds: Array.from({ length: 6 }, (_, row) => Array.from({ length: 40 }, (_, col) => {
        const cell = buffer.getLine(buffer.viewportY + row)!.getCell(col)!;
        return cell.isBgRGB() ? cell.getBgColor() : null;
      })) });
  } finally { source.dispose(); }
}

// One mention past the cap must stay unlinked rather than be truncated.
{
  const entry = { data: longPath(219), links: { root, statuses: { [resolve(root, longPath(219))]: "file" as const } } };
  const source = await build(entry);
  try {
    source.feed(entry.data);
    await source.settle();
    if (source.capture(0)?.ansi.includes("antgrid-")) throw new Error("a 2004-byte link uri was emitted");
  } finally { source.dispose(); }
}
console.log(JSON.stringify(fixtures));
