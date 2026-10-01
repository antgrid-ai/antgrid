import { describe, it, expect } from "bun:test";
import { win32 } from "node:path";
import {
  detectLinks,
  type DetectBudget,
  type DetectResult,
  type DetectRow,
} from "../src/terminal-links/detector";
import { PathStatCache, type PathStatCacheOptions } from "../src/terminal-links/stat-cache";
import type { LinkBases } from "../src/terminal-links/resolver";
import { AsyncFs, Clock, mkRows, pathParams, settle } from "./support/terminal-links-fixtures";

const ROOT_BASES: LinkBases = { checkoutRoot: "/r", spawnCwd: "/r" };
const liveBudget = (): DetectBudget => ({ lookups: 2048, newStats: 64 });

interface Env {
  fs: AsyncFs;
  clock: Clock;
  cache: PathStatCache;
  platform: NodeJS.Platform;
}

function env(opts: PathStatCacheOptions = {}, platform: NodeJS.Platform = "linux"): Env {
  const fs = new AsyncFs(platform === "win32" ? win32 : undefined);
  const clock = new Clock();
  const cache = new PathStatCache({
    fs,
    now: clock.now,
    timer: clock.timer,
    platform,
    ...(platform === "win32" ? { isLocalVolume: () => true } : {}),
    ...opts,
  });
  return { fs, clock, cache, platform };
}

function detect(
  e: Env,
  rows: DetectRow[],
  bases: LinkBases = ROOT_BASES,
  firstPainted = 0,
  budget: DetectBudget = liveBudget(),
): DetectResult {
  return detectLinks(rows, firstPainted, bases, e.cache, budget, undefined, e.platform);
}

/** What a live source does on a static screen: capture, wait for the stats it
 *  asked for to land, capture again, until nothing is pending. */
async function detectSettled(
  e: Env,
  rows: DetectRow[],
  bases: LinkBases = ROOT_BASES,
  firstPainted = 0,
): Promise<{ result: DetectResult; captures: number }> {
  let result = detect(e, rows, bases, firstPainted);
  let captures = 1;
  while (result.pending.size > 0 && captures < 8) {
    await settle();
    result = detect(e, rows, bases, firstPainted);
    captures++;
  }
  return { result, captures };
}

const span = (r: DetectResult, row: number) => r.spans.filter((s) => s.row === row);

describe("chain progression on a static screen", () => {
  it("links the second candidate once the first settles missing, with no further feed", async () => {
    const e = env();
    e.fs.add("/r/a.ts");
    const rows = mkRows(["see a.ts"], 20);
    const bases = { liveCwd: "/r/sub", spawnCwd: "/r", checkoutRoot: "/r" };

    const first = detect(e, rows, bases);
    expect(first.spans).toEqual([]);
    expect([...first.pending]).toEqual(["/r/sub/a.ts"]);

    const invalidations: string[] = [];
    e.cache.onChange((abs) => invalidations.push(abs));
    const { result, captures } = await detectSettled(e, rows, bases);

    expect(captures).toBeLessThanOrEqual(2);
    expect(result.spans).toHaveLength(1);
    const s = result.spans[0]!;
    expect([s.row, s.startCol, s.endCol]).toEqual([0, 4, 8]);
    expect(pathParams(s.uri)).toEqual({ p: "a.ts", b: "s", k: "f" });
    expect([...result.negatives]).toEqual(["/r/sub/a.ts"]);
    expect([...result.linked]).toEqual(["/r/a.ts"]);
    expect(result.pending.size).toBe(0);
    expect(invalidations.length).toBeGreaterThan(0);
  });

  it("requests every candidate of a mention up front", () => {
    const e = env();
    const rows = mkRows(["see a.ts"], 20);
    detect(e, rows, { liveCwd: "/r/x", spawnCwd: "/r/y", checkoutRoot: "/r" });
    expect(e.cache.request("/r/x/a.ts")).toBe("inflight");
    expect(e.cache.request("/r/y/a.ts")).toBe("inflight");
    expect(e.cache.request("/r/a.ts")).toBe("inflight");
  });

  it("stats every one of 100 unknown mentions, 64 new stats per capture", async () => {
    const e = env();
    e.fs.add("/r/d", "dir");
    const lines = Array.from({ length: 100 }, (_, i) => `see d/f${i}.ts`);
    const rows = mkRows(lines, 30);

    const first = detect(e, rows);
    expect(first.starved).toBe(true);
    expect(first.pending.size).toBeGreaterThan(0);
    const queuedFirst = e.fs.lstats.length;
    await settle();
    expect(e.fs.lstats.some((p) => p === "/r/d/f99.ts")).toBe(true);
    expect(e.fs.lstats.some((p) => p === "/r/d/f0.ts")).toBe(false);
    expect(queuedFirst).toBeLessThanOrEqual(64 * 3);

    const { result } = await detectSettled(e, rows);
    expect(result.pending.size).toBe(0);
    expect(result.spans).toEqual([]);
    for (const i of [0, 35, 36, 63, 64, 65, 99]) {
      expect(e.fs.lstats).toContain(`/r/d/f${i}.ts`);
    }
    expect(result.negatives.size).toBe(100);
  });

  it("spends the budget on the newest rows first", () => {
    const e = env();
    const rows = mkRows(Array.from({ length: 10 }, (_, i) => `see d/f${i}.ts`), 30);
    const r = detect(e, rows, ROOT_BASES, 0, { lookups: 2048, newStats: 3 });
    expect(r.starved).toBe(true);
    expect(e.cache.request("/r/d/f9.ts")).toBe("inflight");
    expect(e.cache.request("/r/d/f8.ts")).toBe("inflight");
    expect(e.cache.request("/r/d/f7.ts")).toBe("inflight");
    expect(e.cache.request("/r/d/f6.ts")).toBe("queued");
  });

  it("does not bill a key that is already in flight against the new-stat budget", () => {
    const e = env();
    const rows = mkRows(["see d/a.ts", "see d/b.ts"], 20);
    detect(e, rows, ROOT_BASES, 0, { lookups: 2048, newStats: 2 });
    const again = detect(e, rows, ROOT_BASES, 0, { lookups: 2048, newStats: 2 });
    expect(again.starved).toBe(false);
  });

  it("flags a dropped request as starved", () => {
    const e = env({ maxQueued: 0 });
    const r = detect(e, mkRows(["see d/a.ts"], 20));
    expect(r.starved).toBe(true);
  });

  it("stops evaluating when the lookup budget is spent", () => {
    const e = env();
    e.fs.add("/r/a.ts");
    const r = detect(e, mkRows(["see a.ts"], 20), ROOT_BASES, 0, { lookups: 0, newStats: 64 });
    expect(r.spans).toEqual([]);
    expect(r.starved).toBe(true);
    expect(e.fs.lstats).toEqual([]);
  });

  it("never mutates the caller's budget", () => {
    const e = env();
    const budget = liveBudget();
    detect(e, mkRows(["see d/a.ts"], 20), ROOT_BASES, 0, budget);
    expect(budget).toEqual(liveBudget());
  });
});

