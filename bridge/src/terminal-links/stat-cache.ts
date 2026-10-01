import { lstat, readlink, stat } from "node:fs/promises";
import { posix, win32 } from "node:path";
import { isRefusedPathShape } from "./grammar";
import { isLocalVolume as defaultIsLocalVolume } from "./win32-volume";

export type PathStatus = "file" | "dir" | "missing" | "refused";

export interface LinkFsStats {
  isFile(): boolean;
  isDirectory(): boolean;
  isSymbolicLink(): boolean;
}

export interface LinkFs {
  lstat(p: string): Promise<LinkFsStats>;
  stat(p: string): Promise<LinkFsStats>;
  readlink(p: string): Promise<string>;
}

/** "queued" means this call created a new stat; a key that is already queued
 *  or running answers "inflight", so a caller charging its budget per "queued"
 *  is not billed again for the same key on the next frame. */
export type RequestOutcome = "fresh" | "inflight" | "queued" | "dropped";

export interface PathStatCacheOptions {
  fs?: LinkFs;
  now?: () => number;
  platform?: NodeJS.Platform;
  isLocalVolume?: (abs: string) => boolean;
  timer?: (fn: () => void, ms: number) => { cancel(): void };
  maxEntries?: number;
  maxInFlight?: number;
  maxQueued?: number;
  positiveTtlMs?: number;
  negativeTtlMs?: number;
  softTimeoutMs?: number;
}

/** Links followed in ONE check before the path is refused: far more than any
 *  real layout needs, and a loop terminates here instead of spinning. It counts
 *  every link on the way, not only nesting, so a short printed path through a
 *  tangle of links cannot multiply into thousands of syscalls. */
const MAX_LINKS_PER_CHECK = 8;
/** Components one check may look at, links' own targets included. */
const MAX_WALK_STEPS = 512;
/** `/net` and `/Network` are autofs roots; case-folded because the default
 *  macOS volume is case-insensitive. */
const AUTOFS_ROOT = /^\/(?:net|network)(?:\/|$)/i;

const defaultFs: LinkFs = { lstat, stat, readlink };

const defaultTimer = (fn: () => void, ms: number): { cancel(): void } => {
  const handle = setTimeout(fn, ms);
  handle.unref?.();
  return { cancel: () => clearTimeout(handle) };
};

interface Entry {
  status: PathStatus;
  at: number;
}

type Component = { kind: "missing" } | { kind: "plain" } | { kind: "link"; target: string };

interface ComponentEntry {
  value: Component;
  at: number;
}

interface Job {
  key: string;
  state: "queued" | "running";
  priority: boolean;
  timer?: { cancel(): void };
  timedOut: boolean;
  settle: (status: PathStatus) => void;
  promise: Promise<PathStatus>;
}

/**
 * Answers "is this printed path a file or directory right now" for link
 * detection, without ever letting detection wait on the filesystem.
 *
 * Detection runs inside frame capture, where a blocking call would stall
 * terminal output, so lookups are `peek` (a Map read) plus `request` (queue a
 * stat for later). Results arrive through `onChange`, and the owner of a frame
 * re-captures when one that mattered to it lands.
 *
 * Every stat shares one small worker pool and one soft deadline. Paths come
 * from whatever a program printed, so a stat can land on a dead share; the
 * deadline frees the WAITERS, never the slot, which stays held until the real
 * call returns. That bounds the damage a hung share can do to `maxInFlight`
 * stuck calls instead of one per click.
 */
export class PathStatCache {
  private readonly fs: LinkFs;
  private readonly now: () => number;
  private readonly platform: NodeJS.Platform;
  private readonly localVolume: (abs: string) => boolean;
  private readonly timer: (fn: () => void, ms: number) => { cancel(): void };
  private readonly maxEntries: number;
  private readonly maxInFlight: number;
  private readonly maxQueued: number;
  private readonly positiveTtlMs: number;
  private readonly negativeTtlMs: number;
  private readonly softTimeoutMs: number;

  private readonly trusted = new Set<string>();
  private readonly entries = new Map<string, Entry>();
  private readonly components = new Map<string, ComponentEntry>();
  private readonly componentsInFlight = new Map<string, Promise<Component>>();
  private readonly jobs = new Map<string, Job>();
  private readonly priorityQueue: Job[] = [];
  private readonly normalQueue: Job[] = [];
  private running = 0;
  private droppedSinceDrain = false;
  private readonly changeListeners = new Set<(abs: string, status: PathStatus) => void>();
  private readonly drainListeners = new Set<() => void>();

  constructor(opts: PathStatCacheOptions = {}) {
    this.fs = opts.fs ?? defaultFs;
    this.now = opts.now ?? Date.now;
    this.platform = opts.platform ?? process.platform;
    this.localVolume = opts.isLocalVolume ?? ((abs) => defaultIsLocalVolume(abs, this.trusted, this.platform));
    this.timer = opts.timer ?? defaultTimer;
    this.maxEntries = opts.maxEntries ?? 4096;
    this.maxInFlight = opts.maxInFlight ?? 4;
    this.maxQueued = opts.maxQueued ?? 512;
    this.positiveTtlMs = opts.positiveTtlMs ?? 30_000;
    this.negativeTtlMs = opts.negativeTtlMs ?? 4_000;
    this.softTimeoutMs = opts.softTimeoutMs ?? 3_000;
  }

