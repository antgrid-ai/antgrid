import { afterEach, describe, expect, test } from "bun:test";
import { TerminalFrameSource, type TerminalLinkOptions } from "../src/terminal-frames/source";
import { encodedJsonBytes } from "../src/terminal-frames/protocol";
import { PathStatCache, type PathStatCacheOptions } from "../src/terminal-links/stat-cache";
import { AsyncFs, Clock, pathParams, settle } from "./support/terminal-links-fixtures";

const sources: TerminalFrameSource[] = [];
afterEach(() => {
  for (const s of sources.splice(0)) s.dispose();
});

/** A timer wheel that never fires on its own, so a test decides when the
 *  source's debounced recheck runs and can count how many are live. */
class ManualTimers {
  private readonly all: Array<{ fn: () => void; ms: number; live: boolean }> = [];
  timer = (fn: () => void, ms: number): { cancel(): void } => {
    const t = { fn, ms, live: true };
    this.all.push(t);
    return { cancel: () => void (t.live = false) };
  };
  get live(): Array<{ fn: () => void; ms: number; live: boolean }> {
    return this.all.filter((t) => t.live);
  }
}

interface Rig {
  source: TerminalFrameSource;
  fs: AsyncFs;
  clock: Clock;
  cache: PathStatCache;
  timers: ManualTimers;
  links: TerminalLinkOptions;
  requested: string[];
  /** Cache listeners currently attached, so a test can see a source let go. */
  subscriptions: { change: number; drain: number };
}

function rig(
  opts: { cache?: PathStatCacheOptions; links?: Partial<TerminalLinkOptions>; cols?: number; rows?: number } = {},
): Rig {
  const fs = new AsyncFs();
  const clock = new Clock();
  const timers = new ManualTimers();
  const cache = new PathStatCache({ fs, now: clock.now, timer: clock.timer, platform: "linux", ...opts.cache });
  const requested: string[] = [];
  const request = cache.request.bind(cache);
  cache.request = (abs) => {
    requested.push(abs);
    return request(abs);
  };
  const subscriptions = { change: 0, drain: 0 };
  const onChange = cache.onChange.bind(cache);
  const onDrain = cache.onDrain.bind(cache);
  cache.onChange = (listener) => {
    subscriptions.change++;
    const detach = onChange(listener);
    return () => {
      subscriptions.change--;
      detach();
    };
  };
  cache.onDrain = (listener) => {
    subscriptions.drain++;
    const detach = onDrain(listener);
    return () => {
      subscriptions.drain--;
      detach();
    };
  };
  const links: TerminalLinkOptions = {
    alternateScreen: true, cache, hostname: "test", timer: timers.timer, platform: "linux", ...opts.links,
  };
  const source = new TerminalFrameSource(opts.cols ?? 40, opts.rows ?? 6, undefined, links);
  source.setLinkRoot("/r");
  sources.push(source);
  return { source, fs, clock, cache, timers, links, requested, subscriptions };
}

async function feed(source: TerminalFrameSource, data: string): Promise<void> {
  source.feed(data);
  await source.settle();
}

/** What a viewer's attachment does: capture, let the stats it asked for land,
 *  capture again. */
async function frameAfterStats(r: Rig): Promise<string> {
  r.source.capture(0);
  await settle();
  const frame = r.source.capture(0);
  expect(frame).not.toBeNull();
  return frame!.ansi;
}

function linksIn(ansi: string): Array<{ row: number; col: number; uri: string }> {
  const found: Array<{ row: number; col: number; uri: string }> = [];
  for (const m of ansi.matchAll(/\x1b\[(\d+);(\d+)H\x1b\]8;;([^\x1b]*)\x1b\\/g)) {
    found.push({ row: Number(m[1]) - 1, col: Number(m[2]) - 1, uri: m[3]! });
  }
  return found;
}

