import { describe, it, expect, afterEach, beforeEach } from "bun:test";
import {
  PathStatCache,
  sharedPathStatCache,
  type LinkFs,
  type LinkFsStats,
  type PathStatCacheOptions,
  type PathStatus,
} from "../src/terminal-links/stat-cache";
import { isLocalVolume } from "../src/terminal-links/win32-volume";
import { posix, win32 } from "node:path";

type NodeKind = "file" | "dir" | "link" | "other";
interface FakeNode {
  kind: NodeKind;
  target?: string;
}

function statsOf(kind: NodeKind): LinkFsStats {
  return {
    isFile: () => kind === "file",
    isDirectory: () => kind === "dir",
    isSymbolicLink: () => kind === "link",
  };
}

/** A filesystem that records every call and can hold chosen calls open. */
class FakeFs implements LinkFs {
  readonly nodes = new Map<string, FakeNode>();
  readonly calls: string[] = [];
  readonly paths: string[] = [];
  private readonly holds = new Map<string, Array<() => void>>();
  private readonly held = new Set<string>();
  private active = 0;
  maxActive = 0;
  failMode: "none" | "reject" | "throw" = "none";

  set(path: string, kind: NodeKind, target?: string): this {
    this.nodes.set(path, { kind, target });
    return this;
  }

  hold(path: string): void {
    this.held.add(path);
  }

  /** Releases every call parked on `path`, and lets later ones through. */
  release(path: string): void {
    this.held.delete(path);
    for (const go of this.holds.get(path) ?? []) go();
    this.holds.delete(path);
  }

  count(op?: string): number {
    return op ? this.calls.filter((c) => c.startsWith(`${op}:`)).length : this.calls.length;
  }

  private async enter(op: string, path: string): Promise<void> {
    this.calls.push(`${op}:${path}`);
    this.paths.push(path);
    if (this.failMode === "throw") throw new Error("boom");
    if (this.failMode === "reject") return Promise.reject(new Error("boom"));
    this.active++;
    this.maxActive = Math.max(this.maxActive, this.active);
    try {
      if (this.held.has(path)) {
        await new Promise<void>((resolve) => {
          const list = this.holds.get(path) ?? [];
          list.push(resolve);
          this.holds.set(path, list);
        });
      }
      await Promise.resolve();
    } finally {
      this.active--;
    }
  }

  async lstat(path: string): Promise<LinkFsStats> {
    await this.enter("lstat", path);
    const node = this.nodes.get(path);
    if (!node) throw new Error("ENOENT");
    return statsOf(node.kind);
  }

  async stat(path: string): Promise<LinkFsStats> {
    await this.enter("stat", path);
    let at = path;
    let node = this.nodes.get(at);
    for (let hops = 0; node?.kind === "link" && hops < 32; hops++) {
      const target = node.target ?? "";
      const windows = /^[A-Za-z]:|^\\/.test(at);
      const api = windows ? win32 : posix;
      at = api.resolve(api.dirname(at), target);
      node = this.nodes.get(at);
    }
    if (!node || node.kind === "link") throw new Error("ENOENT");
    return statsOf(node.kind);
  }

  async readlink(path: string): Promise<string> {
    await this.enter("readlink", path);
    const node = this.nodes.get(path);
    if (node?.kind !== "link") throw new Error("EINVAL");
    return node.target ?? "";
  }
}

/** A clock and timer wheel the test advances by hand. */
class Clock {
  time = 1_000_000;
  private timers: Array<{ at: number; fn: () => void; live: boolean }> = [];
  now = () => this.time;
  timer = (fn: () => void, ms: number) => {
    const t = { at: this.time + ms, fn, live: true };
    this.timers.push(t);
    return { cancel: () => void (t.live = false) };
  };
  liveTimers(): number {
    return this.timers.filter((t) => t.live).length;
  }
  advance(ms: number): void {
    this.time += ms;
    for (const t of [...this.timers]) {
      if (t.live && t.at <= this.time) {
        t.live = false;
        t.fn();
      }
    }
    this.timers = this.timers.filter((t) => t.live);
  }
}

const tick = () => new Promise<void>((resolve) => setImmediate(resolve));
async function settle(): Promise<void> {
  for (let i = 0; i < 4; i++) await tick();
}

function dirs(fs: FakeFs, ...paths: string[]): void {
  for (const p of paths) fs.set(p, "dir");
}

function makeCache(
  fs: FakeFs,
  clock: Clock,
  opts: PathStatCacheOptions = {},
): PathStatCache {
  return new PathStatCache({
    fs,
    now: clock.now,
    timer: clock.timer,
    platform: "linux",
    ...opts,
  });
}

const unhandled: unknown[] = [];
const onUnhandled = (reason: unknown) => void unhandled.push(reason);

beforeEach(() => {
  unhandled.length = 0;
  process.on("unhandledRejection", onUnhandled);
});
afterEach(() => {
  process.off("unhandledRejection", onUnhandled);
});