describe("TTL drives re-stats", () => {
  it("re-requests a linked key after the positive TTL, and unlinks when it goes missing", async () => {
    const e = env();
    e.fs.add("/r/a.ts");
    const rows = mkRows(["see a.ts"], 20);
    const { result } = await detectSettled(e, rows);
    expect(result.spans).toHaveLength(1);
    const statsBefore = e.fs.stats.length;

    e.clock.advance(30_001);
    e.fs.remove("/r/a.ts");
    const changes: Array<[string, string]> = [];
    e.cache.onChange((abs, status) => changes.push([abs, status]));

    const stale = detect(e, rows);
    expect(stale.spans).toHaveLength(1);
    await settle();
    expect(changes).toEqual([["/r/a.ts", "missing"]]);
    expect(e.fs.lstats.filter((p) => p === "/r/a.ts").length).toBeGreaterThan(1);
    expect(e.fs.stats.length).toBe(statsBefore);

    const after = detect(e, rows);
    expect(after.spans).toEqual([]);
    expect([...after.negatives]).toEqual(["/r/a.ts"]);
  });

  it("re-requests a negative after its TTL so a file written later links", async () => {
    const e = env();
    const rows = mkRows(["see a.ts"], 20);
    const { result } = await detectSettled(e, rows);
    expect(result.spans).toEqual([]);

    e.fs.add("/r/a.ts");
    e.clock.advance(4_001);
    detect(e, rows);
    await settle();
    expect(detect(e, rows).spans).toHaveLength(1);
  });
});

