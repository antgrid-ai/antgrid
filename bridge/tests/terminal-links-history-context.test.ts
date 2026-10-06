import { describe, it, expect } from "bun:test";
import type { TerminalHistoryRow } from "../src/terminal-frames/protocol";
import { linkHistoryRows, type HistoryContext } from "../src/terminal-links/history-links";
import { PathStatCache } from "../src/terminal-links/stat-cache";
import { AsyncFs, Clock, pathParams } from "./support/terminal-links-fixtures";

const PLAIN = "\x1b[0m";

type Body = Omit<TerminalHistoryRow, "rowId">;

function body(text: string, cols: number, wrapped = false): Body {
  return { cols, wrapped, spans: [{ text: text.padEnd(cols), cells: cols, sgr: PLAIN }] };
}

function page(first: number, ...bodies: Body[]): TerminalHistoryRow[] {
  return bodies.map((b, i) => ({ ...b, rowId: first + i }));
}

async function link(rows: TerminalHistoryRow[], context: HistoryContext | undefined, files: string[] = []) {
  const fs = new AsyncFs();
  for (const f of files) fs.add(f);
  const clock = new Clock();
  const cache = new PathStatCache({ fs, now: clock.now, timer: clock.timer, platform: "linux" });
  return linkHistoryRows(rows, { checkoutRoot: "/r", spawnCwd: "/r" }, {
    cache, now: clock.now, platform: "linux", budgetMs: 1e9, ...(context ? { context } : {}),
  });
}

const linked = (rows: TerminalHistoryRow[]) =>
  rows.flatMap((r) => r.spans.filter((s) => s.uri !== undefined).map((s) => [r.rowId, s.text, s.uri!] as const));

const NOTHING_AFTER: HistoryContext = { before: [], after: [], afterComplete: false };

describe("a page cut through a soft-wrapped line", () => {
  const cols = 20;
  const head = body("visit https://exampl", cols);
  const tail = body("e.com/path", cols, true);

  it("links the URL's first half to the whole URL when the continuation is context", async () => {
    const out = await link(page(10, head), { before: [], after: [tail], afterComplete: true });

    expect(linked(out)).toEqual([[10, "https://exampl", "antgrid-url:https://example.com/path"]]);
    expect(out).toHaveLength(1);
  });

  it("links the URL's second half to the whole URL when the beginning is context", async () => {
    const out = await link(page(11, tail), { before: [head], after: [], afterComplete: true });

    expect(linked(out)).toEqual([[11, "e.com/path", "antgrid-url:https://example.com/path"]]);
  });

  it("mints nothing for the first half when the continuation is unknown", async () => {
    expect(linked(await link(page(10, head), NOTHING_AFTER))).toEqual([]);
    expect(linked(await link(page(10, head), undefined))).toEqual([]);
  });

  it("mints nothing for a row that continues one it cannot see, even where a file would match", async () => {
    const out = await link(page(11, tail), NOTHING_AFTER, ["/r/e.com/path"]);

    expect(linked(out)).toEqual([]);
  });

  it("sends a split path to the file the whole line names, not to a fragment's", async () => {
    const files = ["/r/packages/app/src/index.ts", "/r/src/index.ts", "/r/packages/app/"];
    const first = body("edit packages/app/", 18);
    const second = body("src/index.ts", 18, true);

    const newer = await link(page(2, second), { before: [first], after: [], afterComplete: true }, files);
    const older = await link(page(1, first), { before: [], after: [second], afterComplete: true }, files);
    const newerBlind = await link(page(2, second), NOTHING_AFTER, files);

    expect(linked(newer).map(([, , uri]) => pathParams(uri).p)).toEqual(["packages/app/src/index.ts"]);
    expect(linked(older).map(([, , uri]) => pathParams(uri).p)).toEqual(["packages/app/src/index.ts"]);
    expect(linked(newerBlind)).toEqual([]);
  });

  it("links a mention that reaches the edge of the final row of the whole output", async () => {
    const out = await link(page(10, head), { before: [], after: [], afterComplete: true });

    expect(linked(out)).toEqual([[10, "https://exampl", "antgrid-url:https://exampl"]]);
  });

  it("never paints or returns the context rows", async () => {
    const out = await link(page(10, head), { before: [body("see https://a.com/b", 40)], after: [tail], afterComplete: true });

    expect(out.map((r) => r.rowId)).toEqual([10]);
    expect(linked(out).map(([row]) => row)).toEqual([10]);
  });

  it("does not let a stored program link in the context count as one of the page's own", async () => {
    const forged: Body = {
      cols,
      wrapped: true,
      spans: [{ text: "e.com/path".padEnd(cols), cells: cols, sgr: PLAIN, uri: "antgrid-url:https://evil.test" }],
    };

    const out = await link(page(10, head), { before: [], after: [forged], afterComplete: true });

    expect(linked(out)).toEqual([[10, "https://exampl", "antgrid-url:https://example.com/path"]]);
  });
});

describe("the budget a page shares with the rows around it", () => {
  const cols = 200;
  const perRow = 14;

  // Three candidate bases per path make a page of this density exceed the
  // lookup budget on its own, so any lookup spent elsewhere costs it a link.
  function dense(rowCount: number, from: number, files: string[]): Body[] {
    const rows: Body[] = [];
    let n = from;
    for (let r = 0; r < rowCount; r++) {
      let text = "";
      for (let k = 0; k < perRow; k++) {
        const p = `d/f${n++}.ts`;
        files.push(`/r/${p}`);
        text += `${p} `;
      }
      rows.push(body(text.trimEnd(), cols));
    }
    return rows;
  }

  async function linkedCount(rows: TerminalHistoryRow[], context: HistoryContext | undefined, files: string[]) {
    const fs = new AsyncFs();
    for (const f of files) fs.add(f);
    const clock = new Clock();
    const cache = new PathStatCache({ fs, now: clock.now, timer: clock.timer, platform: "linux", maxQueued: 100_000, maxEntries: 100_000 });
    const out = await linkHistoryRows(rows, { checkoutRoot: "/r", spawnCwd: "/r/s", liveCwd: "/r/l" }, {
      cache, now: clock.now, platform: "linux", budgetMs: 1e9, ...(context ? { context } : {}),
    });
    return { count: linked(out).length, fs };
  }

  it("links as many of the page's mentions with dense rows after it as with none", async () => {
    const files: string[] = [];
    const rows = page(100, ...dense(200, 0, files));
    const after = dense(48, 100_000, files);

    const alone = await linkedCount(rows, undefined, files);
    const withAfter = await linkedCount(rows, { before: [], after, afterComplete: true }, files);

    expect(alone.count).toBeGreaterThan(0);
    expect(withAfter.count).toBe(alone.count);
  });

  it("never asks the filesystem about a row that only follows the page", async () => {
    const files: string[] = [];
    const rows = page(100, ...dense(2, 0, files));
    const after = dense(4, 100_000, files);

    const { fs } = await linkedCount(rows, { before: [], after, afterComplete: true }, files);

    expect(fs.calls.some((c) => c.includes("/d/f100"))).toBe(false);
  });
});
