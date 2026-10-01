import { lstat, readlink, stat } from "node:fs/promises";
import { posix, win32 } from "node:path";
import { hasDriveLetterAt, startsWithDoubleSeparator, startsWithIgnoreCase } from "./chars";
import { isRefusedPathShape } from "./grammar";
import { isLocalVolume as defaultIsLocalVolume, uncShareOf } from "./win32-volume";

export type PathStatus = "file" | "dir" | "missing" | "refused";

/** What a click is told. `timeout` is not an answer about the path: the stat is
 *  still running, so the file may well exist. */
export type ResolveAnswer = PathStatus | "timeout";

export interface ResolvedPath {
  status: ResolveAnswer;
  /** The directory entry the walk actually reached, links expanded; set only
   *  for a `file` or `dir`. Containment is judged on this, not on the printed
   *  path, because a link inside a checkout can lead anywhere. */
  real?: string;
}

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
function isAutofsRoot(path: string): boolean {
  if (path[0] !== "/") return false;
  for (const root of ["net", "network"]) {
    const end = 1 + root.length;
    if (startsWithIgnoreCase(path, root, 1) && (path.length === end || path[end] === "/")) return true;
  }
  return false;
}

/** Non-empty components of `text`; `\` separates only on Windows, where a
 *  POSIX name may legitimately contain it. */
function splitComponents(text: string, win: boolean): string[] {
  const out: string[] = [];
  let start = 0;
  for (let i = 0; i <= text.length; i++) {
    if (i < text.length && !(text[i] === "/" || (win && text[i] === "\\"))) continue;
    if (i > start) out.push(text.slice(start, i));
    start = i + 1;
  }
  return out;
}

const defaultFs: LinkFs = { lstat, stat, readlink };

export const defaultTimer = (fn: () => void, ms: number): { cancel(): void } => {
  const handle = setTimeout(fn, ms);
  handle.unref?.();
  return { cancel: () => clearTimeout(handle) };
};

interface Entry {
  status: PathStatus;
  at: number;
  real?: string;
  /** Written when the soft deadline passed, not when the stat answered. It frees
   *  detection's waiters but says nothing about the path, so a click must not
   *  take it as an answer. */
  timedOut?: boolean;
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
  settle: (result: ResolvedPath) => void;
  promise: Promise<ResolvedPath>;
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