describe("PathStatCache lookups and expiry", () => {
  it("answers a file, a directory and a missing path", async () => {
    const fs = new FakeFs();
    dirs(fs, "/r", "/r/d");
    fs.set("/r/a.ts", "file");
    const cache = makeCache(fs, new Clock());

    expect(cache.peek("/r/a.ts")).toBeUndefined();
    expect(cache.request("/r/a.ts")).toBe("queued");
    cache.request("/r/d");
    cache.request("/r/none");
    await settle();

    expect(cache.peek("/r/a.ts")).toBe("file");
    expect(cache.peek("/r/d")).toBe("dir");
    expect(cache.peek("/r/none")).toBe("missing");
  });

  it("serves a positive result for 30 s and then re-stats while still answering stale", async () => {
    const fs = new FakeFs();
    dirs(fs, "/r");
    fs.set("/r/a.ts", "file");
    const clock = new Clock();
    const cache = makeCache(fs, clock);
    cache.request("/r/a.ts");
    await settle();
    expect(cache.request("/r/a.ts")).toBe("fresh");

    clock.advance(29_999);
    expect(cache.request("/r/a.ts")).toBe("fresh");
    clock.advance(2);
    expect(cache.peek("/r/a.ts")).toBe("file");
    const before = fs.count("stat");
    expect(cache.request("/r/a.ts")).toBe("queued");
    await settle();
    expect(fs.count("stat")).toBe(before + 1);
  });

  it("serves a negative result for 4 s and then re-stats", async () => {
    const fs = new FakeFs();
    dirs(fs, "/r");
    const clock = new Clock();
    const cache = makeCache(fs, clock);
    cache.request("/r/a.ts");
    await settle();
    expect(cache.peek("/r/a.ts")).toBe("missing");
    expect(cache.request("/r/a.ts")).toBe("fresh");

    clock.advance(3_999);
    expect(cache.request("/r/a.ts")).toBe("fresh");
    clock.advance(2);
    fs.set("/r/a.ts", "file");
    expect(cache.request("/r/a.ts")).toBe("queued");
    await settle();
    expect(cache.peek("/r/a.ts")).toBe("file");
  });

  it("honours custom TTLs", async () => {
    const fs = new FakeFs();
    dirs(fs, "/r");
    fs.set("/r/a.ts", "file");
    const clock = new Clock();
    const cache = makeCache(fs, clock, { positiveTtlMs: 10, negativeTtlMs: 5 });
    cache.request("/r/a.ts");
    cache.request("/r/b.ts");
    await settle();
    clock.advance(6);
    expect(cache.request("/r/a.ts")).toBe("fresh");
    expect(cache.request("/r/b.ts")).toBe("queued");
    clock.advance(5);
    expect(cache.request("/r/a.ts")).toBe("queued");
  });

  it("never throws from peek or request", () => {
    const cache = makeCache(new FakeFs(), new Clock());
    expect(() => cache.peek(undefined as unknown as string)).not.toThrow();
    expect(() => cache.request(undefined as unknown as string)).not.toThrow();
  });
});