describe("hard-wrap joins", () => {
  it("joins a path broken mid-name and links both rows", async () => {
    const e = env();
    e.fs.add("/r/bridge/src/agent-core.ts");
    const { result } = await detectSettled(e, mkRows(["see bridge/src/agen", "  t-core.ts done"], 20));
    expect(result.spans).toHaveLength(2);
    expect(result.spans.map((s) => [s.row, s.startCol, s.endCol])).toEqual([
      [0, 4, 19],
      [1, 2, 11],
    ]);
    for (const s of result.spans) expect(pathParams(s.uri).p).toBe("bridge/src/agent-core.ts");
    expect([...result.linked]).toEqual(["/r/bridge/src/agent-core.ts"]);
  });

  it("is punctuation-trimmed: a trailing ';' is not part of the join", async () => {
    const e = env();
    e.fs.add("/r/web/src/ui/devices.tsx");
    const { result } = await detectSettled(e, mkRows(["edit web/src/", "  ui/devices.tsx; done"], 16));
    expect(result.spans.map((s) => [s.row, s.startCol, s.endCol])).toEqual([
      [0, 5, 13],
      [1, 2, 16],
    ]);
    for (const s of result.spans) expect(pathParams(s.uri).p).toBe("web/src/ui/devices.tsx");
  });

  it("falls back to the head alone when the join is not on disk", async () => {
    const e = env({}, "win32");
    e.fs.add("C:\\r\\…\\antgrid-public-c", "dir");
    const bases = { checkoutRoot: "C:\\r", spawnCwd: "C:\\r" };
    const { result } = await detectSettled(e, mkRows(["…\\antgrid-public-c", "      return"], 20), bases);
    expect(result.spans).toHaveLength(1);
    expect(result.spans[0]).toMatchObject({ row: 0, startCol: 0, endCol: 18 });
    expect(pathParams(result.spans[0]!.uri)).toEqual({ p: "…\\antgrid-public-c", b: "s", k: "d" });
  });

  it("never links the parent of a head that stops at a directory separator", async () => {
    const e = env();
    e.fs.add("/r/app/lib", "dir");
    const rows = mkRows(["some words here app/", "lib/missing.dart"], 20);
    const { result } = await detectSettled(e, rows);
    expect(result.spans).toEqual([]);
    expect(e.fs.lstats).toContain("/r/app");
    expect(e.fs.lstats).toContain("/r/app/lib/missing.dart");
  });

  it("links the directory when the next row is an ellipsis", async () => {
    const e = env();
    e.fs.add("/r/app", "dir");
    const { result } = await detectSettled(e, mkRows(["some words here app/", "…"], 20));
    expect(result.spans).toHaveLength(1);
    expect(result.spans[0]).toMatchObject({ row: 0, startCol: 16, endCol: 20 });
    expect(pathParams(result.spans[0]!.uri)).toEqual({ p: "app/", b: "s", k: "d" });
  });

  it("links the next row's own path when the join is unverified", async () => {
    const e = env();
    e.fs.add("/r/app/lib/widgets/session_mode_control.dart");
    const rows = mkRows(["view the changes inside agent_panel.dart", "app/lib/widgets/session_mode_control.dart"], 44);
    const { result } = await detectSettled(e, rows);
    expect(result.spans).toHaveLength(1);
    expect(result.spans[0]).toMatchObject({ row: 1, startCol: 0, endCol: 41 });
    expect(pathParams(result.spans[0]!.uri).p).toBe("app/lib/widgets/session_mode_control.dart");
    expect(e.fs.lstats).toContain("/r/agent_panel.dartapp");
  });

  it("links a head and the next row's path independently when the join is missing", async () => {
    const e = env();
    e.fs.add("/r/agent_panel.dart");
    e.fs.add("/r/app/lib/x.dart");
    const rows = mkRows(["view the changes inside agent_panel.dart", "app/lib/x.dart"], 44);
    const { result } = await detectSettled(e, rows);
    expect(result.spans.map((s) => [s.row, pathParams(s.uri).p])).toEqual([
      [0, "agent_panel.dart"],
      [1, "app/lib/x.dart"],
    ]);
  });

  it("puts a ':42' suffix that sits on the continuation into the link", async () => {
    const e = env();
    e.fs.add("/r/bridge/src/agent-core.ts");
    const { result } = await detectSettled(e, mkRows(["see bridge/src/agent-co", "re.ts:42 ok"], 24));
    expect(result.spans).toHaveLength(2);
    for (const s of result.spans) {
      expect(pathParams(s.uri)).toEqual({ p: "bridge/src/agent-core.ts", b: "s", k: "f", n: 42 });
    }
  });

  it("holds the head back while a longer join is still being checked", () => {
    const e = env();
    e.fs.add("/r/bridge/src/agen");
    const r = detect(e, mkRows(["see bridge/src/agen", "  t-core.ts done"], 20));
    expect(r.spans).toEqual([]);
    expect(r.pending.size).toBeGreaterThan(0);
  });

  it("prefers a verified join over the head that also exists", async () => {
    const e = env();
    e.fs.add("/r/bridge/src/agen", "dir");
    e.fs.add("/r/bridge/src/agent-core.ts");
    const { result } = await detectSettled(e, mkRows(["see bridge/src/agen", "  t-core.ts done"], 20));
    expect(result.spans.map((s) => pathParams(s.uri).p)).toEqual([
      "bridge/src/agent-core.ts",
      "bridge/src/agent-core.ts",
    ]);
  });

  it("joins a path that spans three rows", async () => {
    const e = env();
    e.fs.add("/r/aaaa/bbbb/cccc/ddddd.ts");
    const { result } = await detectSettled(e, mkRows(["see aaaa/bbb", "b/cccc/ddddd", ".ts"], 12));
    expect(result.spans.map((s) => [s.row, s.startCol, s.endCol])).toEqual([
      [0, 4, 12],
      [1, 0, 12],
      [2, 0, 3],
    ]);
    for (const s of result.spans) expect(pathParams(s.uri).p).toBe("aaaa/bbbb/cccc/ddddd.ts");
  });

  it("never joins more than three rows", async () => {
    const e = env();
    e.fs.add("/r/aaaa/bbbb/cccc/dddddeeeeeeeeeeee.ts");
    const rows = mkRows(["see aaaa/bbb", "b/cccc/ddddd", "eeeeeeeeeeee", ".ts"], 12);
    const { result } = await detectSettled(e, rows);
    expect(result.spans).toEqual([]);
  });

  it("links a soft-wrapped path on both rows", async () => {
    const e = env();
    e.fs.add("/r/bridge/src/agent-core.ts");
    const rows = mkRows(["see bridge/src/agent", "-core.ts done"], 20, { wrapped: [1] });
    const { result } = await detectSettled(e, rows);
    expect(result.spans.map((s) => [s.row, s.startCol, s.endCol])).toEqual([
      [0, 4, 20],
      [1, 0, 8],
    ]);
    for (const s of result.spans) expect(pathParams(s.uri).p).toBe("bridge/src/agent-core.ts");
  });

  it("maps a mention after a wide character to its real columns", async () => {
    const e = env();
    e.fs.add("/r/src/a.ts");
    const { result } = await detectSettled(e, mkRows(["界 src/a.ts"], 20));
    expect(result.spans).toHaveLength(1);
    expect([result.spans[0]!.startCol, result.spans[0]!.endCol]).toEqual([3, 11]);
  });

  it("covers a wide character inside the mention with its full width", async () => {
    const e = env();
    e.fs.add("/r/src/界.ts");
    const { result } = await detectSettled(e, mkRows(["see src/界.ts"], 20));
    expect(result.spans).toHaveLength(1);
    expect([result.spans[0]!.startCol, result.spans[0]!.endCol]).toEqual([4, 13]);
  });

  it("does not join a head that is followed by trimmed punctuation", async () => {
    const e = env();
    e.fs.add("/r/bridge/src/agen.");
    e.fs.add("/r/bridge/src/agen.ts");
    const { result } = await detectSettled(e, mkRows(["see bridge/src/agen.", "ts done"], 20));
    expect(result.spans).toEqual([]);
  });

  it("does not join across a row that stops short of the edge", async () => {
    const e = env();
    e.fs.add("/r/bridge/src/agent-core.ts");
    const { result } = await detectSettled(e, mkRows(["see bridge/s", "rc/agent-core.ts"], 20));
    expect(result.spans.every((s) => s.row === 1)).toBe(true);
  });
});