  /** Marks the checkout root's volume as allowed even when it is remote: the
   *  bridge already works there, so refusing it would unlink the whole tree.
   *  A drive is trusted whole; a UNC root trusts its own share and no other. */
  trustVolume(root: string): void {
    if (hasDriveLetterAt(root)) {
      this.trusted.add(root[0]!.toUpperCase());
      return;
    }
    if (this.platform !== "win32") return;
    const share = uncShareOf(root);
    if (share !== undefined) this.trusted.add(share.key);
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

  /** The real path of the last answer for `abs`, whatever its age. */
  peekReal(abs: string): string | undefined {
    try {
      return this.entries.get(abs)?.real;
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
  async resolveFresh(abs: string, maxAgeMs: number): Promise<ResolveAnswer> {
    return (await this.resolveReal(abs, maxAgeMs)).status;
  }

  /** `resolveFresh` plus the real path the answer was found at. A stat that
   *  outlives the soft deadline answers `timeout`, never `missing`: the file
   *  may exist and the caller must be able to say it does not know. */
  async resolveReal(abs: string, maxAgeMs: number): Promise<ResolvedPath> {
    try {
      const entry = this.entries.get(abs);
      if (entry && !entry.timedOut && this.isFresh(entry, maxAgeMs)) return { status: entry.status, real: entry.real };
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
      return await this.race(job.promise, this.softTimeoutMs, { status: "timeout" });
    } catch {
      return { status: "missing" };
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
      await this.race(Promise.all(waits), budgetMs, undefined);
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

  private race<T, L>(promise: Promise<T>, ms: number, onLate: L): Promise<T | L> {
    return new Promise((resolve) => {
      const handle = this.timer(() => resolve(onLate), ms);
      promise.then(
        (value) => {
          handle.cancel();
          resolve(value);
        },
        () => {
          handle.cancel();
          resolve(onLate);
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
    let settle!: (result: ResolvedPath) => void;
    const promise = new Promise<ResolvedPath>((resolve) => {
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
      (result) => this.finish(job, result),
      () => this.finish(job, { status: "missing" }),
    );
  }

  /** Detection's waiters get a negative so a screen stops waiting on a hung
   *  share; a click is told `timeout` instead, which is the honest answer. */
  private timeOut(job: Job): void {
    job.timedOut = true;
    this.commit(job.key, "missing", undefined, true);
    job.settle({ status: "timeout" });
  }

  private finish(job: Job, result: { status: PathStatus; real?: string }): void {
    job.timer?.cancel();
    this.running--;
    if (this.jobs.get(job.key) === job) this.jobs.delete(job.key);
    this.commit(job.key, result.status, result.real);
    job.settle(result);
    this.pump();
  }

  private commit(key: string, status: PathStatus, real?: string, timedOut?: boolean): void {
    const previous = this.entries.get(key)?.status;
    this.entries.delete(key);
    this.entries.set(key, {
      status,
      at: this.now(),
      ...(real !== undefined ? { real } : {}),
      ...(timedOut ? { timedOut } : {}),
    });
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

  /** `isRefusedPathShape`, except that the share a UNC checkout root lives on
   *  is the root's own volume: the bridge already works there, so only what
   *  follows the share is judged. Any other UNC path keeps the refusal. */
  private shapeRefused(path: string): boolean {
    if (this.platform === "win32") {
      const share = uncShareOf(path);
      if (share !== undefined && this.trusted.has(share.key)) {
        return isRefusedPathShape(path.slice(share.end), this.platform);
      }
    }
    return isRefusedPathShape(path, this.platform);
  }

  /** True for a path the OS must never be asked about: a shape that opens a
   *  network session, a non-local volume, or an autofs root. Applied to every
   *  directory the walk below actually stands in, not only the printed path,
   *  because a link can lead anywhere. */
  private refusesReal(path: string): boolean {
    if (this.shapeRefused(path)) return true;
    // An autofs mount contacts the host named in the path, with no click. The
    // default macOS volume ignores case, so `/NET` reaches the same mount.
    if (this.platform === "win32") return !this.localVolume(path);
    return isAutofsRoot(path);
  }

  /** Walks `abs` the way the OS does, expanding each link in place and keeping
   *  `real` as the directory actually reached. Resolving a link's `..` or a
   *  later component against the printed path instead would vet one tree while
   *  the final stat lands in another. */
  private async vetAndStat(abs: string): Promise<{ status: PathStatus; real?: string }> {
    if (this.refusesReal(abs)) return { status: "refused" };

    const win = this.platform === "win32";
    const pathApi = win ? win32 : posix;
    const split = (text: string): string[] => splitComponents(text, win);
    const root = pathApi.parse(abs).root;
    if (root === "") return { status: "refused" };
    const parts = split(abs.slice(root.length));
    // Candidates arrive resolved; a dot segment here would let a link be
    // walked around instead of through.
    if (parts.some((p) => p === "." || p === "..")) return { status: "refused" };

    let real = root;
    let followed = 0;
    for (let steps = 0; parts.length > 0; steps++) {
      // Every link adds components, so the walk is bounded by its total length
      // as well as by the number of links.
      if (steps >= MAX_WALK_STEPS) return { status: "refused" };
      const part = parts.shift()!;
      if (part === ".") continue;
      if (part === "..") {
        real = pathApi.dirname(real);
        if (this.refusesReal(real)) return { status: "refused" };
        continue;
      }
      const candidate = real.endsWith(pathApi.sep) ? real + part : real + pathApi.sep + part;
      if (this.refusesReal(candidate)) return { status: "refused" };
      const component = await this.component(candidate);
      if (component.kind === "missing") return { status: "missing" };
      if (component.kind === "plain") {
        real = candidate;
        continue;
      }

      if (++followed > MAX_LINKS_PER_CHECK) return { status: "refused" };
      const target = component.target;
      if (this.shapeRefused(target)) return { status: "refused" };
      const targetRoot = pathApi.parse(target).root;
      if (targetRoot !== "") {
        real = win ? this.windowsTargetRoot(real, targetRoot) : targetRoot;
        if (this.refusesReal(real)) return { status: "refused" };
      }
      parts.unshift(...split(target.slice(targetRoot.length)));
    }

    try {
      const final = await this.fs.stat(real);
      if (final.isFile()) return { status: "file", real };
      if (final.isDirectory()) return { status: "dir", real };
    } catch {
      // Falls through to missing.
    }
    return { status: "missing" };
  }

  /** Where a link's rooted target starts. A target with a drive or a share
   *  names its own volume; one without keeps the volume it was found on. */
  private windowsTargetRoot(real: string, targetRoot: string): string {
    if (hasDriveLetterAt(targetRoot) || startsWithDoubleSeparator(targetRoot)) return targetRoot;
    const volume = win32.parse(real).root;
    return volume.slice(0, volume.length - 1) + targetRoot;
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