describe("PathStatCache capacity", () => {
  it("evicts the least recently used entry past maxEntries", async () => {
    const fs = new FakeFs();
    dirs(fs, "/r");
    for (const n of ["a", "b", "c", "d"]) fs.set(`/r/${n}`, "file");
    const cache = makeCache(fs, new Clock(), { maxEntries: 3 });
    for (const n of ["a", "b", "c"]) cache.request(`/r/${n}`);
    await settle();
    expect(cache.peek("/r/a")).toBe("file");

    cache.request("/r/d");
    await settle();

    expect(cache.peek("/r/a")).toBe("file");
    expect(cache.peek("/r/b")).toBeUndefined();
    expect(cache.peek("/r/c")).toBe("file");
    expect(cache.peek("/r/d")).toBe("file");
  });

  it("never runs more than maxInFlight real calls at once, resolveFresh included", async () => {
    const fs = new FakeFs();
    dirs(fs, "/r");
    const names = Array.from({ length: 12 }, (_, i) => `/r/f${i}`);
    for (const n of names) {
      fs.set(n, "file");
      fs.hold(n);
    }
    const cache = makeCache(fs, new Clock());
    for (const n of names.slice(0, 9)) cache.request(n);
    const fresh = names.slice(9).map((n) => cache.resolveFresh(n, 1000));
    await settle();

    expect(fs.maxActive).toBeLessThanOrEqual(4);
    expect(fs.count("stat")).toBe(0);
    for (const n of names) {
      fs.release(n);
      await tick();
    }
    await Promise.all(fresh);
    await settle();
    expect(fs.maxActive).toBeLessThanOrEqual(4);
    expect(fs.count("stat")).toBe(12);
  });

  it("lets resolveFresh jump ahead of queued requests", async () => {
    const fs = new FakeFs();
    dirs(fs, "/r");
    for (const n of ["h1", "h2", "h3", "h4", "q1", "q2", "click"]) {
      fs.set(`/r/${n}`, "file");
    }
    for (const n of ["h1", "h2", "h3", "h4"]) fs.hold(`/r/${n}`);
    const cache = makeCache(fs, new Clock());
    for (const n of ["h1", "h2", "h3", "h4", "q1", "q2"]) cache.request(`/r/${n}`);
    const click = cache.resolveFresh("/r/click", 1000);
    await settle();

    fs.release("/r/h1");
    await settle();

    const statOrder = fs.calls.filter((c) => c.startsWith("stat:"));
    expect(statOrder).toContain("stat:/r/click");
    expect(statOrder.indexOf("stat:/r/click")).toBeLessThan(statOrder.indexOf("stat:/r/q1"));
    expect(await click).toBe("file");
  });

  it("promotes an already queued request when a click asks for it", async () => {
    const fs = new FakeFs();
    dirs(fs, "/r");
    for (const n of ["h1", "h2", "h3", "h4", "q1", "target"]) fs.set(`/r/${n}`, "file");
    for (const n of ["h1", "h2", "h3", "h4"]) fs.hold(`/r/${n}`);
    const cache = makeCache(fs, new Clock());
    for (const n of ["h1", "h2", "h3", "h4", "q1", "target"]) cache.request(`/r/${n}`);
    const click = cache.resolveFresh("/r/target", 1000);
    fs.release("/r/h1");
    await settle();

    const statOrder = fs.calls.filter((c) => c.startsWith("stat:"));
    expect(statOrder).toContain("stat:/r/target");
    expect(statOrder.indexOf("stat:/r/target")).toBeLessThan(statOrder.indexOf("stat:/r/q1"));
    expect(await click).toBe("file");
  });

  it("ignores maxQueued for resolveFresh and drops plain requests past it", async () => {
    const fs = new FakeFs();
    dirs(fs, "/r");
    for (const n of ["a", "b", "c", "d", "e", "f", "g"]) {
      fs.set(`/r/${n}`, "file");
      fs.hold(`/r/${n}`);
    }
    const cache = makeCache(fs, new Clock(), { maxInFlight: 1, maxQueued: 2 });
    expect(cache.request("/r/a")).toBe("queued");
    expect(cache.request("/r/b")).toBe("queued");
    expect(cache.request("/r/c")).toBe("queued");
    expect(cache.request("/r/d")).toBe("dropped");
    const click = cache.resolveFresh("/r/e", 1000);
    expect(cache.request("/r/e")).toBe("inflight");
    for (const n of ["a", "b", "c", "e"]) {
      fs.release(`/r/${n}`);
      await settle();
    }
    expect(await click).toBe("file");
  });
});