describe("firstPainted", () => {
  it("emits spans and linked keys only for painted rows, but still joins from context", async () => {
    const e = env();
    e.fs.add("/r/a.ts");
    e.fs.add("/r/b.ts");
    const rows = mkRows(["see a.ts", "see b.ts"], 20);
    const { result } = await detectSettled(e, rows, ROOT_BASES, 1);
    expect(result.spans).toHaveLength(1);
    expect(result.spans[0]!.row).toBe(1);
    expect([...result.linked]).toEqual(["/r/b.ts"]);
  });

  it("links a join whose head is in a context row on the painted continuation", async () => {
    const e = env();
    e.fs.add("/r/bridge/src/agent-core.ts");
    const rows = mkRows(["see bridge/src/agen", "  t-core.ts done"], 20);
    const { result } = await detectSettled(e, rows, ROOT_BASES, 1);
    expect(result.spans.map((s) => s.row)).toEqual([1]);
  });
});

describe("explicit links win", () => {
  it("drops a mention that overlaps the program's own link and keeps others", async () => {
    const e = env();
    e.fs.add("/r/a.ts");
    e.fs.add("/r/b.ts");
    const explicit = { 0: { 7: "https://example.com" } };
    const rows = mkRows(["see a.ts and b.ts"], 30, { explicit });
    const { result } = await detectSettled(e, rows);
    expect(result.spans.map((s) => pathParams(s.uri).p)).toEqual(["b.ts"]);
  });

  it("drops a URL that covers an explicit cell", () => {
    const e = env();
    const rows = mkRows(["see https://example.com/a"], 30, { explicit: { 0: { 10: "https://other" } } });
    expect(detect(e, rows).spans).toEqual([]);
  });

  it("drops a join whose continuation overlaps an explicit cell", async () => {
    const e = env();
    e.fs.add("/r/bridge/src/agent-core.ts");
    const rows = mkRows(["see bridge/src/agen", "  t-core.ts done"], 20, { explicit: { 1: { 3: "https://x" } } });
    const { result } = await detectSettled(e, rows);
    expect(result.spans).toEqual([]);
  });
});