function term(source: TerminalFrameSource): import("@xterm/headless").Terminal {
  return (source as unknown as { term: import("@xterm/headless").Terminal }).term;
}

test("a detected link appears at its column with no underline from the bridge, and the cell's own colour survives", async () => {
  const r = rig();
  r.fs.add("/r/src/a.ts");
  await feed(r.source, "edit \x1b[31msrc/a.ts\x1b[0m now");

  const ansi = await frameAfterStats(r);

  expect(linksIn(ansi)).toEqual([{ row: 0, col: 5, uri: "antgrid-path:?p=src%2Fa.ts&b=r&k=f" }]);
  const afterOpen = ansi.slice(ansi.indexOf("\x1b]8;;antgrid-path:"));
  const styled = afterOpen.slice(0, afterOpen.indexOf("src/a.ts") + 1);
  expect(styled).toContain("38;5;1");
  expect(styled).not.toMatch(/\x1b\[[0-9;:]*4:\d/);
});

test("a printed URL links without touching the filesystem", async () => {
  const r = rig();
  await feed(r.source, "see https://example.com/a?b=1#c.");

  const ansi = r.source.capture(0)!.ansi;

  expect(linksIn(ansi)).toEqual([{ row: 0, col: 4, uri: "antgrid-url:https://example.com/a?b=1#c" }]);
  expect(r.fs.calls).toEqual([]);
});

test("an explicit link wins over a mention that overlaps it", async () => {
  const r = rig();
  r.fs.add("/r/src/a.ts");
  await feed(r.source, "\x1b]8;;https://example.com/own\x1b\\src/a.ts\x1b]8;;\x1b\\ and src/a.ts");

  const ansi = await frameAfterStats(r);

  expect(linksIn(ansi).map((l) => l.uri)).toEqual([
    "https://example.com/own",
    "antgrid-path:?p=src%2Fa.ts&b=r&k=f",
  ]);
  expect(linksIn(ansi)[1]!.col).toBe(13);
});

test("program-authored antgrid links reach no output, and the adapter drops them", async () => {
  const r = rig();
  await feed(r.source,
    "\x1b]8;;antgrid-path:?p=x&b=r&k=f\x1b\\one\x1b]8;;\x1b\\ \x1b]8;;ANTGRID-URL:https://evil.test\x1b\\two\x1b]8;;\x1b\\");

  const ansi = r.source.capture(0)!.ansi;
  const buffer = term(r.source).buffer.active;
  const adapter = (r.source as unknown as { adapter: { link(cell: unknown): string | undefined } }).adapter;

  expect(ansi.toLowerCase()).not.toContain("antgrid-");
  expect(adapter.link(buffer.getLine(0)!.getCell(0)!)).toBeUndefined();
  expect(adapter.link(buffer.getLine(0)!.getCell(4)!)).toBeUndefined();
});

describe("static screen reframe", () => {
  test("an unknown key turning file bumps the revision once and calls the listener once", async () => {
    const r = rig();
    r.fs.add("/r/src/a.ts");
    await feed(r.source, "see src/a.ts");
    let calls = 0;
    r.source.onParsed(() => { calls++; });

    r.source.capture(0);
    const before = r.source.revision;
    await settle();

    expect(r.source.revision).toBe(before + 1);
    expect(calls).toBe(1);
    expect(linksIn(r.source.capture(0)!.ansi)).toHaveLength(1);
  });

  test("a key the screen did not wait on changes nothing", async () => {
    const r = rig();
    r.fs.add("/r/src/a.ts");
    r.fs.add("/r/other.ts");
    await feed(r.source, "see src/a.ts");
    await frameAfterStats(r);
    let calls = 0;
    r.source.onParsed(() => { calls++; });
    const before = r.source.revision;

    r.cache.request("/r/other.ts");
    await settle();

    expect(r.source.revision).toBe(before);
    expect(calls).toBe(0);
  });

  test("a re-stat with the same answer changes nothing", async () => {
    const r = rig();
    r.fs.add("/r/src/a.ts");
    await feed(r.source, "see src/a.ts");
    await frameAfterStats(r);
    const before = r.source.revision;

    r.clock.advance(31_000);
    r.cache.request("/r/src/a.ts");
    await settle();

    expect(r.source.revision).toBe(before);
  });

  test("a linked key that disappears re-frames the screen without the link", async () => {
    const r = rig();
    r.fs.add("/r/src/a.ts");
    await feed(r.source, "see src/a.ts");
    await frameAfterStats(r);
    const before = r.source.revision;

    r.fs.remove("/r/src/a.ts");
    r.clock.advance(31_000);
    r.cache.request("/r/src/a.ts");
    await settle();

    expect(r.source.revision).toBe(before + 1);
    expect(linksIn(r.source.capture(0)!.ansi)).toEqual([]);
  });

  test("a candidate chain progresses to the second base with no further output", async () => {
    const r = rig();
    r.fs.add("/r/a.ts");
    await feed(r.source, "\x1b]7;file:///r/sub\x07see a.ts");
    let calls = 0;
    let last: string | undefined;
    // A viewer re-captures whenever the screen announces a new revision, and
    // nothing else ever touches this screen.
    r.source.onParsed(() => {
      calls++;
      last = r.source.capture(0)?.ansi;
    });

    r.source.capture(0);
    await settle();

    expect(r.source.linkBases().liveCwd).toBe("/r/sub");
    expect(calls).toBeGreaterThan(0);
    expect(calls).toBeLessThanOrEqual(3);
    expect(linksIn(last!).map((l) => l.uri)).toEqual(["antgrid-path:?p=a.ts&b=r&k=f"]);
  });

  test("two keys the screen waited on settling together cost one re-frame", async () => {
    const r = rig();
    r.fs.add("/r/src/a.ts");
    r.fs.add("/r/src/b.ts");
    await feed(r.source, "see src/a.ts src/b.ts");
    r.source.capture(0);
    const before = r.source.revision;
    let calls = 0;
    r.source.onParsed(() => { calls++; });

    const commit = (r.cache as unknown as { commit(key: string, status: string): void }).commit.bind(r.cache);
    commit("/r/src/a.ts", "file");
    commit("/r/src/b.ts", "file");
    await Promise.resolve();
    await Promise.resolve();
    await settle();

    expect(r.source.revision).toBe(before + 1);
    expect(calls).toBe(1);
  });

  test("a drain after a capture that was not starved changes nothing", async () => {
    const r = rig();
    await feed(r.source, "see src/a.ts");
    r.source.capture(0);
    await settle();
    r.source.capture(0);
    const before = r.source.revision;

    for (const drained of (r.cache as unknown as { drainListeners: Set<() => void> }).drainListeners) drained();
    await settle();

    expect(r.source.revision).toBe(before);
  });

  test("a root set after the screen was framed re-frames it with the root", async () => {
    const r = rig();
    r.fs.add("/r/src/a.ts");
    const late = new TerminalFrameSource(40, 6, undefined, r.links);
    sources.push(late);
    await feed(late, "see src/a.ts");
    expect(linksIn(late.capture(0)!.ansi)).toEqual([]);
    const before = late.revision;
    let calls = 0;
    late.onParsed(() => { calls++; });

    late.setLinkRoot("/r");
    late.setLinkRoot("/r");
    await settle();

    expect(late.revision).toBe(before + 1);
    expect(calls).toBe(1);
    late.capture(0);
    await settle();
    expect(linksIn(late.capture(0)!.ansi).map((l) => pathParams(l.uri).p)).toEqual(["src/a.ts"]);
  });

  test("a root set before any capture costs no extra frame", async () => {
    const r = rig();
    const fresh = new TerminalFrameSource(40, 6, undefined, r.links);
    sources.push(fresh);
    await feed(fresh, "see src/a.ts");
    const before = fresh.revision;

    fresh.setLinkRoot("/r");
    await settle();

    expect(fresh.revision).toBe(before);
  });

  test("the scan memo drops its least recently used line, not everything", async () => {
    const ESC = String.fromCharCode(27);
    const r = rig({ rows: 301 });
    const rows = (tag: string) =>
      Array.from({ length: 300 }, (_, i) => `${ESC}[${i + 2};1H${tag} line ${i} src/a.ts`).join("");
    await feed(r.source, `${ESC}[1;1Hhot src/a.ts` + rows("first"));
    r.source.capture(0);
    await feed(r.source, rows("second"));
    r.source.capture(0);

    const memo = (r.source as unknown as { link: { scanMemo: Map<string, unknown> } }).link.scanMemo;
    expect([...memo.keys()].some((k) => k.startsWith("hot src/a.ts"))).toBe(true);
    expect([...memo.keys()].some((k) => k.startsWith("second line 299"))).toBe(true);
    expect(memo.size).toBeLessThanOrEqual(512);
  });
});

describe("negative recheck", () => {
  test("many captures leave one live timer, which re-requests the negatives once", async () => {
    const r = rig();
    await feed(r.source, "see src/a.ts");
    r.source.capture(0);
    await settle();
    for (let i = 0; i < 10; i++) r.source.capture(i);

    expect(r.timers.live).toHaveLength(1);
    expect(r.timers.live[0]!.ms).toBe(5000);

    r.clock.advance(5000);
    r.requested.length = 0;
    const timer = r.timers.live[0]!;
    timer.fn();
    timer.fn();

    expect(r.requested).toEqual(["/r/src/a.ts"]);
  });

  test("a changed revision cancels the recheck's work", async () => {
    const r = rig();
    await feed(r.source, "see src/a.ts");
    r.source.capture(0);
    await settle();
    r.source.capture(0);
    const timer = r.timers.live[0]!;

    await feed(r.source, " more");
    r.clock.advance(5000);
    r.requested.length = 0;
    timer.fn();

    expect(r.requested).toEqual([]);
  });

  test("a file that appears while nothing else happens is picked up by the recheck", async () => {
    const r = rig();
    await feed(r.source, "see src/a.ts");
    r.source.capture(0);
    await settle();
    r.source.capture(0);
    const before = r.source.revision;

    r.fs.add("/r/src/a.ts");
    r.clock.advance(5000);
    r.timers.live[0]!.fn();
    await settle();

    expect(r.source.revision).toBe(before + 1);
    expect(linksIn(r.source.capture(0)!.ansi)).toHaveLength(1);
  });

  test("dispose cancels the timer and stops listening to the cache", async () => {
    const r = rig();
    await feed(r.source, "see src/a.ts");
    r.source.capture(0);
    await settle();
    r.source.capture(0);
    expect(r.timers.live).toHaveLength(1);

    expect(r.subscriptions).toEqual({ change: 1, drain: 1 });
    r.source.dispose();
    const before = r.source.revision;
    r.fs.add("/r/src/a.ts");
    r.clock.advance(5000);
    r.cache.request("/r/src/a.ts");
    await settle();

    expect(r.timers.live).toHaveLength(0);
    expect(r.subscriptions).toEqual({ change: 0, drain: 0 });
    expect(r.source.revision).toBe(before);
  });
});

test("a drain after a dropped request re-frames a starved screen", async () => {
  const r = rig({ cache: { maxQueued: 0 } });
  r.fs.add("/r/src/a.ts");
  r.fs.add("/r/src/c.ts");
  await r.cache.resolveFresh("/r/src/a.ts", 1000);
  await feed(r.source, "src/a.ts src/c.ts");
  r.source.capture(0);
  const before = r.source.revision;
  let calls = 0;
  r.source.onParsed(() => { calls++; });

  await r.cache.resolveFresh("/r/unrelated", 1000);

  expect(r.source.revision).toBe(before + 1);
  expect(calls).toBe(1);
});

describe("alternate screen", () => {
  test("is not scanned unless the terminal opted in", async () => {
    const r = rig({ links: { alternateScreen: false } });
    r.fs.add("/r/src/a.ts");
    await feed(r.source, "\x1b[?1049h\x1b[2Jsee src/a.ts");

    const ansi = await frameAfterStats(r);

    expect(ansi).not.toContain("antgrid-");
  });

  test("is scanned for an agent terminal", async () => {
    const r = rig({ links: { alternateScreen: true } });
    r.fs.add("/r/src/a.ts");
    await feed(r.source, "\x1b[?1049h\x1b[2Jsee src/a.ts");

    const ansi = await frameAfterStats(r);

    expect(linksIn(ansi)).toHaveLength(1);
  });

  test("the normal buffer is scanned either way", async () => {
    const r = rig({ links: { alternateScreen: false } });
    r.fs.add("/r/src/a.ts");
    await feed(r.source, "see src/a.ts");

    expect(linksIn(await frameAfterStats(r))).toHaveLength(1);
  });
});

test("a path whose head scrolled above the viewport still links from the rows below it", async () => {
  const r = rig({ cols: 10, rows: 3 });
  r.fs.add("/r/src/abcdef/g.ts");
  await feed(r.source, "src/abcdef/g.ts\r\nx\r\ny");

  const ansi = await frameAfterStats(r);

  expect(term(r.source).buffer.active.baseY).toBeGreaterThan(0);
  expect(linksIn(ansi)).toEqual([{ row: 0, col: 0, uri: "antgrid-path:?p=src%2Fabcdef%2Fg.ts&b=r&k=f" }]);
});

test("a cache that throws on lookup gives an explicit-only frame and never fails the run", async () => {
  const r = rig();
  r.cache.peek = () => { throw new Error("boom"); };
  await feed(r.source, "see src/a.ts \x1b]8;;https://example.com/x\x1b\\own\x1b]8;;\x1b\\");

  const frame = r.source.capture(0);

  expect(frame).not.toBeNull();
  expect(linksIn(frame!.ansi).map((l) => l.uri)).toEqual(["https://example.com/x"]);
  expect(r.source.failure).toBeUndefined();
});

describe("frame size", () => {
  const data = "a https://example.com/one https://example.com/two https://example.com/three";

  test("falls back to the program's own links when only that fits", async () => {
    const r = rig();
    await feed(r.source, data);
    const withLinks = encodedJsonBytes(r.source.capture(0)!.ansi);
    const without = encodedJsonBytes(r.source.capture(0, { detectedLinks: false })!.ansi);
    expect(without).toBeLessThan(withLinks);

    r.links.frameBudgetBytes = withLinks - 1;
    const frame = r.source.capture(0);

    expect(frame).not.toBeNull();
    expect(frame!.ansi).not.toContain("antgrid-");
    expect(r.source.oversize).toBe(false);
  });

  test("reports oversize when it fits neither way", async () => {
    const r = rig();
    await feed(r.source, data);
    const without = encodedJsonBytes(r.source.capture(0, { detectedLinks: false })!.ansi);

    r.links.frameBudgetBytes = without - 1;

    expect(r.source.capture(0)).toBeNull();
    expect(r.source.oversize).toBe(true);
  });
});

test("the final frame carries no detected links", async () => {
  const r = rig();
  r.fs.add("/r/src/a.ts");
  await feed(r.source, "see src/a.ts and https://example.com/x");
  await frameAfterStats(r);

  const frame = r.source.capture(0, { final: true, detectedLinks: false });

  expect(frame!.ansi).not.toContain("antgrid-");
});

describe("OSC 7", () => {
  test("a cwd inside the checkout becomes the live base and the report is not drawn", async () => {
    const r = rig();
    r.fs.add("/r/sub/a.ts");
    await feed(r.source, "\x1b]7;file:///r/sub\x07see a.ts");

    const ansi = await frameAfterStats(r);

    expect(r.source.linkBases().liveCwd).toBe("/r/sub");
    expect(ansi).not.toContain("file:///r/sub");
    expect(linksIn(ansi).map((l) => l.uri)).toEqual(["antgrid-path:?p=a.ts&b=l&k=f"]);
  });

  test("a remote host is never recorded", async () => {
    const r = rig();
    await feed(r.source, "\x1b]7;file://other-box/r/sub\x07");

    expect(r.source.linkBases().liveCwd).toBeUndefined();
  });

  test("a network-root cwd is never recorded", async () => {
    const r = rig();
    await feed(r.source, "\x1b]7;file:////host/share\x07");

    expect(r.source.linkBases().liveCwd).toBeUndefined();
  });

  test("a cwd outside the checkout is recorded but never used as a base", async () => {
    const r = rig();
    // An image is the one outside file a candidate may name, so only a base
    // that was never filtered could make the source ask about this path.
    r.fs.add("/elsewhere/a.png");
    await feed(r.source, "\x1b]7;file:///elsewhere\x07see a.png");

    const ansi = await frameAfterStats(r);

    expect(r.source.linkBases().liveCwd).toBe("/elsewhere");
    expect(ansi).not.toContain("antgrid-");
    expect(r.fs.calls.some((p) => p.startsWith("/elsewhere"))).toBe(false);
  });

  test("a spawn cwd outside the checkout is never used as a base", async () => {
    const r = rig({ links: { spawnCwd: "/elsewhere" } });
    r.fs.add("/elsewhere/a.png");
    await feed(r.source, "see a.png");

    const ansi = await frameAfterStats(r);

    expect(ansi).not.toContain("antgrid-");
    expect(r.fs.calls.some((p) => p.startsWith("/elsewhere"))).toBe(false);
  });
});

describe("without link options", () => {
  const fixture = "\x1b[?1049h\x1b[2;3H\x1b]8;;https://example.com/report\x1b\\\x1b[38;2;20;100;200mOpen report\x1b]8;;\x1b\\\x1b[0m\x1b[5;9H";

  test("frames are those a link-enabled source gives when told not to detect", async () => {
    const plain = new TerminalFrameSource(40, 6);
    const r = rig();
    r.fs.add("/r/src/a.ts");
    sources.push(plain);
    const text = fixture + String.fromCharCode(13, 10) + "src/a.ts https://example.com/x";
    for (const s of [plain, r.source]) await feed(s, text);
    // Without this the two could agree only because neither source linked anything.
    expect(linksIn(await frameAfterStats(r)).length).toBeGreaterThan(0);

    const ansi = plain.capture(0)!.ansi;

    expect(ansi).toBe(r.source.capture(0, { detectedLinks: false })!.ansi);
    expect(ansi).toContain("https://example.com/report");
    expect(ansi).not.toContain("antgrid-");
  });

  test("enabling detection changes no byte of a screen with nothing to link", async () => {
    const plain = new TerminalFrameSource(40, 6);
    const r = rig();
    sources.push(plain);
    for (const s of [plain, r.source]) await feed(s, fixture);

    expect(r.source.capture(0)!.ansi).toBe(plain.capture(0)!.ansi);
  });

  test("setLinkRoot and linkBases are inert", () => {
    const plain = new TerminalFrameSource(40, 6);
    sources.push(plain);

    plain.setLinkRoot("/r");

    expect(plain.linkBases()).toEqual({});
  });
});

test("an unusable link root is ignored", async () => {
  const r = rig();
  r.source.setLinkRoot("relative/path");
  expect(r.source.linkBases().checkoutRoot).toBe("/r");
  r.source.setLinkRoot("/ok\x00bad");
  expect(r.source.linkBases().checkoutRoot).toBe("/r");
});