describe("PathStatCache sharing and failure", () => {
  it("shares one stat between concurrent callers for a key", async () => {
    const fs = new FakeFs();
    dirs(fs, "/r");
    fs.set("/r/a.ts", "file");
    fs.hold("/r/a.ts");
    const cache = makeCache(fs, new Clock());

    expect(cache.request("/r/a.ts")).toBe("queued");
    expect(cache.request("/r/a.ts")).toBe("inflight");
    const one = cache.resolveFresh("/r/a.ts", 1000);
    const two = cache.resolveFresh("/r/a.ts", 1000);
    await settle();
    fs.release("/r/a.ts");

    expect(await one).toBe("file");
    expect(await two).toBe("file");
    expect(fs.count("stat")).toBe(1);
  });

  it("reuses a component lookup across sibling paths", async () => {
    const fs = new FakeFs();
    dirs(fs, "/r", "/r/deep");
    fs.set("/r/deep/a.ts", "file").set("/r/deep/b.ts", "file");
    const cache = makeCache(fs, new Clock());
    cache.request("/r/deep/a.ts");
    cache.request("/r/deep/b.ts");
    await settle();
    expect(fs.calls.filter((c) => c === "lstat:/r/deep").length).toBe(1);
    expect(fs.calls.filter((c) => c === "lstat:/r").length).toBe(1);
  });

  it("serves a cached answer from resolveFresh when it is younger than the window", async () => {
    const fs = new FakeFs();
    dirs(fs, "/r");
    fs.set("/r/a.ts", "file");
    const clock = new Clock();
    const cache = makeCache(fs, clock);
    expect(await cache.resolveFresh("/r/a.ts", 1000)).toBe("file");
    const calls = fs.count();
    clock.advance(500);
    expect(await cache.resolveFresh("/r/a.ts", 1000)).toBe("file");
    expect(fs.count()).toBe(calls);

    clock.advance(600);
    fs.set("/r/a.ts", "dir");
    expect(await cache.resolveFresh("/r/a.ts", 1000)).toBe("dir");
  });

  it("maps a rejecting filesystem to missing with no unhandled rejection", async () => {
    const fs = new FakeFs();
    fs.failMode = "reject";
    const cache = makeCache(fs, new Clock());
    cache.request("/r/a.ts");
    expect(await cache.resolveFresh("/r/b.ts", 1000)).toBe("missing");
    await settle();
    expect(cache.peek("/r/a.ts")).toBe("missing");
    expect(unhandled).toEqual([]);
  });

  it("maps a synchronously throwing filesystem to missing", async () => {
    const fs = new FakeFs();
    fs.failMode = "throw";
    const cache = makeCache(fs, new Clock());
    cache.request("/r/a.ts");
    expect(await cache.resolveFresh("/r/b.ts", 1000)).toBe("missing");
    await settle();
    expect(cache.peek("/r/a.ts")).toBe("missing");
    expect(unhandled).toEqual([]);
  });

  it("maps a throwing final stat to missing", async () => {
    const fs = new FakeFs();
    dirs(fs, "/r");
    fs.set("/r/a.ts", "file");
    const realStat = fs.stat.bind(fs);
    fs.stat = async () => {
      throw new Error("EACCES");
    };
    const cache = makeCache(fs, new Clock());
    expect(await cache.resolveFresh("/r/a.ts", 1000)).toBe("missing");
    fs.stat = realStat;
  });

  it("never rejects from prefetch or resolveFresh", async () => {
    const fs = new FakeFs();
    fs.failMode = "throw";
    const cache = makeCache(fs, new Clock());
    await cache.prefetch(["/r/a", "/r/b"], 50);
    expect(await cache.resolveFresh("/r/c", 1000)).toBe("missing");
  });

  it("prefetch returns once everything settles, or when the budget runs out", async () => {
    const fs = new FakeFs();
    dirs(fs, "/r");
    fs.set("/r/a", "file").set("/r/b", "file");
    const clock = new Clock();
    const cache = makeCache(fs, clock);
    await cache.prefetch(["/r/a", "/r/b"], 100);
    expect(cache.peek("/r/a")).toBe("file");
    expect(cache.peek("/r/b")).toBe("file");

    fs.set("/r/c", "file");
    fs.hold("/r/c");
    let done = false;
    const slow = cache.prefetch(["/r/c"], 150).then(() => {
      done = true;
    });
    await settle();
    expect(done).toBe(false);
    clock.advance(150);
    await slow;
    expect(done).toBe(true);
    expect(cache.peek("/r/c")).toBeUndefined();
    fs.release("/r/c");
    await settle();
    expect(cache.peek("/r/c")).toBe("file");
  });

  it("cancels the timers it armed once everything settles", async () => {
    const fs = new FakeFs();
    dirs(fs, "/r");
    fs.set("/r/a", "file");
    const clock = new Clock();
    const cache = makeCache(fs, clock);
    await cache.prefetch(["/r/a"], 100);
    await cache.resolveFresh("/r/a", 0);
    await settle();
    expect(clock.liveTimers()).toBe(0);
  });
});

describe("PathStatCache listeners", () => {
  it("fires onChange only when a status changes, including from never-known", async () => {
    const fs = new FakeFs();
    dirs(fs, "/r");
    fs.set("/r/a.ts", "file");
    const clock = new Clock();
    const cache = makeCache(fs, clock);
    const seen: Array<[string, PathStatus]> = [];
    cache.onChange((abs, status) => void seen.push([abs, status]));

    cache.request("/r/a.ts");
    await settle();
    expect(seen).toEqual([["/r/a.ts", "file"]]);

    clock.advance(31_000);
    cache.request("/r/a.ts");
    await settle();
    expect(seen).toHaveLength(1);

    fs.nodes.delete("/r/a.ts");
    clock.advance(31_000);
    cache.request("/r/a.ts");
    await settle();
    expect(seen).toEqual([
      ["/r/a.ts", "file"],
      ["/r/a.ts", "missing"],
    ]);
  });

  it("stops calling a listener once it unsubscribes, and isolates a throwing one", async () => {
    const fs = new FakeFs();
    dirs(fs, "/r");
    fs.set("/r/a", "file").set("/r/b", "file");
    const cache = makeCache(fs, new Clock());
    const seen: string[] = [];
    cache.onChange(() => {
      throw new Error("listener");
    });
    const off = cache.onChange((abs) => void seen.push(abs));
    cache.request("/r/a");
    await settle();
    off();
    cache.request("/r/b");
    await settle();
    expect(seen).toEqual(["/r/a"]);
    expect(cache.peek("/r/b")).toBe("file");
    expect(unhandled).toEqual([]);
  });

  it("fires onDrain when the queue empties after it dropped a request", async () => {
    const fs = new FakeFs();
    dirs(fs, "/r");
    for (const n of ["a", "b", "c", "d"]) {
      fs.set(`/r/${n}`, "file");
      fs.hold(`/r/${n}`);
    }
    const cache = makeCache(fs, new Clock(), { maxInFlight: 1, maxQueued: 1 });
    let drained = 0;
    cache.onDrain(() => void drained++);

    cache.request("/r/a");
    cache.request("/r/b");
    expect(cache.request("/r/c")).toBe("dropped");
    expect(drained).toBe(0);

    fs.release("/r/a");
    await settle();
    expect(drained).toBe(1);
    fs.release("/r/b");
    await settle();
    expect(drained).toBe(1);
  });

  it("does not fire onDrain when nothing was dropped", async () => {
    const fs = new FakeFs();
    dirs(fs, "/r");
    fs.set("/r/a", "file");
    const cache = makeCache(fs, new Clock());
    let drained = 0;
    cache.onDrain(() => void drained++);
    cache.request("/r/a");
    await settle();
    expect(drained).toBe(0);
  });
});