describe("URLs", () => {
  const urlOf = (uri: string) => uri.replace(/^antgrid-url:/, "");
  const urlRows = (r: DetectResult, row: number) => span(r, row).map((s) => urlOf(s.uri));

  it("links a bare URL without touching the filesystem", () => {
    const e = env();
    const r = detect(e, mkRows(["see https://example.com/a?b=1#c."], 40));
    expect(r.spans).toHaveLength(1);
    expect(r.spans[0]).toMatchObject({ row: 0, startCol: 4, endCol: 31 });
    expect(urlOf(r.spans[0]!.uri)).toBe("https://example.com/a?b=1#c");
    expect(e.fs.calls).toEqual([]);
  });

  it("rejoins a query string a TUI wrapped onto the next row", () => {
    const rows = mkRows(["  see https://example.com/path/to/page?a", "  =1&b=2#frag", "  done"], 40);
    expect(rows[0]!.endCol).toBe(40);
    const r = detect(env(), rows);
    expect(r.spans.map((s) => [s.row, s.startCol, s.endCol])).toEqual([
      [0, 6, 40],
      [1, 2, 13],
    ]);
    for (const s of r.spans) expect(urlOf(s.uri)).toBe("https://example.com/path/to/page?a=1&b=2#frag");
  });

  it("follows a URL across several full rows", () => {
    const lines = ["https://example.com/aaaaaaaaaaaaaaaaaaaa", "b".repeat(40), "#!/route"];
    const r = detect(env(), mkRows(lines, 40));
    expect(r.spans.map((s) => s.row)).toEqual([0, 1, 2]);
    for (const s of r.spans) expect(urlOf(s.uri)).toBe(`${lines[0]}${lines[1]}#!/route`);
  });

  it("links a URL hard-wrapped over five rows at 40 columns as one", () => {
    const lines = [
      "https://example.com/aaaaaaaaaaaaaaaaaaaa",
      "b".repeat(40),
      "c".repeat(40),
      "d".repeat(40),
      "eee",
    ];
    const r = detect(env(), mkRows(lines, 40));
    expect(r.spans.map((s) => s.row)).toEqual([0, 1, 2, 3, 4]);
    for (const s of r.spans) expect(urlOf(s.uri)).toBe(lines.join(""));
  });

  it("leaves a URL that ends a short row alone", () => {
    const r = detect(env(), mkRows(["open https://example.com/x", "next line of prose"], 40));
    expect(r.spans).toHaveLength(1);
    expect(urlOf(r.spans[0]!.uri)).toBe("https://example.com/x");
  });

  it("does not append a second URL from the next row", () => {
    const lines = ["https://example.com/aaaaaaaaaaaaaaaaaaaa", "https://other.example/"];
    const r = detect(env(), mkRows(lines, 40));
    expect(urlRows(r, 0)).toEqual([lines[0]!]);
    expect(urlRows(r, 1)).toEqual([lines[1]!]);
  });

  it("keeps a closing parenthesis the URL opened, and drops the sentence's own", () => {
    const head = "https://en.example.org/wiki/Foo_(programming_lang";
    const row = `  ${head}`;
    for (const tail of ["uage)", "uage))."]) {
      const r = detect(env(), mkRows([row, tail], row.length));
      expect(r.spans.map((s) => s.row)).toEqual([0, 1]);
      for (const s of r.spans) expect(urlOf(s.uri)).toBe("https://en.example.org/wiki/Foo_(programming_language)");
    }
  });

  it("drops trailing sentence punctuation from the joined URL", () => {
    const r = detect(env(), mkRows(["  https://example.com/path/to/page?query", "=1."], 40));
    for (const s of r.spans) expect(urlOf(s.uri)).toBe("https://example.com/path/to/page?query=1");
    expect(r.spans).toHaveLength(2);
    expect(r.spans[1]).toMatchObject({ startCol: 0, endCol: 2 });
  });

  it("does not link a wrapped URL whose link would pass 2000 bytes", () => {
    const lines = ["https://example.com/" + "a".repeat(20), ...Array.from({ length: 60 }, () => "b".repeat(40))];
    const r = detect(env(), mkRows(lines, 40));
    expect(r.spans).toEqual([]);
  });

  it("does not let a path-looking tail of an unlinked URL link on its own", async () => {
    const e = env();
    e.fs.add("/r/bbbb/c.ts");
    const lines = ["https://example.com/" + "a".repeat(20), ...Array.from({ length: 60 }, () => "b".repeat(40))];
    lines[1] = "bbbb/c.ts" + "b".repeat(31);
    const r = detect(e, mkRows(lines, 40));
    expect(r.spans).toEqual([]);
    expect(e.fs.calls).toEqual([]);
  });

  it("drops a path that overlaps a joined URL's continuation", async () => {
    const e = env();
    e.fs.add("/r/x/y.ts");
    const rows = mkRows(["https://example.com/aaaaaaaaaaaaaaaaaaaa", "x/y.ts"], 40);
    const r = detect(e, rows);
    expect(r.spans.map((s) => s.row)).toEqual([0, 1]);
    for (const s of r.spans) expect(s.uri.startsWith("antgrid-url:")).toBe(true);
    expect(e.fs.calls).toEqual([]);
  });

  it("percent-encodes non-ASCII in the wrapper", () => {
    const r = detect(env(), mkRows(["see https://例え.jp/ä"], 30));
    expect(r.spans).toHaveLength(1);
    expect(r.spans[0]!.uri).toBe("antgrid-url:https://%E4%BE%8B%E3%81%88.jp/%C3%A4");
  });
});

describe("quoted alternatives", () => {
  it("lets an inner unquoted path link when the outer quote is rejected", async () => {
    const e = env();
    e.fs.add("/r/src/a.ts");
    const { result } = await detectSettled(e, mkRows(['"error: src/a.ts"'], 30));
    expect(result.spans).toHaveLength(1);
    expect([result.spans[0]!.startCol, result.spans[0]!.endCol]).toEqual([8, 16]);
    expect(pathParams(result.spans[0]!.uri).p).toBe("src/a.ts");
  });

  it("lets the inner tokens of an accepted quote link when the quote resolves missing", async () => {
    const e = env();
    e.fs.add("/r/src/a.ts");
    const { result } = await detectSettled(e, mkRows(['"run src/a.ts now"'], 30));
    expect(result.spans).toHaveLength(1);
    expect([result.spans[0]!.startCol, result.spans[0]!.endCol]).toEqual([5, 13]);
    expect(pathParams(result.spans[0]!.uri).p).toBe("src/a.ts");
    expect(e.fs.lstats).toContain("/r/run src");
  });

  it("drops the inner tokens when the quote itself is a file", async () => {
    const e = env();
    e.fs.add("/r/run src/a.ts now");
    e.fs.add("/r/src/a.ts");
    const { result } = await detectSettled(e, mkRows(['"run src/a.ts now"'], 30));
    expect(result.spans).toHaveLength(1);
    expect([result.spans[0]!.startCol, result.spans[0]!.endCol]).toEqual([1, 17]);
    expect(pathParams(result.spans[0]!.uri).p).toBe("run src/a.ts now");
  });

  it("links nothing from the inner tokens while the quote is still being checked", () => {
    const e = env();
    e.fs.add("/r/src/a.ts");
    const r = detect(e, mkRows(['"run src/a.ts now"'], 30));
    expect(r.spans).toEqual([]);
    expect(r.pending.size).toBe(2);
  });

  it("keeps a path with a space that only a quote can express", async () => {
    const e = env();
    e.fs.add("/r/docs/My File.md");
    const { result } = await detectSettled(e, mkRows(['open "docs/My File.md" please'], 40));
    expect(result.spans).toHaveLength(1);
    expect(pathParams(result.spans[0]!.uri).p).toBe("docs/My File.md");
  });

  it("emits a path only once when quote styles nest", async () => {
    const e = env();
    e.fs.add("/r/b.ts");
    const { result } = await detectSettled(e, mkRows(['say "go to \'b.ts\' now"'], 40));
    expect(result.spans).toHaveLength(1);
  });

  it("finds an unquoted path inside a JSON stack line", async () => {
    const e = env({}, "win32");
    e.fs.add("C:\\r\\src\\server.ts");
    const line = '{"stack":"at Object.fetch (C:/r/src/server.ts:15:26)\\nat x"}';
    const { result } = await detectSettled(e, mkRows([line], 80), { checkoutRoot: "C:\\r", spawnCwd: "C:\\r" });
    expect(result.spans).toHaveLength(1);
    expect(pathParams(result.spans[0]!.uri)).toEqual({ p: "C:/r/src/server.ts", b: "a", k: "f", n: 15, c: 26 });
  });
});

