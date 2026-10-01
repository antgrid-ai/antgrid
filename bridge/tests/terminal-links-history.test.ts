import { describe, it, expect } from "bun:test";
import {
  TERMINAL_HISTORY_PAGE_BYTES,
  TerminalHistoryRowSchema,
  encodedJsonBytes,
  type TerminalHistoryRow,
  type TerminalHistorySpan,
} from "../src/terminal-frames/protocol";
import { linkHistoryRows } from "../src/terminal-links/history-links";
import { PathStatCache } from "../src/terminal-links/stat-cache";
import type { LinkBases } from "../src/terminal-links/resolver";
import { AsyncFs, Clock, pathParams, settle } from "./support/terminal-links-fixtures";

const PLAIN = "\x1b[0m";
const RED = "\x1b[0;31m";
const BASES: LinkBases = { checkoutRoot: "/r", spawnCwd: "/r" };

function makeCache(fs: AsyncFs, clock: Clock): PathStatCache {
  return new PathStatCache({ fs, now: clock.now, timer: clock.timer, platform: "linux" });
}

function pad(text: string, cols: number): string {
  return text.length >= cols ? text : text + " ".repeat(cols - text.length);
}

function row(rowId: number, text: string, cols: number, opts: { wrapped?: boolean; sgr?: string } = {}): TerminalHistoryRow {
  return {
    rowId,
    cols,
    wrapped: opts.wrapped === true,
    spans: [{ text: pad(text, cols), cells: cols, sgr: opts.sgr ?? PLAIN }],
  };
}

function rowOfSpans(rowId: number, spans: TerminalHistorySpan[], wrapped = false): TerminalHistoryRow {
  return { rowId, cols: spans.reduce((n, s) => n + s.cells, 0), wrapped, spans };
}

const textOf = (r: TerminalHistoryRow) => r.spans.map((s) => s.text).join("");
const cellsOf = (r: TerminalHistoryRow) => r.spans.reduce((n, s) => n + s.cells, 0);
const linkSpans = (r: TerminalHistoryRow) => r.spans.filter((s) => s.uri !== undefined);

async function link(
  rows: TerminalHistoryRow[],
  setup: (fs: AsyncFs) => void = () => {},
  bases: LinkBases = BASES,
) {
  const fs = new AsyncFs();
  setup(fs);
  const clock = new Clock();
  const cache = makeCache(fs, clock);
  const out = await linkHistoryRows(rows, bases, { cache, now: clock.now, platform: "linux" });
  return { out, fs, clock, cache };
}