describe("PathStatCache refusals", () => {
  it("makes zero filesystem calls for a refused shape", async () => {
    const fs = new FakeFs();
    const cache = makeCache(fs, new Clock(), { platform: "win32", isLocalVolume: () => true });
    for (const p of ["\\\\host\\share\\a.png", "//host/share/a.png", "\\\\?\\C:\\x.png", "C:a.png", "x::$DATA"]) {
      expect(await cache.resolveFresh(p, 1000)).toBe("refused");
      cache.request(p);
    }
    await settle();
    expect(fs.count()).toBe(0);
  });

  it("refuses a control character on any platform without a call", async () => {
    const fs = new FakeFs();
    const cache = makeCache(fs, new Clock());
    expect(await cache.resolveFresh("/r/a\u001b.ts", 1000)).toBe("refused");
    expect(fs.count()).toBe(0);
  });

  it("refuses an autofs network prefix on posix without a call", async () => {
    const fs = new FakeFs();
    const cache = makeCache(fs, new Clock());
    expect(await cache.resolveFresh("/net/host/x", 1000)).toBe("refused");
    expect(await cache.resolveFresh("/Network/Servers/x", 1000)).toBe("refused");
    expect(fs.count()).toBe(0);
  });

  it("does not refuse a prefix that merely starts with the same letters", async () => {
    const fs = new FakeFs();
    dirs(fs, "/networking", "/netx");
    fs.set("/netx/a", "file");
    const cache = makeCache(fs, new Clock());
    expect(await cache.resolveFresh("/netx/a", 1000)).toBe("file");
    expect(await cache.resolveFresh("/networking", 1000)).toBe("dir");
  });

  it("refuses the autofs roots themselves and in any letter case, without a call", async () => {
    const fs = new FakeFs();
    const cache = makeCache(fs, new Clock());
    for (const p of ["/net", "/Network", "/NET/evil/x.png", "/Net/evil/x.png", "/network/Servers/evil/x.png"]) {
      expect(await cache.resolveFresh(p, 1000)).toBe("refused");
    }
    expect(fs.count()).toBe(0);
  });

  it("refuses a relative path and a path with dot segments", async () => {
    const fs = new FakeFs();
    const cache = makeCache(fs, new Clock());
    expect(await cache.resolveFresh("a/b.ts", 1000)).toBe("refused");
    expect(await cache.resolveFresh("/r/../etc/a", 1000)).toBe("refused");
    expect(fs.count()).toBe(0);
  });
});

/**
 * A filesystem that resolves links the way the OS does: every non-final
 * component is followed, `..` is taken against the directory actually
 * reached, and a link's target is read relative to the directory it sits in.
 * `touched` records every real path a call landed on, including components
 * that turned out to be missing, because an autofs mount happens on the lookup.
 */
class OsFs implements LinkFs {
  readonly nodes = new Map<string, FakeNode>();
  readonly touched: string[] = [];
  calls = 0;

  dir(path: string): this {
    let at = path;
    while (at !== "/") {
      if (!this.nodes.has(at)) this.nodes.set(at, { kind: "dir" });
      at = posix.dirname(at);
    }
    return this;
  }

  file(path: string): this {
    this.dir(posix.dirname(path));
    this.nodes.set(path, { kind: "file" });
    return this;
  }

  link(path: string, target: string): this {
    this.dir(posix.dirname(path));
    this.nodes.set(path, { kind: "link", target });
    return this;
  }

  private walk(path: string, followLast: boolean): FakeNode {
    this.calls++;
    const parts = path.split("/").filter(Boolean);
    let real = "/";
    let hops = 0;
    let node: FakeNode | undefined = this.nodes.get("/") ?? { kind: "dir" };
    while (parts.length > 0) {
      const part = parts.shift()!;
      if (part === ".") continue;
      if (part === "..") {
        real = posix.dirname(real);
        node = this.nodes.get(real) ?? { kind: "dir" };
        continue;
      }
      const candidate = real === "/" ? "/" + part : real + "/" + part;
      this.touched.push(candidate);
      node = this.nodes.get(candidate);
      if (!node) throw new Error("ENOENT");
      if (node.kind === "link" && (parts.length > 0 || followLast)) {
        if (++hops > 40) throw new Error("ELOOP");
        if (node.target!.startsWith("/")) real = "/";
        parts.unshift(...node.target!.split("/").filter(Boolean));
        continue;
      }
      if (parts.length > 0 && node.kind !== "dir") throw new Error("ENOTDIR");
      real = candidate;
    }
    return node;
  }