describe("outside the checkout", () => {
  it("links an outside image and nothing else outside", async () => {
    const e = env();
    e.fs.add("/o/shot.png");
    e.fs.add("/o/notes.ts");
    const { result } = await detectSettled(e, mkRows(["see /o/shot.png and /o/notes.ts"], 40));
    expect(result.spans).toHaveLength(1);
    expect(pathParams(result.spans[0]!.uri)).toEqual({ p: "/o/shot.png", b: "a", k: "i" });
    expect(e.fs.lstats.some((p) => p.includes("notes.ts"))).toBe(false);
  });

  it("does not link an outside directory named like an image", async () => {
    const e = env();
    e.fs.add("/o/shot.png", "dir");
    const { result } = await detectSettled(e, mkRows(["see /o/shot.png"], 40));
    expect(result.spans).toEqual([]);
  });

  it("links a directory inside the root as kind d", async () => {
    const e = env();
    e.fs.add("/r/app/lib", "dir");
    const { result } = await detectSettled(e, mkRows(["ls app/lib"], 30));
    expect(pathParams(result.spans[0]!.uri)).toEqual({ p: "app/lib", b: "s", k: "d" });
  });

  it("carries the line and column of the printed suffix", async () => {
    const e = env();
    e.fs.add("/r/src/a.ts");
    const { result } = await detectSettled(e, mkRows(["src/a.ts:12:5: error"], 30));
    expect(pathParams(result.spans[0]!.uri)).toEqual({ p: "src/a.ts", b: "s", k: "f", n: 12, c: 5 });
  });

  it("tries the diff-prefix-stripped path first and then the printed one", async () => {
    const e = env();
    e.fs.add("/r/b/odd.ts");
    const { result } = await detectSettled(e, mkRows(["+++ b/odd.ts"], 30));
    expect(pathParams(result.spans[0]!.uri).p).toBe("b/odd.ts");
    const e2 = env();
    e2.fs.add("/r/bridge/x.ts");
    const second = await detectSettled(e2, mkRows(["+++ b/bridge/x.ts"], 30));
    expect(pathParams(second.result.spans[0]!.uri).p).toBe("bridge/x.ts");
  });

  it("marks the live cwd as the base that matched", async () => {
    const e = env();
    e.fs.add("/r/web/a.ts");
    const { result } = await detectSettled(e, mkRows(["see a.ts"], 20), {
      checkoutRoot: "/r",
      spawnCwd: "/r",
      liveCwd: "/r/web",
    });
    expect(pathParams(result.spans[0]!.uri).b).toBe("l");
  });
});

describe("failure containment", () => {
  it("returns empty results when the scanner throws", () => {
    const e = env();
    const r = detectLinks(
      mkRows(["see a.ts"], 20),
      0,
      ROOT_BASES,
      e.cache,
      liveBudget(),
      () => {
        throw new Error("boom");
      },
      "linux",
    );
    expect(r).toEqual({
      spans: [],
      pending: new Set(),
      negatives: new Set(),
      linked: new Set(),
      refining: new Set(),
      starved: false,
    });
  });

  it("returns empty results when the cache throws", () => {
    const hostile = {
      peek() {
        throw new Error("peek");
      },
      request() {
        throw new Error("request");
      },
    } as unknown as PathStatCache;
    const r = detectLinks(mkRows(["see a.ts"], 20), 0, ROOT_BASES, hostile, liveBudget(), undefined, "linux");
    expect(r.spans).toEqual([]);
  });

  it("accepts rows with no text", () => {
    const e = env();
    expect(detect(e, mkRows(["", "   ", ""], 10)).spans).toEqual([]);
    expect(detect(e, []).spans).toEqual([]);
  });

  it("makes no filesystem call for a UNC-shaped mention", async () => {
    const e = env({}, "win32");
    const { result } = await detectSettled(e, mkRows(["see \\\\host\\share\\a.png and //h/s/a.png"], 50), {
      checkoutRoot: "C:\\r",
    });
    expect(result.spans).toEqual([]);
    expect(e.fs.calls).toEqual([]);
  });
});