describe("linkHistoryRows", () => {
  it("splits a span at the link boundaries and keeps its sgr on every piece", async () => {
    const rows = [row(1, "see src/a.ts now", 20, { sgr: RED })];
    const { out } = await link(rows, (fs) => fs.add("/r/src/a.ts"));

    expect(out[0]!.spans.map((s) => [s.text, s.cells, s.uri !== undefined])).toEqual([
      ["see ", 4, false],
      ["src/a.ts", 8, true],
      [" now    ", 8, false],
    ]);
    for (const s of out[0]!.spans) expect(s.sgr).toBe(RED);
    expect(pathParams(linkSpans(out[0]!)[0]!.uri!)).toEqual({ p: "src/a.ts", b: "s", k: "f" });
    expect(textOf(out[0]!)).toBe(textOf(rows[0]!));
    expect(cellsOf(out[0]!)).toBe(20);
  });

  it("links a mention that crosses two differently styled spans", async () => {
    const rows = [
      rowOfSpans(1, [
        { text: "see src/", cells: 8, sgr: PLAIN },
        { text: "a.ts  ", cells: 6, sgr: RED },
      ]),
    ];
    const { out } = await link(rows, (fs) => fs.add("/r/src/a.ts"));
    expect(out[0]!.spans.map((s) => [s.text, s.sgr, s.uri !== undefined])).toEqual([
      ["see ", PLAIN, false],
      ["src/", PLAIN, true],
      ["a.ts", RED, true],
      ["  ", RED, false],
    ]);
    const [a, b] = linkSpans(out[0]!);
    expect(a!.uri).toBe(b!.uri);
  });

  it("leaves explicit program links untouched and does not link inside them", async () => {
    const rows = [
      rowOfSpans(1, [
        { text: "see ", cells: 4, sgr: PLAIN },
        { text: "src/a.ts", cells: 8, sgr: PLAIN, uri: "https://example.com/doc" },
        { text: " and src/b.ts", cells: 13, sgr: PLAIN },
      ]),
    ];
    const { out } = await link(rows, (fs) => {
      fs.add("/r/src/a.ts");
      fs.add("/r/src/b.ts");
    });
    expect(out[0]!.spans[1]).toEqual(rows[0]!.spans[1]!);
    expect(linkSpans(out[0]!).map((s) => s.text)).toEqual(["src/a.ts", "src/b.ts"]);
    expect(linkSpans(out[0]!)[0]!.uri).toBe("https://example.com/doc");
  });

  it("removes a stored program-authored antgrid link and never invents it back", async () => {
    const rows = [
      rowOfSpans(1, [
        { text: "fake", cells: 4, sgr: RED, uri: "antgrid-path:?p=x&b=r&k=f" },
        { text: " x", cells: 2, sgr: RED, uri: "ANTGRID-URL:https://evil" },
        { text: " ok", cells: 3, sgr: PLAIN, uri: "https://example.com" },
      ]),
    ];
    const { out } = await link(rows);
    expect(out[0]!.spans).toEqual([
      { text: "fake", cells: 4, sgr: RED },
      { text: " x", cells: 2, sgr: RED },
      { text: " ok", cells: 3, sgr: PLAIN, uri: "https://example.com" },
    ]);
    expect("uri" in out[0]!.spans[0]!).toBe(false);
  });

  it("strips program-authored links even when there is nothing to detect", async () => {
    const rows = [rowOfSpans(1, [{ text: "x", cells: 1, sgr: PLAIN, uri: "antgrid-url:https://e.com" }])];
    const out = await linkHistoryRows(rows, {}, { platform: "linux" });
    expect(out[0]!.spans[0]!.uri).toBeUndefined();
  });

  it("links a path joined across two rows inside the page", async () => {
    const rows = [row(1, "see bridge/src/agen", 20), row(2, "  t-core.ts done", 20)];
    const { out } = await link(rows, (fs) => fs.add("/r/bridge/src/agent-core.ts"));
    expect(linkSpans(out[0]!).map((s) => s.text)).toEqual(["bridge/src/agen"]);
    expect(linkSpans(out[1]!).map((s) => s.text)).toEqual(["t-core.ts"]);
    for (const r of out) expect(pathParams(linkSpans(r)[0]!.uri!).p).toBe("bridge/src/agent-core.ts");
  });

  it("links a soft-wrapped path on both rows", async () => {
    const rows = [row(1, "see bridge/src/agent", 20), row(2, "-core.ts done", 20, { wrapped: true })];
    const { out } = await link(rows, (fs) => fs.add("/r/bridge/src/agent-core.ts"));
    expect(linkSpans(out[0]!).map((s) => s.text)).toEqual(["bridge/src/agent"]);
    expect(linkSpans(out[1]!).map((s) => s.text)).toEqual(["-core.ts"]);
  });

  it("does not join across the end of the page", async () => {
    const page = [row(1, "see bridge/src/agen", 20)];
    const { out } = await link(page, (fs) => {
      fs.add("/r/bridge/src/agent-core.ts");
      fs.add("/r/bridge/src/agen");
    });
    expect(linkSpans(out[0]!).map((s) => s.text)).toEqual(["bridge/src/agen"]);
    expect(pathParams(linkSpans(out[0]!)[0]!.uri!).p).toBe("bridge/src/agen");
  });

  it("links a URL, wrapped or not, without a filesystem", async () => {
    const rows = [row(1, "  see https://example.com/path/to/page?a", 40), row(2, "  =1&b=2#frag", 40)];
    const { out, fs } = await link(rows);
    expect(linkSpans(out[0]!).map((s) => s.uri)).toEqual(["antgrid-url:https://example.com/path/to/page?a=1&b=2#frag"]);
    expect(linkSpans(out[1]!).map((s) => s.text)).toEqual(["=1&b=2#frag"]);
    expect(fs.calls).toEqual([]);
  });

  it("never links inside a span whose code points differ from its cells", async () => {
    const rows = [rowOfSpans(1, [{ text: "界 src/a.ts", cells: 11, sgr: PLAIN }])];
    const { out } = await link(rows, (fs) => fs.add("/r/src/a.ts"));
    expect(out[0]).toEqual(rows[0]!);
  });

  it("links the mapped spans around a wide-character span", async () => {
    const rows = [
      rowOfSpans(1, [
        { text: "界", cells: 2, sgr: RED },
        { text: " src/a.ts", cells: 9, sgr: PLAIN },
      ]),
    ];
    const { out } = await link(rows, (fs) => fs.add("/r/src/a.ts"));
    expect(out[0]!.spans.map((s) => [s.text, s.cells, s.uri !== undefined])).toEqual([
      ["界", 2, false],
      [" ", 1, false],
      ["src/a.ts", 8, true],
    ]);
  });

  it("links on the second candidate when the first is missing, within the budget", async () => {
    const rows = [row(1, "see a.ts", 20)];
    const { out } = await link(
      rows,
      (fs) => fs.add("/r/a.ts"),
      { checkoutRoot: "/r", liveCwd: "/r/sub", spawnCwd: "/r/sub2" },
    );
    expect(pathParams(linkSpans(out[0]!)[0]!.uri!)).toEqual({ p: "a.ts", b: "r", k: "f" });
  });

  it("serves a page unlinked when a stat is slower than the budget", async () => {
    const fs = new AsyncFs();
    fs.add("/r/src/a.ts");
    fs.hold("/r/src/a.ts");
    const clock = new Clock();
    const cache = makeCache(fs, clock);
    const rows = [row(1, "see src/a.ts now", 20)];

    const pending = linkHistoryRows(rows, BASES, { cache, now: clock.now, budgetMs: 150, platform: "linux" });
    await settle();
    clock.advance(150);
    const out = await pending;

    expect(linkSpans(out[0]!)).toEqual([]);
    expect(out[0]).toEqual(rows[0]!);
    fs.release("/r/src/a.ts");
    await settle();
    expect(cache.peek("/r/src/a.ts")).toBe("file");
  });

  it("links a later pass's result once the stat has landed within the budget", async () => {
    const fs = new AsyncFs();
    fs.add("/r/src/a.ts");
    const clock = new Clock();
    const cache = makeCache(fs, clock);
    const rows = [row(1, "see src/a.ts now", 20)];
    const out = await linkHistoryRows(rows, BASES, { cache, now: clock.now, platform: "linux" });
    expect(linkSpans(out[0]!)).toHaveLength(1);
  });

  it("does not link outside the checkout: no root means no relative candidates", async () => {
    const { out, fs } = await link([row(1, "see src/a.ts", 20)], (f) => f.add("/r/src/a.ts"), {});
    expect(linkSpans(out[0]!)).toEqual([]);
    expect(fs.calls).toEqual([]);
  });

  it("keeps every row valid against the history row schema", async () => {
    const rows = [
      row(1, "see bridge/src/agen", 20, { sgr: RED }),
      row(2, "  t-core.ts done https://example.com/x", 40),
      rowOfSpans(3, [
        { text: "x", cells: 1, sgr: PLAIN, uri: "antgrid-path:?p=x&b=r&k=f" },
        { text: "界 src/b.ts", cells: 11, sgr: PLAIN },
      ]),
    ];
    const { out } = await link(rows, (fs) => {
      fs.add("/r/bridge/src/agent-core.ts");
      fs.add("/r/src/b.ts");
    });
    for (const r of out) expect(() => TerminalHistoryRowSchema.parse(r)).not.toThrow();
    for (const r of out) for (const s of r.spans) if (s.uri) expect(s.uri).toMatch(/^[\x21-\x7e]+$/);
  });

  it("never mutates its input", async () => {
    const rows = [
      row(1, "see src/a.ts https://example.com/x", 40, { sgr: RED }),
      rowOfSpans(2, [{ text: "fake", cells: 4, sgr: PLAIN, uri: "antgrid-path:?p=x&b=r&k=f" }]),
    ];
    const before = JSON.stringify(rows);
    const { out } = await link(rows, (fs) => fs.add("/r/src/a.ts"));
    expect(JSON.stringify(rows)).toBe(before);
    expect(out[0]).not.toBe(rows[0]);
    expect(out[0]!.spans).not.toBe(rows[0]!.spans);
    expect(out).not.toBe(rows);
  });

  it("stops adding links once the page would pass its byte cap", async () => {
    const cols = 1000;
    const cap = TERMINAL_HISTORY_PAGE_BYTES - 1024;
    const rows: TerminalHistoryRow[] = [];
    const mention = (i: number) => `see src/a.ts ${"x".repeat(cols - 20)}`.padEnd(cols, "y").slice(0, cols - (i % 1));
    while (encodedJsonBytes(rows) < cap - 700) rows.push(row(rows.length + 1, mention(0), cols));
    const startBytes = encodedJsonBytes(rows);
    expect(startBytes).toBeLessThanOrEqual(cap);

    const { out } = await link(rows, (fs) => fs.add("/r/src/a.ts"));
    const linked = out.map((r) => linkSpans(r).length > 0);
    const count = linked.filter(Boolean).length;
    expect(count).toBeGreaterThan(0);
    expect(count).toBeLessThan(rows.length);
    expect(encodedJsonBytes(out)).toBeLessThanOrEqual(cap);
    // Links are added in row order, so what is missing is the tail.
    expect(linked.indexOf(false)).toBe(count);
    expect(linked.slice(count).every((l) => !l)).toBe(true);
  });

  it("keeps a row of nearly one-cell spans inside the schema's span and column bounds", async () => {
    const spans: TerminalHistorySpan[] = [];
    for (let i = 0; i < 988; i++) spans.push({ text: "a", cells: 1, sgr: i % 2 ? PLAIN : RED });
    spans.push({ text: " src/a.ts ", cells: 10, sgr: PLAIN });
    const { out } = await link([rowOfSpans(1, spans)], (fs) => fs.add("/r/src/a.ts"));
    expect(out[0]!.spans).toHaveLength(991);
    expect(linkSpans(out[0]!)).toHaveLength(1);
    expect(() => TerminalHistoryRowSchema.parse(out[0])).not.toThrow();
  });

  it("never rejects: a failing cache still serves the page, stripped", async () => {
    const hostile = {
      peek() {
        throw new Error("peek");
      },
      request() {
        throw new Error("request");
      },
      prefetch() {
        return Promise.reject(new Error("prefetch"));
      },
    } as unknown as PathStatCache;
    const rows = [
      rowOfSpans(1, [
        { text: "see src/a.ts ", cells: 13, sgr: PLAIN },
        { text: "x", cells: 1, sgr: PLAIN, uri: "antgrid-path:?p=x&b=r&k=f" },
      ]),
    ];
    const out = await linkHistoryRows(rows, BASES, { cache: hostile, platform: "linux" });
    expect(out).toHaveLength(1);
    expect(linkSpans(out[0]!)).toEqual([]);
  });

  it("leaves pages without a mention exactly as they were", async () => {
    const rows = [row(1, "nothing to see here", 30), row(2, "", 30)];
    const { out } = await link(rows);
    expect(out).toEqual(rows);
  });

  it("links a directory and an outside image with their own kinds", async () => {
    const rows = [row(1, "ls app/lib", 20), row(2, "img /o/a.png", 20)];
    const { out } = await link(rows, (fs) => {
      fs.add("/r/app/lib", "dir");
      fs.add("/o/a.png");
    });
    expect(pathParams(linkSpans(out[0]!)[0]!.uri!).k).toBe("d");
    expect(pathParams(linkSpans(out[1]!)[0]!.uri!)).toEqual({ p: "/o/a.png", b: "a", k: "i" });
  });
});

describe("linkHistoryRows passes", () => {
  it("does not wait on stats after the last pass, whose answers nothing reads", async () => {
    const fs = new AsyncFs();
    fs.add("/r/src/a.ts");
    const clock = new Clock();
    const cache = makeCache(fs, clock);
    let waits = 0;
    // Answers nothing, so every pass is left with the same stat to wait for.
    cache.prefetch = async () => {
      waits++;
    };

    const out = await linkHistoryRows([row(1, "see src/a.ts", 20)], BASES, {
      cache, now: clock.now, platform: "linux",
    });

    expect(linkSpans(out[0]!)).toEqual([]);
    expect(waits).toBe(3);
  });

  it("trusts the volume of the checkout root before it stats anything", async () => {
    const fs = new AsyncFs();
    const clock = new Clock();
    const cache = makeCache(fs, clock);
    const trusted: string[] = [];
    const trust = cache.trustVolume.bind(cache);
    cache.trustVolume = (root) => {
      trusted.push(root);
      trust(root);
    };

    await linkHistoryRows([row(1, "see src/a.ts", 20)], BASES, { cache, now: clock.now, platform: "linux" });

    expect(trusted).toEqual(["/r"]);
    expect(fs.calls.length).toBeGreaterThan(0);
  });
});