  async lstat(path: string): Promise<LinkFsStats> {
    return statsOf(this.walk(path, false).kind);
  }
  async stat(path: string): Promise<LinkFsStats> {
    return statsOf(this.walk(path, true).kind);
  }
  async readlink(path: string): Promise<string> {
    const node = this.walk(path, false);
    if (node.kind !== "link") throw new Error("EINVAL");
    return node.target!;
  }
}

describe("PathStatCache link walking", () => {
  function osCache(fs: OsFs): PathStatCache {
    return new PathStatCache({ fs, platform: "darwin" });
  }
  const reachedAutofs = (fs: OsFs) => fs.touched.filter((p) => /^\/(net|network)(\/|$)/i.test(p));

  it("refuses a link to the filesystem root that is then walked into an autofs mount", async () => {
    const fs = new OsFs().link("/repo/up", "/").file("/net/evil/x.png");
    expect(await osCache(fs).resolveFresh("/repo/up/net/evil/x.png", 1000)).toBe("refused");
    expect(reachedAutofs(fs)).toEqual([]);
  });

  it("refuses a link that points straight at an autofs root", async () => {
    const fs = new OsFs().link("/repo/n", "/net").file("/net/evil/x.png");
    expect(await osCache(fs).resolveFresh("/repo/n/evil/x.png", 1000)).toBe("refused");
    expect(reachedAutofs(fs)).toEqual([]);
  });

  it("takes a link's relative target and a later `..` against the real directory", async () => {
    const fs = new OsFs()
      .link("/repo/s1/s2/s3/a", "../../../d")
      .link("/repo/d/b", "../../net/evil")
      .file("/net/evil/x.png")
      .dir("/repo/s1/s2/net/evil");
    expect(await osCache(fs).resolveFresh("/repo/s1/s2/s3/a/b/x.png", 1000)).toBe("refused");
    expect(reachedAutofs(fs)).toEqual([]);
  });

  it("still follows an ordinary relative link out of a sibling directory", async () => {
    const fs = new OsFs().file("/repo/real/a.ts").link("/repo/x/y/alias", "../../real");
    expect(await osCache(fs).resolveFresh("/repo/x/y/alias/a.ts", 1000)).toBe("file");
    expect(await osCache(fs).resolveFresh("/repo/x/y/alias", 1000)).toBe("dir");
  });

  it("bounds the work a tangle of links can cause, whatever the printed path is", async () => {
    // b0 -> /r, and each bN -> /r followed by six copies of /b(N-1): the printed
    // path is short but every link leads through six more.
    const fs = new OsFs().file("/r/f.ts").link("/r/b0", "/r");
    for (let n = 1; n <= 4; n++) fs.link(`/r/b${n}`, "/r" + `/b${n - 1}`.repeat(6));
    const printed = "/r" + "/b4".repeat(6) + "/f.ts";
    expect(printed.length).toBeLessThan(40);

    expect(await osCache(fs).resolveFresh(printed, 1000)).toBe("refused");
    expect(fs.calls).toBeLessThan(200);
  });
});

describe("PathStatCache soft timeout", () => {
  it("frees waiters after 3 s while the slot stays held", async () => {
    const fs = new FakeFs();
    dirs(fs, "/r");
    for (const n of ["a", "b", "c", "d", "e"]) fs.set(`/r/${n}`, "file");
    for (const n of ["a", "b", "c", "d"]) fs.hold(`/r/${n}`);
    const clock = new Clock();
    const cache = makeCache(fs, clock);
    const seen: Array<[string, PathStatus]> = [];
    cache.onChange((abs, status) => void seen.push([abs, status]));

    const waiter = cache.resolveFresh("/r/a", 1000);
    for (const n of ["b", "c", "d"]) cache.request(`/r/${n}`);
    await settle();
    expect(cache.request("/r/e")).toBe("queued");
    await settle();
    expect(fs.calls.some((c) => c === "stat:/r/e")).toBe(false);

    clock.advance(2_999);
    await settle();
    expect(cache.peek("/r/a")).toBeUndefined();
    clock.advance(1);
    expect(await waiter).toBe("missing");
    expect(cache.peek("/r/a")).toBe("missing");
    expect(seen).toContainEqual(["/r/a", "missing"]);

    await settle();
    expect(fs.calls.some((c) => c === "stat:/r/e")).toBe(false);
    expect(cache.request("/r/e")).toBe("inflight");

    fs.release("/r/a");
    await settle();
    expect(fs.calls.some((c) => c === "stat:/r/e")).toBe(true);
    expect(cache.peek("/r/a")).toBe("file");
    expect(cache.peek("/r/e")).toBe("file");
  });

  it("does not start a second real call for a key whose first one is still hung", async () => {
    const fs = new FakeFs();
    dirs(fs, "/r");
    fs.set("/r/a", "file");
    fs.hold("/r/a");
    const clock = new Clock();
    const cache = makeCache(fs, clock);
    cache.request("/r/a");
    await settle();
    clock.advance(3_000);
    clock.advance(5_000);
    expect(cache.request("/r/a")).toBe("inflight");
    expect(await cache.resolveFresh("/r/a", 1000)).toBe("missing");
    expect(fs.calls.filter((c) => c.endsWith(":/r/a"))).toEqual(["lstat:/r/a"]);
  });

  it("answers a queued click with missing after the soft timeout instead of hanging", async () => {
    const fs = new FakeFs();
    dirs(fs, "/r");
    for (const n of ["a", "b", "c", "d", "click"]) fs.set(`/r/${n}`, "file");
    for (const n of ["a", "b", "c", "d"]) fs.hold(`/r/${n}`);
    const clock = new Clock();
    const cache = makeCache(fs, clock);
    for (const n of ["a", "b", "c", "d"]) cache.request(`/r/${n}`);
    await settle();
    const click = cache.resolveFresh("/r/click", 1000);
    await settle();
    clock.advance(3_000);
    expect(await click).toBe("missing");
  });

  it("honours a custom soft timeout", async () => {
    const fs = new FakeFs();
    dirs(fs, "/r");
    fs.set("/r/a", "file");
    fs.hold("/r/a");
    const clock = new Clock();
    const cache = makeCache(fs, clock, { softTimeoutMs: 100 });
    const waiter = cache.resolveFresh("/r/a", 1000);
    await settle();
    clock.advance(100);
    expect(await waiter).toBe("missing");
  });
});