  /** Marks the checkout root's drive as allowed even when it is remote: the
   *  bridge already works there, so refusing it would unlink the whole tree. */
  trustVolume(root: string): void {
    const m = /^([A-Za-z]):/.exec(root);
    if (m) this.trusted.add(m[1]!.toUpperCase());
  }

  /** Stale included: a lookup that is merely old still answers, and `request`
   *  is what refreshes it. */
  peek(abs: string): PathStatus | undefined {
    try {
      const entry = this.entries.get(abs);
      if (!entry) return undefined;
      this.entries.delete(abs);
      this.entries.set(abs, entry);
      return entry.status;
    } catch {
      return undefined;
    }
  }

  request(abs: string): RequestOutcome {
    try {
      const entry = this.entries.get(abs);
      if (entry && this.isFresh(entry, Infinity)) return "fresh";
      if (this.jobs.has(abs)) return "inflight";
      if (this.normalQueue.length >= this.maxQueued) {
        this.droppedSinceDrain = true;
        return "dropped";
      }
      this.enqueue(abs, false);
      this.pump();
      return "queued";
    } catch {
      return "dropped";
    }
  }

  /** Jumps the queue but still respects `maxInFlight`, and ignores `maxQueued`:
   *  a click is bounded by its caller's own in-flight cap instead. */
  async resolveFresh(abs: string, maxAgeMs: number): Promise<PathStatus> {
    try {
      const entry = this.entries.get(abs);
      if (entry && this.isFresh(entry, maxAgeMs)) return entry.status;
      let job = this.jobs.get(abs);
      if (!job) {
        job = this.enqueue(abs, true);
      } else if (job.state === "queued" && !job.priority) {
        const at = this.normalQueue.indexOf(job);
        if (at !== -1) this.normalQueue.splice(at, 1);
        job.priority = true;
        this.priorityQueue.push(job);
      }
      this.pump();
      return await this.race(job.promise, this.softTimeoutMs);
    } catch {
      return "missing";
    }
  }

  /** Waits for the given paths to settle, or for the budget, whichever is
   *  first. A path that does not settle in time stays queued and lands later. */
  async prefetch(abs: readonly string[], budgetMs: number): Promise<void> {
    try {
      const waits: Promise<unknown>[] = [];
      for (const key of abs) {
        this.request(key);
        const job = this.jobs.get(key);
        if (job) waits.push(job.promise);
      }
      if (waits.length === 0) return;
      await this.race(Promise.all(waits), budgetMs);
    } catch {
      // Prefetch only warms the cache; the caller proceeds with what it has.
    }
  }

  onChange(listener: (abs: string, status: PathStatus) => void): () => void {
    this.changeListeners.add(listener);
    return () => {
      this.changeListeners.delete(listener);
    };
  }

  onDrain(listener: () => void): () => void {
    this.drainListeners.add(listener);
    return () => {
      this.drainListeners.delete(listener);
    };
  }

  private race<T>(promise: Promise<T>, ms: number): Promise<T | "missing"> {
    return new Promise((resolve) => {
      const handle = this.timer(() => resolve("missing"), ms);
      promise.then(
        (value) => {
          handle.cancel();
          resolve(value);
        },
        () => {
          handle.cancel();
          resolve("missing");
        },
      );
    });
  }

  private ttlFor(status: PathStatus): number {
    return status === "file" || status === "dir" ? this.positiveTtlMs : this.negativeTtlMs;
  }

  private isFresh(entry: Entry, maxAgeMs: number): boolean {
    return this.now() - entry.at < Math.min(maxAgeMs, this.ttlFor(entry.status));
  }

  private enqueue(key: string, priority: boolean): Job {
    let settle!: (status: PathStatus) => void;
    const promise = new Promise<PathStatus>((resolve) => {
      settle = resolve;
    });
    const job: Job = { key, state: "queued", priority, timedOut: false, settle, promise };
    this.jobs.set(key, job);
    (priority ? this.priorityQueue : this.normalQueue).push(job);
    return job;
  }

  private pump(): void {
    while (this.running < this.maxInFlight) {
      const job = this.priorityQueue.shift() ?? this.normalQueue.shift();
      if (!job) break;
      this.start(job);
    }
    if (this.droppedSinceDrain && this.priorityQueue.length === 0 && this.normalQueue.length === 0) {
      this.droppedSinceDrain = false;
      for (const listener of [...this.drainListeners]) {
        try {
          listener();
        } catch {
          // One listener's failure must not starve the others or the pool.
        }
      }
    }
  }

  private start(job: Job): void {
    job.state = "running";
    this.running++;
    job.timer = this.timer(() => this.timeOut(job), this.softTimeoutMs);
    this.vetAndStat(job.key).then(
      (status) => this.finish(job, status),
      () => this.finish(job, "missing"),
    );
  }

  private timeOut(job: Job): void {
    job.timedOut = true;
    this.commit(job.key, "missing");
    job.settle("missing");
  }