describe("alternatives still waiting on a stat", () => {
  it("lets the next row's own path link while only the head-only reading is pending", async () => {
    const e = env();
    e.fs.add("/r/tools/x.ts");
    e.fs.add("/r/bridge/src", "dir");
    await e.cache.resolveFresh("/r/tools/x.ts", 1000);
    await e.cache.resolveFresh("/r/bridge/src/agentools/x.ts", 1000);
    e.fs.hold("/r/bridge/src/agen");
    const rows = mkRows(["see bridge/src/agen", "tools/x.ts here"], 20);

    const held = detect(e, rows);

    expect(held.pending.has("/r/bridge/src/agen")).toBe(true);
    expect(held.spans.map((s) => [s.row, pathParams(s.uri).p])).toEqual([[1, "tools/x.ts"]]);
    e.fs.release("/r/bridge/src/agen");
    await settle();
  });

  it("holds the head back while a join is pending, although the head itself exists", async () => {
    const e = env();
    e.fs.add("/r/bridge/src/agen", "dir");
    e.fs.add("/r/bridge/src/agent-core.ts");
    await e.cache.resolveFresh("/r/bridge/src/agen", 1000);
    e.fs.hold("/r/bridge/src/agent-core.ts");
    const rows = mkRows(["see bridge/src/agen", "  t-core.ts done"], 20);

    const held = detect(e, rows);
    expect(held.spans).toEqual([]);
    expect(held.pending.has("/r/bridge/src/agent-core.ts")).toBe(true);

    e.fs.release("/r/bridge/src/agent-core.ts");
    await settle();
    const after = detect(e, rows);
    expect(after.spans.map((s) => [s.row, pathParams(s.uri).p])).toEqual([
      [0, "bridge/src/agent-core.ts"],
      [1, "bridge/src/agent-core.ts"],
    ]);
  });

  it("keeps the next row's own path unlinked while a join over it is pending", async () => {
    const e = env();
    e.fs.add("/r/app/lib/widgets/session_mode_control.dart");
    await e.cache.resolveFresh("/r/app/lib/widgets/session_mode_control.dart", 1000);
    await e.cache.resolveFresh("/r/agent_panel.dart", 1000);
    e.fs.hold("/r/agent_panel.dartapp");
    const rows = mkRows(["view the changes inside agent_panel.dart", "app/lib/widgets/session_mode_control.dart"], 44);

    const held = detect(e, rows);
    expect(held.spans).toEqual([]);

    e.fs.release("/r/agent_panel.dartapp");
    await settle();
    const after = detect(e, rows);
    expect(after.spans.map((s) => [s.row, pathParams(s.uri).p])).toEqual([
      [1, "app/lib/widgets/session_mode_control.dart"],
    ]);
  });

  it("links nothing from a quote's inner tokens while the quote is pending, even when they are known", async () => {
    const e = env();
    e.fs.add("/r/src/a.ts");
    await e.cache.resolveFresh("/r/src/a.ts", 1000);
    e.fs.hold("/r/run src");
    const rows = mkRows(['"run src/a.ts now"'], 30);

    const held = detect(e, rows);
    expect(held.spans).toEqual([]);

    e.fs.release("/r/run src");
    await settle();
    const after = detect(e, rows);
    expect(after.spans.map((s) => pathParams(s.uri).p)).toEqual(["src/a.ts"]);
  });
});

describe("a file URL cut by a hard wrap", () => {
  it("joins the decoded path and links both rows", async () => {
    const e = env();
    e.fs.add("/r/src/very/long/path/x.ts");
    const { result } = await detectSettled(e, mkRows(["at file:///r/src/very/long/pa", "th/x.ts done"], 30));

    expect(result.spans.map((s) => s.row)).toEqual([0, 1]);
    for (const s of result.spans) expect(pathParams(s.uri).p).toBe("/r/src/very/long/path/x.ts");
  });

  it("decodes the percent escapes of the whole joined path", async () => {
    const e = env();
    e.fs.add("/r/my docs/x.ts");
    const { result } = await detectSettled(e, mkRows(["at file:///r/my%20", "docs/x.ts done"], 18));

    expect(result.spans.map((s) => s.row)).toEqual([0, 1]);
    for (const s of result.spans) expect(pathParams(s.uri).p).toBe("/r/my docs/x.ts");
  });
});

describe("refreshing known keys", () => {
  it("does not let stale negatives starve an unknown candidate of its request", async () => {
    const e = env();
    e.fs.add("/r/top.ts");
    e.fs.add("/r/m", "dir");
    const rows = mkRows(["see top.ts", ...Array.from({ length: 64 }, (_, i) => `see m/g${i}.ts`)], 30);

    const first = detect(e, rows);
    expect(first.starved).toBe(true);
    await settle();
    expect(e.cache.peek("/r/top.ts")).toBeUndefined();

    // A viewer that was paused while the answers aged out.
    e.clock.advance(5_000);
    detect(e, rows);
    await settle();

    expect(e.cache.peek("/r/top.ts")).toBe("file");
  });
});

describe("a line made of quoted names", () => {
  it("is grouped without comparing every quote to every token", () => {
    const e = env();
    const count = 3000;
    const text = '"a/b" '.repeat(count);
    let reads = 0;
    const entries = Array.from({ length: count }, (_, i) => {
      const at = i * 6 + 1;
      const make = (quoted: boolean) => ({
        get start() { reads++; return at; },
        get end() { reads++; return at + 3; },
        quoted,
        text: { variants: ["a/b"] },
        followedByParen: false,
      });
      return [make(true), make(false)];
    }).flat();

    detectLinks(mkRows([text], text.length), 0, ROOT_BASES, e.cache, { lookups: 8, newStats: 8 },
      () => ({ paths: entries, urls: [] }), e.platform);

    expect(reads).toBeLessThan(count * 40);
  });
});