describe("PathStatCache on win32 semantics", () => {
  function winCache(fs: FakeFs, opts: PathStatCacheOptions = {}): PathStatCache {
    return makeCache(fs, new Clock(), {
      platform: "win32",
      isLocalVolume: (abs) => !abs.toUpperCase().startsWith("Z:"),
      ...opts,
    });
  }

  function neverReceivedUnc(fs: FakeFs): void {
    expect(fs.paths.filter((p) => p.startsWith("\\\\") || p.startsWith("//"))).toEqual([]);
  }

  it("answers an ordinary local file and directory", async () => {
    const fs = new FakeFs();
    dirs(fs, "C:\\", "C:\\proj", "C:\\proj\\src");
    fs.set("C:\\proj\\src\\a.ts", "file");
    const cache = winCache(fs);
    expect(await cache.resolveFresh("C:\\proj\\src\\a.ts", 1000)).toBe("file");
    expect(await cache.resolveFresh("C:\\proj\\src", 1000)).toBe("dir");
    expect(await cache.resolveFresh("C:\\proj\\none.ts", 1000)).toBe("missing");
  });

  it("refuses a junction whose target is a UNC share and never hands a UNC path to the filesystem", async () => {
    const fs = new FakeFs();
    dirs(fs, "C:\\proj");
    fs.set("C:\\proj\\jn", "link", "\\\\host\\share");
    fs.set("\\\\host\\share", "dir");
    fs.set("\\\\host\\share\\a.png", "file");
    const cache = winCache(fs);
    expect(await cache.resolveFresh("C:\\proj\\jn\\a.png", 1000)).toBe("refused");
    expect(await cache.resolveFresh("C:\\proj\\jn", 1000)).toBe("refused");
    neverReceivedUnc(fs);
  });

  it("refuses a link that leads to a link that leads to a UNC share", async () => {
    const fs = new FakeFs();
    dirs(fs, "C:\\proj");
    fs.set("C:\\proj\\l1", "link", "C:\\proj\\l2");
    fs.set("C:\\proj\\l2", "link", "\\\\host\\share\\x");
    const cache = winCache(fs);
    expect(await cache.resolveFresh("C:\\proj\\l1", 1000)).toBe("refused");
    neverReceivedUnc(fs);
  });

  it("refuses a link whose target is on a non-local volume before touching it", async () => {
    const fs = new FakeFs();
    dirs(fs, "C:\\proj");
    fs.set("C:\\proj\\l1", "link", "Z:\\data\\a.txt");
    fs.set("Z:\\data\\a.txt", "file");
    const cache = winCache(fs);
    expect(await cache.resolveFresh("C:\\proj\\l1", 1000)).toBe("refused");
    expect(fs.paths.some((p) => p.startsWith("Z:"))).toBe(false);
  });

  it("follows a relative link target against the link's own directory", async () => {
    const fs = new FakeFs();
    dirs(fs, "C:\\proj", "C:\\proj\\real");
    fs.set("C:\\proj\\real\\a.ts", "file");
    fs.set("C:\\proj\\alias", "link", "real\\a.ts");
    const cache = winCache(fs);
    expect(await cache.resolveFresh("C:\\proj\\alias", 1000)).toBe("file");
  });

  function chain(fs: FakeFs, links: number): string {
    dirs(fs, "C:\\proj");
    fs.set("C:\\proj\\real.txt", "file");
    for (let i = 1; i <= links; i++) {
      fs.set(`C:\\proj\\l${i}`, "link", i === links ? "C:\\proj\\real.txt" : `C:\\proj\\l${i + 1}`);
    }
    return "C:\\proj\\l1";
  }

  it("refuses a chain of nine links and follows one of eight", async () => {
    const nine = new FakeFs();
    expect(await winCache(nine).resolveFresh(chain(nine, 9), 1000)).toBe("refused");

    const eight = new FakeFs();
    expect(await winCache(eight).resolveFresh(chain(eight, 8), 1000)).toBe("file");
  });

  it("refuses a link loop instead of spinning", async () => {
    const fs = new FakeFs();
    dirs(fs, "C:\\proj");
    fs.set("C:\\proj\\a", "link", "C:\\proj\\b");
    fs.set("C:\\proj\\b", "link", "C:\\proj\\a");
    expect(await winCache(fs).resolveFresh("C:\\proj\\a", 1000)).toBe("refused");
  });

  it("reports a device name as missing", async () => {
    const fs = new FakeFs();
    dirs(fs, "C:\\proj");
    fs.set("C:\\proj\\nul", "other");
    expect(await winCache(fs).resolveFresh("C:\\proj\\nul", 1000)).toBe("missing");
  });

  it("reports a dangling link as missing", async () => {
    const fs = new FakeFs();
    dirs(fs, "C:\\proj");
    fs.set("C:\\proj\\gone", "link", "C:\\proj\\nowhere");
    expect(await winCache(fs).resolveFresh("C:\\proj\\gone", 1000)).toBe("missing");
  });

  it("refuses a path on a non-local volume with zero filesystem calls", async () => {
    const fs = new FakeFs();
    dirs(fs, "Z:\\", "Z:\\data");
    fs.set("Z:\\data\\a.png", "file");
    const cache = winCache(fs);
    expect(await cache.resolveFresh("Z:\\data\\a.png", 1000)).toBe("refused");
    cache.request("Z:\\data\\a.png");
    await settle();
    expect(fs.count()).toBe(0);
  });

  it("allows a volume the checkout root lives on, however it is classified", async () => {
    const fs = new FakeFs();
    dirs(fs, "Z:\\", "Z:\\proj");
    fs.set("Z:\\proj\\a.ts", "file");
    const cache = makeCache(fs, new Clock(), { platform: "win32" });
    cache.trustVolume("z:\\proj");
    expect(await cache.resolveFresh("Z:\\proj\\a.ts", 1000)).toBe("file");
    expect(fs.count()).toBeGreaterThan(0);
  });

  it("does not trust a volume nobody named", async () => {
    const fs = new FakeFs();
    dirs(fs, "Y:\\proj");
    fs.set("Y:\\proj\\a.ts", "file");
    const cache = makeCache(fs, new Clock(), { platform: "win32" });
    cache.trustVolume("Z:\\proj");
    cache.trustVolume("\\\\host\\share\\proj");
    cache.trustVolume("relative\\proj");
    const outcome = await cache.resolveFresh("Y:\\proj\\a.ts", 1000);
    // Without a local-volume lookup (non-Windows host) the path is refused;
    // on Windows the answer follows the real drive type, which a test must
    // not depend on.
    if (process.platform !== "win32") expect(outcome).toBe("refused");
  });
});