  private finish(job: Job, status: PathStatus): void {
    job.timer?.cancel();
    this.running--;
    if (this.jobs.get(job.key) === job) this.jobs.delete(job.key);
    this.commit(job.key, status);
    job.settle(status);
    this.pump();
  }

  private commit(key: string, status: PathStatus): void {
    const previous = this.entries.get(key)?.status;
    this.entries.delete(key);
    this.entries.set(key, { status, at: this.now() });
    this.evict(this.entries, this.maxEntries);
    if (previous === status) return;
    for (const listener of [...this.changeListeners]) {
      try {
        listener(key, status);
      } catch {
        // See pump(): a listener must never break the cache.
      }
    }
  }

  private evict(map: Map<string, unknown>, max: number): void {
    while (map.size > max) {
      const oldest = map.keys().next();
      if (oldest.done) break;
      map.delete(oldest.value);
    }
  }

  /** True for a path the OS must never be asked about: a shape that opens a
   *  network session, a non-local volume, or an autofs root. Applied to every
   *  directory the walk below actually stands in, not only the printed path,
   *  because a link can lead anywhere. */
  private refusesReal(path: string): boolean {
    if (isRefusedPathShape(path, this.platform)) return true;
    // An autofs mount contacts the host named in the path, with no click. The
    // default macOS volume ignores case, so `/NET` reaches the same mount.
    if (this.platform === "win32") return !this.localVolume(path);
    return AUTOFS_ROOT.test(path);
  }

  /** Walks `abs` the way the OS does, expanding each link in place and keeping
   *  `real` as the directory actually reached. Resolving a link's `..` or a
   *  later component against the printed path instead would vet one tree while
   *  the final stat lands in another. */
  private async vetAndStat(abs: string): Promise<PathStatus> {
    if (this.refusesReal(abs)) return "refused";

    const win = this.platform === "win32";
    const pathApi = win ? win32 : posix;
    const split = (text: string): string[] => text.split(win ? /[\\/]+/ : /\/+/).filter(Boolean);
    const root = pathApi.parse(abs).root;
    if (root === "") return "refused";
    const parts = split(abs.slice(root.length));
    // Candidates arrive resolved; a dot segment here would let a link be
    // walked around instead of through.
    if (parts.some((p) => p === "." || p === "..")) return "refused";

    let real = root;
    let followed = 0;
    for (let steps = 0; parts.length > 0; steps++) {
      // Every link adds components, so the walk is bounded by its total length
      // as well as by the number of links.
      if (steps >= MAX_WALK_STEPS) return "refused";
      const part = parts.shift()!;
      if (part === ".") continue;
      if (part === "..") {
        real = pathApi.dirname(real);
        if (this.refusesReal(real)) return "refused";
        continue;
      }
      const candidate = real.endsWith(pathApi.sep) ? real + part : real + pathApi.sep + part;
      if (this.refusesReal(candidate)) return "refused";
      const component = await this.component(candidate);
      if (component.kind === "missing") return "missing";
      if (component.kind === "plain") {
        real = candidate;
        continue;
      }

      if (++followed > MAX_LINKS_PER_CHECK) return "refused";
      const target = component.target;
      if (isRefusedPathShape(target, this.platform)) return "refused";
      const targetRoot = pathApi.parse(target).root;
      if (targetRoot !== "") {
        // A rooted target without a drive keeps the drive it was found on.
        real = win && !/^[A-Za-z]:/.test(targetRoot) ? pathApi.parse(real).root.slice(0, 2) + targetRoot : targetRoot;
        if (this.refusesReal(real)) return "refused";
      }
      parts.unshift(...split(target.slice(targetRoot.length)));
    }

    try {
      const final = await this.fs.stat(real);
      if (final.isFile()) return "file";
      if (final.isDirectory()) return "dir";
    } catch {
      // Falls through to missing.
    }
    return "missing";
  }

  private component(path: string): Promise<Component> {
    const hit = this.components.get(path);
    if (hit) {
      const ttl = hit.value.kind === "missing" ? this.negativeTtlMs : this.positiveTtlMs;
      if (this.now() - hit.at < ttl) return Promise.resolve(hit.value);
    }
    const pending = this.componentsInFlight.get(path);
    if (pending) return pending;
    const lookup = this.lookupComponent(path).then((value) => {
      this.componentsInFlight.delete(path);
      this.components.delete(path);
      this.components.set(path, { value, at: this.now() });
      this.evict(this.components, this.maxEntries);
      return value;
    });
    this.componentsInFlight.set(path, lookup);
    return lookup;
  }

  private async lookupComponent(path: string): Promise<Component> {
    try {
      const stats = await this.fs.lstat(path);
      if (!stats.isSymbolicLink()) return { kind: "plain" };
      return { kind: "link", target: await this.fs.readlink(path) };
    } catch {
      return { kind: "missing" };
    }
  }
}

let shared: PathStatCache | undefined;

/** One process-wide cache, so every terminal and every click draws on the same
 *  worker pool and the same results. */
export function sharedPathStatCache(): PathStatCache {
  return (shared ??= new PathStatCache());
}