describe("the edges of the rows given", () => {
  const url = "https://example.com/x";

  it("links a path on a row that continues the one above it only when that row is in view", async () => {
    const e = env();
    e.fs.add("/r/src/index.ts");
    e.fs.add("/r/packages/app/src/index.ts");

    const alone = await detectSettled(e, mkRows(["src/index.ts"], 18, { wrapped: [0] }));
    const whole = await detectSettled(e, mkRows(["edit packages/app/", "src/index.ts"], 18, { wrapped: [1] }), ROOT_BASES, 1);

    expect(alone.result.spans).toEqual([]);
    expect(whole.result.spans.map((s) => pathParams(s.uri).p)).toEqual(["packages/app/src/index.ts"]);
    expect(whole.result.spans.map((s) => s.row)).toEqual([1]);
  });

  it("does not link a URL that runs to the right edge of a last row the caller marks open", () => {
    const e = env();
    const text = `visit ${url.slice(0, 14)}`;
    expect(text.length).toBe(20);

    const closed = detect(e, mkRows([text], 20));
    const open = detectLinks(mkRows([text], 20), 0, ROOT_BASES, e.cache, liveBudget(), undefined, e.platform, { tailOpen: true });

    expect(closed.spans.map((s) => s.uri)).toEqual(["antgrid-url:https://exampl"]);
    expect(open.spans).toEqual([]);
  });

  it("still links an open last row whose mention stops short of the edge", () => {
    const e = env();
    const rows = mkRows([`go ${url}`], 40);

    const result = detectLinks(rows, 0, ROOT_BASES, e.cache, liveBudget(), undefined, e.platform, { tailOpen: true });

    expect(result.spans.map((s) => s.uri)).toEqual([`antgrid-url:${url}`]);
  });

  it("links the painted half of a URL whose first half is context", () => {
    const e = env();
    const rows = mkRows(["visit https://exampl", "e.com/x"], 20, { wrapped: [1] });

    const result = detect(e, rows, ROOT_BASES, 1);

    expect(result.spans.map((s) => [s.row, s.uri])).toEqual([[1, `antgrid-url:${url}`]]);
  });
});

describe("a link out of the checkout through the checkout", () => {
  /** `/r/out` is a symlink to `/outside`, which holds `secret.ts`. */
  class LinkedFs extends AsyncFs {
    private readonly gates = new Map<string, () => void>();
    private readonly shut = new Set<string>();

    constructor() {
      super();
      this.add("/r/keep.ts");
      this.add("/outside/secret.ts");
    }

    shutGate(p: string): void {
      this.shut.add(p);
    }

    openGate(p: string): void {
      this.shut.delete(p);
      this.gates.get(p)?.();
    }

    private async gate(p: string): Promise<void> {
      if (this.shut.has(p)) await new Promise<void>((resolve) => this.gates.set(p, resolve));
    }

    override async stat(p: string) {
      await this.gate(p);
      return super.stat(p);
    }

    override async lstat(p: string) {
      if (p === "/r/out") return { isFile: () => false, isDirectory: () => false, isSymbolicLink: () => true };
      return super.lstat(p);
    }

    override async readlink(p?: string): Promise<string> {
      if (p === "/r/out") return "/outside";
      return super.readlink();
    }
  }

  function linkedEnv(): { fs: LinkedFs; cache: PathStatCache; e: Env } {
    const fs = new LinkedFs();
    const clock = new Clock();
    const cache = new PathStatCache({ fs, now: clock.now, timer: clock.timer, platform: "linux" });
    return { fs, cache, e: { fs, clock, cache, platform: "linux" } };
  }

  it("is not linked once the checkout's own real path is known", async () => {
    const { e } = linkedEnv();
    const rows = mkRows(["see out/secret.ts and keep.ts"], 40);

    const { result } = await detectSettled(e, rows);

    expect(result.spans.map((s) => pathParams(s.uri).p)).toEqual(["keep.ts"]);
  });

  it("is linked lexically until the checkout answers, and names the root as the answer to wait for", async () => {
    const { fs, e } = linkedEnv();
    const rows = mkRows(["see out/secret.ts"], 40);
    fs.shutGate("/r");
    let result = detect(e, rows);
    for (let i = 0; i < 6 && result.pending.size > 0; i++) {
      await settle(10);
      result = detect(e, rows);
    }

    expect(result.spans.map((s) => pathParams(s.uri).p)).toEqual(["out/secret.ts"]);
    expect([...result.refining]).toEqual(["/r"]);

    fs.openGate("/r");
    await settle();
    const after = detect(e, rows);

    expect(after.spans).toEqual([]);
    expect(after.refining.size).toBe(0);
  });

  it("does not name the root for a path the walk reached unchanged", async () => {
    const { e } = linkedEnv();
    const rows = mkRows(["see keep.ts"], 40);

    const { result } = await detectSettled(e, rows);

    expect(result.spans).toHaveLength(1);
    expect(result.refining.size).toBe(0);
  });
});