describe("isLocalVolume", () => {
  it("is always true off Windows", () => {
    expect(isLocalVolume("/anything", new Set(), "linux")).toBe(true);
    expect(isLocalVolume("Z:\\x", new Set(), "darwin")).toBe(true);
  });

  it("allows a trusted drive letter in either case without a lookup", () => {
    expect(isLocalVolume("Q:\\x", new Set(["Q"]), "win32")).toBe(true);
    expect(isLocalVolume("q:\\x", new Set(["Q"]), "win32")).toBe(true);
    expect(isLocalVolume("Q:\\x", new Set(["q"]), "win32")).toBe(true);
  });

  it("refuses a path with no drive letter", () => {
    expect(isLocalVolume("\\\\host\\share\\x", new Set(["C"]), "win32")).toBe(false);
    expect(isLocalVolume("relative\\x", new Set(["C"]), "win32")).toBe(false);
  });

  it.skipIf(process.platform !== "win32")("asks the OS for the system drive's type", () => {
    const drive = process.env.SystemDrive ?? "C:";
    expect(isLocalVolume(`${drive}\\Windows`, new Set(), "win32")).toBe(true);
  });

  it.skipIf(process.platform !== "win32")("refuses a drive letter nothing is mapped to", () => {
    const used = new Set<string>();
    for (const letter of "ABCDEFGHIJKLMNOPQRSTUVWXYZ") {
      if (isLocalVolume(`${letter}:\\`, new Set(), "win32")) used.add(letter);
    }
    const unused = [..."ZYXWVUTSRQPONM"].find((l) => !used.has(l));
    if (unused) expect(isLocalVolume(`${unused}:\\x`, new Set(), "win32")).toBe(false);
  });
});

describe("sharedPathStatCache", () => {
  it("returns one instance", () => {
    expect(sharedPathStatCache()).toBe(sharedPathStatCache());
  });
});
