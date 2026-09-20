import chokidar, { type FSWatcher } from "chokidar";
import { relative, resolve, sep, extname, basename, join, isAbsolute, dirname } from "node:path";
import { statSync, watch as fsWatch, type FSWatcher as NodeFSWatcher } from "node:fs";
import { logger } from "./logger";
const log = logger.child({ component: "file-watcher" });
import { createMessage, type AbMessage } from "./protocol";
import {
  loadIgnoreRules,
  readFile,
  externalSafeImageMime,
  listDirectory,
  listDirectoryBatch,
  type FileTreeNode,
  type DirectoryListing,
} from "./file-tree";
import type { ConnState } from "./conn-state";
import type { ClientKey } from "./message-bus";
export interface ProjectInfo {
  path: string;
  id: string;
  name?: string;
}

/** Coalescing window for `tree:update`. [scheduleBatch] throttles rather than
 *  debounces — a later change does not push the timer back — so while churn
 *  continues the watcher emits exactly one frame per window, indefinitely. At
 *  100 ms that is ~6 frames/s of ~1.9 KB each, and a remote app pays every one:
 *  one measured 245 s agent run put 2.76 MB of deltas on the wire, 22% of that
 *  whole session's download, and each frame is also a tree merge on the
 *  consumer's UI thread.
 *
 *  So the window widens once the churn proves sustained. Widening costs far
 *  less than it saves because [PendingChanges] is keyed by path: a longer
 *  window folds repeated writes to the same file into ONE entry, so the frame
 *  grows much more slowly than the rate falls. An isolated save keeps the
 *  narrow window — that is the case a user is watching for. */
const IDLE_WINDOW_MS = 100;
const BUSY_WINDOW_MS = 750;
/** A change arriving this soon after a flush means the churn never paused. */
const CHURN_GRACE_MS = 150;
/** Uninterrupted windows before widening. Two adjacent saves are not a storm;
 *  a real one runs for minutes, so it widens almost immediately anyway. */
const CHURN_RUN_TO_WIDEN = 3;

/** Stand-in mtime for a swept directory that could not be stat'd — see
 *  [FileWatcher.revalidateSubscribedDirs]. Distinct from every real mtime, so
 *  a directory that disappears reports once and then stays quiet. */
const MISSING_DIR_MTIME = -1;

/** Hand-validated bounds for file:tree:subscribe's `paths` — parseMessageFast
 *  never runs this frame's Zod schema on the wire (see the comment above
 *  FileTreeRootRequestMessage in protocol.ts), so a real inbound `paths` can
 *  be anything the sender claims: not an array, non-string entries, tens of
 *  thousands of them, or one megabytes long. Mirrors MAX_LOG_PAGE's reasoning
 *  in git-log.ts. */
const MAX_SUBSCRIBED_PATHS = 512;
const MAX_SUBSCRIBED_PATH_LEN = 4096;

/** dirname("foo.ts") is ".", not the wire contract's "" for the root. Every
 *  D6 filter comparison goes through this rather than a bare `dirname` call,
 *  or every root-level change is silently dropped from every subscription. */
function dirnameKeyOf(p: string): string {
  const d = dirname(p);
  return d === "." ? "" : d;
}

/** Normalises one subscribed directory into the exact form [dirnameKeyOf]
 *  produces, so a path sent with a trailing slash or a stray backslash still
 *  lines up with what a delta reports — proven against flushBatch, not
 *  assumed: see the D6 filter below. `paths` is hand-validated (see
 *  [MAX_SUBSCRIBED_PATHS]), so this also never throws on a hostile string. */
function normalizeSubscribedDir(raw: string): string {
  const forwardSlash = raw.replace(/\\/g, "/");
  const noTrailingSlash =
    forwardSlash.length > 1 && forwardSlash.endsWith("/")
      ? forwardSlash.slice(0, -1)
      : forwardSlash;
  // "./a" folds to "a" for the same reason "." folds to the root: a relative
  // prefix a delta path never carries would otherwise be stored as a key
  // nothing can ever match, silently subscribing that client to nothing.
  const noDotPrefix = noTrailingSlash.startsWith("./")
    ? noTrailingSlash.slice(2)
    : noTrailingSlash;
  return noDotPrefix === "." || noDotPrefix === "/" ? "" : noDotPrefix;
}

/** The watcher's one outbound hook: a plain send, with no send-mode flags.
 *  Nothing this class emits needs to bypass the bus's payload-equality dedup —
 *  every frame it sends carries a `seq` that has already been bumped, so
 *  consecutive sends differ on their own. See [flushBatch]. */
type SendTreeMessage = (msg: AbMessage) => void;

type PendingChanges = {
  added: Map<string, FileTreeNode>;
  modified: Map<string, FileTreeNode>;
  removed: Set<string>;
};

export class FileWatcher {
  private projectRoot: string;
  private projectId: string;
  private sendMessage: SendTreeMessage;
  private connState: ConnState;
  private watcher: FSWatcher | null = null;
  private onFilesChanged?: () => void;
  private nativeWatcher: NodeFSWatcher | null = null;
  private ig: ReturnType<typeof loadIgnoreRules>;
  /** The show-everything listing variant, built on first use. Held here and
   *  not in a module-level cache so it dies with the watcher: a checkout's
   *  rules must not outlive the worktree they describe, and a rebuilt watcher
   *  is the only thing that picks up a `.gitignore` edit. */
  private igShowAll: ReturnType<typeof loadIgnoreRules> | null = null;
  private pending: PendingChanges = {
    added: new Map(),
    modified: new Map(),
    removed: new Set(),
  };
  private debounceTimer: ReturnType<typeof setTimeout> | null = null;
  private lastFlushAt = 0;
  /** Consecutive windows that were followed straight away by another change —
   *  see [CHURN_RUN_TO_WIDEN]. */
  private churnRun = 0;
  /** Set when the native recursive watcher reports a change with no path —
   *  see [startNativeRecursiveWatch] — so [flushBatch] falls back to a full
   *  resync instead of sending an incremental batch it knows is incomplete. */
  private needsFullResync = false;
  /** Directory paths one client currently has open, for the D6 delta filter
   *  in [flushBatch]. An entry — even an empty Set, which is the wire
   *  contract's unsubscribe — means that client has STATED what it wants and
   *  counts toward "every attached client subscribed" in [everySubscribed];
   *  a client with no entry is unaccounted for and turns the filter off for
   *  everyone (D6), which is where an unreadable frame lands too (see
   *  [setSubscription]). Cleared wholesale in [stop] — the checkout-teardown
   *  half of keeping the union from growing forever; [dropSubscription] is
   *  the peer-disconnect half, driven from agent-core.ts's `noteClientGone`,
   *  and [everySubscribed] reconciles against the live roster for the
   *  departures that hook does not see. */
  private subscriptions = new Map<ClientKey, Set<string>>();
  /** Last-seen mtime of each directory in the subscribed union, for
   *  [revalidateSubscribedDirs]. Keyed exactly as [subscriptions] is — "" is
   *  the root. Rebuilt from the union on every sweep so a collapsed
   *  directory's entry leaves with it, and cleared with the subscriptions in
   *  [stop]. */
  private dirMtimes = new Map<string, number>();
  /** Core-wide roster of currently attached clients, injected because this
   *  watcher is per-checkout and the roster is not (agent-core.ts's
   *  `attachedClients`). Never derived from `this.subscriptions`'s own size
   *  — a client that attached and sent nothing would then be invisible
   *  rather than unaccounted-for, which is the one case the D6 filter most
   *  needs to fail open on. */
  private attachedClients?: () => ClientKey[];

  constructor(
    project: ProjectInfo,
    sendMessage: SendTreeMessage,
    connState: ConnState,
    onFilesChanged?: () => void,
    attachedClients?: () => ClientKey[],
  ) {
    this.projectRoot = project.path;
    this.projectId = project.id;
    this.sendMessage = sendMessage;
    this.connState = connState;
    this.onFilesChanged = onFilesChanged;
    this.attachedClients = attachedClients;
    this.ig = loadIgnoreRules(this.projectRoot, []);
  }

  /** REPLACES clientKey's whole subscribed set — file:tree:subscribe is
   *  idempotent by design (see the wire contract in protocol.ts), so a
   *  reconnect hydrator can just resend it; an empty array unsubscribes with
   *  no separate verb.
   *
   *  Hand-validated: parseMessageFast (protocol.ts) checks the frame's TYPE
   *  alone, so `paths` reaches here exactly as the sender wrote it — see
   *  [MAX_SUBSCRIBED_PATHS]'s comment. None of that may throw: this runs on
   *  the bus dispatch path with no caller to catch it, and a throw here would
   *  take the whole core down. */
  setSubscription(clientKey: ClientKey, paths: unknown): void {
    if (!Array.isArray(paths)) {
      // UNACCOUNTED-for, not subscribed-to-nothing. A frame whose `paths`
      // cannot be read is the strongest available statement that this
      // client's intent is unknown, and D6's answer to an unknown client is
      // to stop filtering for everyone. Storing the empty Set instead would
      // count the client as fully accounted for AND contributing nothing,
      // narrowing the union to the root for every device on the bus.
      this.subscriptions.delete(clientKey);
      log.warn(
        "file:tree:subscribe from %s carried a non-array `paths` — leaving it unsubscribed (project %s)",
        clientKey,
        this.projectId,
      );
      return;
    }
    const dirs = new Set<string>();
    let dropped = 0;
    for (let i = 0; i < paths.length; i++) {
      if (dirs.size >= MAX_SUBSCRIBED_PATHS) {
        dropped += paths.length - i;
        break;
      }
      const p = paths[i];
      if (typeof p !== "string" || p.length > MAX_SUBSCRIBED_PATH_LEN) {
        dropped++;
        continue;
      }
      dirs.add(normalizeSubscribedDir(p));
    }
    if (paths.length > 0 && dirs.size === 0) {
      // Same reasoning as the non-array case: the sender asked for something
      // and none of it survived, which is a broken encoder rather than an
      // unsubscribe. An empty ARRAY is the unsubscribe, and it lands below.
      this.subscriptions.delete(clientKey);
      log.warn(
        "file:tree:subscribe from %s carried %d unusable paths and nothing else — leaving it unsubscribed (project %s)",
        clientKey,
        paths.length,
        this.projectId,
      );
      return;
    }
    if (dropped > 0) {
      // A truncated subscription reads downstream as "the tree stopped
      // updating there", with nothing on the wire to tell it apart from a
      // client that simply asked for less.
      log.warn(
        "file:tree:subscribe from %s: dropped %d of %d paths (project %s)",
        clientKey,
        dropped,
        paths.length,
        this.projectId,
      );
    }
    this.subscriptions.set(clientKey, dirs);
  }

  /** The peer-disconnect half of Trap 3
   *  (docs/file-tree-lazy-expansion-spec.md) — the checkout-teardown half is
   *  [stop] clearing the whole map. */
  dropSubscription(clientKey: ClientKey): void {
    this.subscriptions.delete(clientKey);
  }

  /** [dirPath] in the [dirnameKeyOf] form. The root is unconditionally
   *  subscribed (D6: "∪ {\"\"}").
   *
   *  Closure under removal is ENFORCED at the removal filter below rather
   *  than inherited from "you cannot subscribe to a child without its
   *  parent": the app's collapse clears `childrenLoaded` on the collapsed
   *  node alone, so it can legitimately hold `a/b` with no `a`, and then a
   *  removal of `a/b` keys on the unsubscribed `a`. */
  isSubscribed(dirPath: string): boolean {
    if (dirPath === "") return true;
    for (const dirs of this.subscriptions.values()) {
      if (dirs.has(dirPath)) return true;
    }
    return false;
  }

  /** Whether every attached client has named the directories it wants.
   *
   *  Fail-OPEN, and the direction is the whole point: no client accounted for
   *  at all — a bare watcher under test, or a core whose transport has named
   *  no client yet ([attachedClients] in agent-core.ts is the roster) — means
   *  nobody has vouched for a narrower union, so the filter stays off rather
   *  than risk dropping a delta a silent client still needed. Returning true
   *  for an empty roster reads tidier and silently starves every client that
   *  never subscribed. */
  private everySubscribed(): boolean {
    const roster = this.attachedClients?.() ?? [];
    if (roster.length === 0) return false;
    // A relay socket close tears down no per-device session
    // (relay-client.ts's `cleanup` leaves `this.sessions` standing), so
    // `noteClientGone` does NOT fire per device on the common disconnect
    // path and a departed device's directories would otherwise widen this
    // union for the life of the core — Trap 3. The roster IS re-asked on
    // every flush, so reconciling against it here is the one sweep that
    // always runs, whatever the transport forgot to call.
    if (this.subscriptions.size > 0) {
      const live = new Set(roster);
      for (const key of this.subscriptions.keys()) {
        if (!live.has(key)) this.subscriptions.delete(key);
      }
    }
    return roster.every((c) => this.subscriptions.has(c));
  }

  /** Every directory some client has open, plus the root — the set whose
   *  CONTENTS a client is currently rendering, and so the only set where a
   *  missed change is visible. */
  private subscribedUnion(): Set<string> {
    const union = new Set<string>([""]);
    for (const dirs of this.subscriptions.values()) {
      for (const dir of dirs) union.add(dir);
    }
    return union;
  }

  /** Record a directory's mtime as of a moment its contents were just
   *  reported truthfully — a delta this watcher flushed, or a listing it
   *  served. Without it [revalidateSubscribedDirs] cannot tell a change this
   *  watcher DELIVERED from one it lost: an ordinary save moves its
   *  directory's mtime too, so every save would read as a missed event and
   *  invalidate the whole tree, re-listing every open directory — the traffic
   *  the on-demand tree exists to avoid. */
  private noteDirFresh(dirKey: string): void {
    const abs = dirKey === "" ? this.projectRoot : join(this.projectRoot, dirKey);
    try {
      this.dirMtimes.set(dirKey, statSync(abs).mtimeMs);
    } catch {
      this.dirMtimes.set(dirKey, MISSING_DIR_MTIME);
    }
  }

  /**
   * Ask the DISK whether any directory a client has open changed behind the
   * watcher's back, and drive the same recovery an OS overflow report drives.
   *
   * A recursive watch is lossy by contract on Windows — ReadDirectoryChangesW
   * discards events when its kernel buffer overflows — and the overflow report
   * that exists to say so cannot be relied on either: one host was measured
   * losing every event below the checkout root while reporting no overflow at
   * all. Nothing pull-based recovers from that. The app's own focus-resume
   * re-pull claims a `sinceSeq`, and a lost event never moved `seq`, so the
   * bridge answers `file:tree:unchanged` and CONFIRMS the stale tree. Only the
   * disk knows, and only the bridge can ask it.
   *
   * One `stat` per open directory, never a readdir: a directory's mtime moves
   * when an entry is added, removed or renamed — exactly the changes that
   * alter what a client draws for it — and deliberately NOT when a file's
   * contents change, which moves no row in the tree but would otherwise make
   * every save look like a missed event. A change inside a CHILD directory
   * moves only that child's mtime, which is why the union is what is swept: a
   * directory nobody has expanded renders nothing that could be stale.
   *
   * Cheap enough to ride the git backstop tick (agent-core.ts) rather than own
   * a timer: the union is capped at MAX_SUBSCRIBED_PATHS per client and is a
   * handful of directories in practice.
   */
  revalidateSubscribedDirs(): void {
    // Nothing attached, nothing to repair — a bare watcher under test and a
    // headless core must not pay for a sweep no client reads.
    if ((this.attachedClients?.() ?? []).length === 0) return;

    let changed = false;
    const next = new Map<string, number>();
    for (const dir of this.subscribedUnion()) {
      // D14 parity: this sweep's view is what the WATCHER should have seen,
      // not what the client rendered. A client browsing in show-everything
      // mode can have `node_modules` expanded and subscribed, and sweeping it
      // would invalidate the tree on every `npm install` write — the exact
      // churn the unconditional ignore prune keeps out.
      if (dir !== "" && this.ig.ignores(dir, true)) continue;
      const abs = dir === "" ? this.projectRoot : join(this.projectRoot, dir);
      let mtime: number;
      try {
        mtime = statSync(abs).mtimeMs;
      } catch {
        mtime = MISSING_DIR_MTIME;
      }
      const prev = this.dirMtimes.get(dir);
      // First sighting is RECORDED, not reported: the sweep that follows a
      // client expanding a tree would otherwise invalidate it wholesale.
      if (prev !== undefined && prev !== mtime) changed = true;
      next.set(dir, mtime);
    }
    this.dirMtimes = next;
    if (!changed) return;

    log.debug(
      "tree revalidation for %s — a subscribed directory moved with no watcher event",
      this.projectId,
    );
    // The same recovery the null-filename overflow branch drives: flushBatch
    // bumps `seq` and sends `file:tree:invalidated`, and the app re-lists the
    // root and everything it has expanded. Deliberately not a synthesized
    // delta — this knows THAT a directory moved, never what within it.
    this.needsFullResync = true;
    this.scheduleBatch();
  }

  /** The revision a listing would stamp, without touching disk — so a
   *  `sinceSeq` request that turns out to be current costs no readdir. */
  currentSeq(): number {
    return this.connState.fileSeq(this.projectRoot);
  }

  /** Ignore rules for a listing request. This is a listing-only distinction —
   *  the watcher's own ignore prune (`handleNativeEvent`, chokidar's
   *  `ignored`) never consults `includeIgnored` and must not start to (D14 in
   *  docs/file-tree-lazy-expansion-spec.md). */
  private ignoreRulesFor(includeIgnored: boolean): ReturnType<typeof loadIgnoreRules> {
    if (!includeIgnored) return this.ig;
    this.igShowAll ??= loadIgnoreRules(this.projectRoot, [], { gitignore: false });
    return this.igShowAll;
  }

  /** Depth-1 listing of the checkout root, for `file:tree:root:request`.
   *
   *  `includeIgnored` selects the show-all rules AND, in the same branch,
   *  supplies `this.ig` (the git-respecting rules) as the second verdict
   *  that marks each entry `ignored: true`. The `false` path passes no
   *  second rule set — nothing ignored can appear there, so nothing needs
   *  checking. */
  getRootListing(includeIgnored: boolean): DirectoryListing {
    // Before the read, never after: the other order can record an mtime newer
    // than the listing it accompanies, and a change landing in between would
    // then be hidden for good rather than costing one redundant sweep hit.
    this.noteDirFresh("");
    return listDirectory(
      "",
      this.projectRoot,
      this.ignoreRulesFor(includeIgnored),
      undefined,
      includeIgnored ? this.ig : undefined,
    );
  }

  /** Depth-1 listings for a batch of paths, for `file:tree:children:request`.
   *  Fair-share budget allocation across the batch is `listDirectoryBatch`'s
   *  job — see file-tree.ts. Same `ignored`-marking rule as [getRootListing]. */
  getChildListings(paths: string[], includeIgnored: boolean): DirectoryListing[] {
    // See [getRootListing] for why this precedes the read.
    for (const path of paths) this.noteDirFresh(path);
    return listDirectoryBatch(
      paths,
      this.projectRoot,
      this.ignoreRulesFor(includeIgnored),
      undefined,
      includeIgnored ? this.ig : undefined,
    );
  }

  startWatching(): void {
    // chokidar v5 watches each directory with its own non-recursive fs.watch(),
    // and on both macOS and Windows that per-directory call is expensive enough
    // that the walk freezes bun's single JS thread for tens of seconds on a
    // large repo: on macOS every fs.watch() is a distinct libuv FSEventStream,
    // so the create/start/stop storm saturates the CoreServices FSEvents thread
    // and contends the allocator lock; on Windows each opens its own directory
    // handle and ReadDirectoryChangesW subscription. A project open starts one
    // watcher per checkout — the repo plus every managed worktree — so the cost
    // multiplies. Measured on Windows over one repo + five worktrees: ~10.9s of
    // uninterrupted block, against the 2s `project:list` liveness ping in
    // HostController — so the app reaps a HEALTHY host mid-open and the session
    // start that triggered the open dies with "SessionsService disposed".
    // Node's recursive fs.watch uses a SINGLE OS-level subscription regardless
    // of tree size (~15ms for those same six roots), sidestepping the storm.
    // Recursive mode is supported only on macOS and Windows; Linux keeps
    // chokidar (its inotify-per-dir backend doesn't have this cost).
    if (process.platform === "darwin" || process.platform === "win32") {
      this.startNativeRecursiveWatch();
      return;
    }
    this.startChokidarWatch();
  }

  /**
   * Re-read the tree state once the watch is actually armed.
   *
   * A file written between the core booting and this point is seen by NEITHER
   * mechanism: the startup `git status` ran before the file existed, and no
   * watch existed to report it appearing. chokidar widens that window rather
   * than closing it — it reads each directory BEFORE attaching that
   * directory's fs.watch, so a file landing in between is missed by the read
   * (too late) and by the watch (not yet attached), permanently, until
   * something else in that directory moves. What is left is a change the Git
   * view cannot show until the 10s backstop poll comes round — the exact
   * staleness this hook exists to prevent.
   *
   * The refresh behind it reads the DISK, not the watcher's own state, so it
   * recovers whatever the watch never learned about.
   */
  private onWatchArmed(): void {
    this.onFilesChanged?.();
  }

  private startChokidarWatch(): void {
    const ignoredFn = (path: string): boolean => {
      const rel = relative(this.projectRoot, path).replace(/\\/g, "/");
      // Chokidar also asks about the watch target's ANCESTORS while it walks up
      // to attach, and `ignore` throws on a path that escapes the root rather
      // than answering — an unhandled RangeError that takes the watcher down.
      // The project's ignore rules cannot speak about anything outside it, so
      // the honest answer for the root itself and for anything above it is "not
      // ignored".
      if (!rel || rel === "." || rel === ".." || rel.startsWith("../")) return false;
      return this.ig.ignores(rel);
    };

    this.watcher = chokidar.watch(this.projectRoot, {
      ignoreInitial: true,
      followSymlinks: false,
      // Bounds chokidar's own cost on Linux, which is the only platform that
      // reaches this branch. On-demand listings have no depth cap, so a client
      // that expands past level 10 sees that directory only when it re-lists
      // it — the native recursive watch macOS and Windows use has no such
      // limit. (This used to be kept equal to file-tree.ts's MAX_DEPTH, which
      // retired with the whole-tree walk.)
      depth: 10,
      ignored: ignoredFn,
    });

    this.watcher
      .on("add", (filePath) => this.onFileAdded(filePath))
      .on("change", (filePath) => this.onFileModified(filePath))
      .on("unlink", (filePath) => this.onFileRemoved(filePath))
      .on("addDir", (dirPath) => this.onDirAdded(dirPath))
      .on("unlinkDir", (dirPath) => this.onFileRemoved(dirPath))
      .on("error", (err) => log.error("File watcher error: %s", err))
      // On `ready`, not on the constructor's return: that is the first moment
      // every directory's watch is attached, and so the first moment nothing
      // more can be silently missed.
      .on("ready", () => this.onWatchArmed());

    log.info("File watcher started for %s", this.projectRoot);
  }

  private startNativeRecursiveWatch(): void {
    try {
      this.nativeWatcher = fsWatch(
        this.projectRoot,
        { recursive: true, persistent: true },
        (_event, filename) => this.handleNativeEvent(filename),
      );
      this.nativeWatcher.on("error", (err) =>
        log.error("File watcher error: %s", err),
      );
      log.info(
        "File watcher started (native recursive) for %s",
        this.projectRoot,
      );
      this.onWatchArmed();
    } catch (err) {
      log.error(
        "native recursive watch failed (%s); falling back to chokidar",
        err,
      );
      this.startChokidarWatch();
    }
  }

  /**
   * One event off the native recursive watcher.
   *
   * A named method rather than the inline closure it used to be, so the
   * buffer-overflow branch below is reachable from a test — driving it through
   * a real overflow means provoking one from the OS, and the private field it
   * sets can be assigned directly without the branch that sets it ever running.
   */
  handleNativeEvent(filename: string | Buffer | null): void {
    if (filename == null) {
      // Windows' (and reportedly macOS's) recursive fs.watch reports exactly
      // this — a change with no path — when its internal notification buffer
      // overflows: a burst of filesystem activity (a new directory landing
      // with many files in one go is enough, measured on Windows) drops the
      // per-file events instead of queuing them, rather than raising an error.
      // There is no path to diff here, so treat it as "something changed,
      // scope unknown" and let flushBatch fall back to a full resync —
      // otherwise some of the affected files never appear until the app's own
      // pull-to-refresh forces a rebuild from disk.
      this.needsFullResync = true;
      this.scheduleBatch();
      return;
    }
    // Usually relative to projectRoot (String() also covers a Buffer if the
    // platform yields one) — but Windows also delivers the ABSOLUTE watched
    // root for events on the directory itself, so re-derive rather than trust
    // it.
    const raw = String(filename);
    const rel = (isAbsolute(raw) ? relative(this.projectRoot, raw) : raw)
      .replace(/\\/g, "/");
    // `ignore` THROWS on a path that isn't root-relative instead of answering,
    // and this runs on a libuv event with no caller to catch it — an unhandled
    // RangeError that takes the watcher down (the chokidar path guards the
    // same way for the same reason). The root itself and anything above it are
    // honestly "not ignored", but there is also nothing under them to report.
    if (!rel || rel === "." || rel === ".." || rel.startsWith("../")) return;
    // The recursive stream sees the whole tree (the OS can't prune at the
    // subscription level); apply the same ignore rules chokidar's `ignored`
    // would, so node_modules/build/etc. churn is dropped here.
    if (this.ig.ignores(rel)) return;
    this.onNativeChange(join(this.projectRoot, rel));
  }

  // Route a raw recursive-watch hit through the existing pending-change maps.
  // The app upserts `added` and `modified` identically, so every still-present
  // path goes through the add path — no separate known-paths set needed.
  private onNativeChange(absPath: string): void {
    let stat;
    try {
      stat = statSync(absPath);
    } catch {
      // Vanished (delete/move-away) — relPath resolved inside onFileRemoved.
      this.onFileRemoved(absPath);
      return;
    }
    if (stat.isDirectory()) {
      this.onDirAdded(absPath);
    } else if (stat.isFile()) {
      this.onFileAdded(absPath);
    }
  }

  handleFileReadRequest(relPath: string): void {
    const result = readFile(this.projectRoot, relPath);
    this.sendMessage(
      createMessage("file:content", {
        projectId: this.projectId,
        path: relPath,
        content: result.content,
        size: result.size,
        encoding: result.encoding ?? "utf8",
        mimeType: result.mimeType,
        error: result.error,
      }),
    );
  }

  /** Resolves a path a terminal program printed (an OSC 8 `file://` hyperlink
   *  target, absolute or already checkout-relative) against this checkout's
   *  root, and replies with the checkout-relative form the app's file tree
   *  understands. The app never learns the checkout's absolute root (see
   *  `docs/architecture.md` — the checkout path never crosses the session
   *  wire), so it cannot make this relative on its own; a null `relPath`
   *  covers both a path from outside this checkout and one that fails to
   *  resolve at all. Mirrors [readFile]'s own traversal guard.
   *
   *  A path OUTSIDE the checkout gets one further check: [externalSafeImageMime]
   *  — an image-generation tool's own output directory is typically outside
   *  any checkout, and before this the app could only refuse such a link
   *  outright. `externalImagePath` carries the absolute path for exactly that
   *  narrow case, gated the same way [readFile] gates the read it enables:
   *  by extension alone, never by content. */
  handleResolvePathRequest(requestId: string, rawPath: string): void {
    const absPath = resolve(this.projectRoot, rawPath);
    const normalizedRoot = resolve(this.projectRoot);
    // Case-folded on Windows, where the comparison is between two strings that
    // came from different places: the root as the host spelled it, and a drive
    // letter as a terminal program printed it. `path.resolve` preserves the
    // case of both, so a `file:///c:/...` hyperlink against a `C:\...` root
    // reads as outside the checkout and the Files tab silently ignores it.
    // `relative()` one method away already folds, so only this test dissents.
    const cmpPath = process.platform === "win32" ? absPath.toLowerCase() : absPath;
    const cmpRoot =
      process.platform === "win32" ? normalizedRoot.toLowerCase() : normalizedRoot;
    const insideRoot = cmpPath === cmpRoot || cmpPath.startsWith(cmpRoot + sep);
    let relPath: string | null = null;
    let isDirectory = false;
    let externalImagePath: string | null = null;
    if (insideRoot) {
      relPath =
        absPath === normalizedRoot ? "" : this.toRelPath(absPath);
      try {
        isDirectory = statSync(absPath).isDirectory();
      } catch {
        // Doesn't exist (yet) — still a valid path to point the Files tab at.
      }
    } else if (externalSafeImageMime(absPath)) {
      // Unlike the inside-root case above, there is no "not yet created"
      // expectation for a path this checkout's watcher knows nothing about —
      // confirm it exists as a real file before pointing the app at it.
      try {
        if (statSync(absPath).isFile()) {
          externalImagePath = absPath;
        }
      } catch {
        // Doesn't exist — leave both relPath and externalImagePath null.
      }
    }
    this.sendMessage(
      createMessage("file:resolve-path-result", {
        projectId: this.projectId,
        requestId,
        relPath,
        isDirectory,
        externalImagePath,
      }),
    );
  }

  /** Returns chokidar's close promise so a caller about to delete the watched
   *  directory can wait the subscriptions out. Chokidar tears down one
   *  `fs.watch()` per directory and resolves only when the last is closed;
   *  dropping it leaves them open, and one live subscription is enough to abort
   *  a `git worktree remove` sweep. The native recursive watcher closes
   *  synchronously, so on macOS/Windows this resolves immediately. */
  stop(): Promise<void> {
    if (this.debounceTimer) {
      clearTimeout(this.debounceTimer);
      this.debounceTimer = null;
    }
    this.pending.added.clear();
    this.pending.modified.clear();
    this.pending.removed.clear();
    // The checkout-teardown half of Trap 3 — every client that had THIS
    // checkout open loses its subscription here, in one place, rather than
    // needing its own per-checkout drop from agent-core.ts's teardown paths.
    this.subscriptions.clear();
    this.dirMtimes.clear();
    const closed = this.watcher?.close();
    this.watcher = null;
    this.nativeWatcher?.close();
    this.nativeWatcher = null;
    log.info("File watcher stopped for %s", this.projectId);
    return Promise.resolve(closed).then(() => undefined);
  }

  private onFileAdded(filePath: string): void {
    const relPath = this.toRelPath(filePath);
    // If it was pending removal, cancel the removal (rename scenario)
    this.pending.removed.delete(relPath);
    this.pending.modified.delete(relPath);

    const node = this.makeFileNode(filePath, relPath);
    if (node) this.pending.added.set(relPath, node);
    this.scheduleBatch();
  }

  private onFileModified(filePath: string): void {
    const relPath = this.toRelPath(filePath);
    // Don't overwrite an add with a modify
    if (this.pending.added.has(relPath)) return;

    const node = this.makeFileNode(filePath, relPath);
    if (!node) return;
    this.pending.modified.set(relPath, node);
    this.scheduleBatch();
  }

  private onFileRemoved(filePath: string): void {
    const relPath = this.toRelPath(filePath);
    // If it was pending add, just remove it (created+deleted within window = no-op)
    if (this.pending.added.has(relPath)) {
      this.pending.added.delete(relPath);
      this.scheduleBatch();
      return;
    }
    this.pending.modified.delete(relPath);
    this.pending.removed.add(relPath);
    this.scheduleBatch();
  }

  private onDirAdded(dirPath: string): void {
    const relPath = this.toRelPath(dirPath);
    if (!relPath || relPath === ".") return;

    const node: FileTreeNode = {
      name: basename(dirPath),
      path: relPath,
      type: "directory",
      children: [],
    };
    this.pending.added.set(relPath, node);
    this.scheduleBatch();
  }

  private scheduleBatch(): void {
    if (this.debounceTimer) return;
    // Measured from the last FLUSH to this change, not flush-to-flush: once the
    // window widens, flushes are naturally further apart, and testing THAT gap
    // against the grace would read the widened cadence as idle and narrow
    // straight back on every cycle.
    this.churnRun =
      Date.now() - this.lastFlushAt < CHURN_GRACE_MS ? this.churnRun + 1 : 0;
    this.debounceTimer = setTimeout(
      () => this.flushBatch(),
      this.churnRun >= CHURN_RUN_TO_WIDEN ? BUSY_WINDOW_MS : IDLE_WINDOW_MS,
    );
  }

  private flushBatch(): void {
    this.debounceTimer = null;

    const fullResync = this.needsFullResync;
    this.needsFullResync = false;

    const added = Array.from(this.pending.added.values());
    const modified = Array.from(this.pending.modified.values());
    const removed = Array.from(this.pending.removed);

    // Reset pending
    this.pending.added.clear();
    this.pending.modified.clear();
    this.pending.removed.clear();

    if (!fullResync && added.length === 0 && modified.length === 0 && removed.length === 0) return;

    // Only a flush that carried something counts: stamping an empty one would
    // make the next isolated save look like the continuation of a storm.
    this.lastFlushAt = Date.now();

    // Ahead of the suppression gate below, and not gated by it: git status is
    // not a heavy-stream frame, and its cache is what a reconnecting app is
    // replayed from — a backgrounded phone must not come back to a snapshot
    // taken before the agent's last edit.
    this.onFilesChanged?.();

    const seq = this.connState.bumpFileSeq(this.projectRoot);
    if (this.connState.suppressed) {
      // Drop the update; the next tree-snapshot reply will reflect the current tree.
      // A pending RESYNC is deferred rather than dropped: the flag was consumed
      // above, and the delta stream it exists to correct is exactly what
      // survives a suppression window — clearing it here would leave the app's
      // base missing every add and remove from the overflow with nothing able
      // to notice.
      this.needsFullResync ||= fullResync;
      return;
    }

    if (fullResync) {
      // The watcher lost track of what actually changed (see the null-filename
      // branch above) — whatever named add/modify/remove this same tick also
      // captured is incomplete at best, so the delta is abandoned and the app
      // clears `childrenLoaded` on the invalidation and re-lists itself.
      //
      // The one path in this method that sends no `tree:update`, deliberately.
      // An app that predates this frame cannot parse it and so learns nothing
      // here — it self-heals on the NEXT delta, whose `seq` is then two ahead
      // of its base, which is exactly what drives its gap-recovery pull. An
      // empty `tree:update` alongside would be contiguous, so that app would
      // advance its base over the gap and never recover at all.
      //
      // Unforced: `seq` was bumped earlier in this flush, so consecutive
      // resyncs carry different payloads and clear the bus's payload-equality
      // dedup on their own. Stop stamping `seq`, or move the bump below this
      // branch, and the second resync in a row is deduped away — the apps
      // that missed the first never learn.
      // Everything open is about to be re-listed, so record where each
      // directory stands now — otherwise the next sweep re-reports the same
      // movement and invalidates a tree that just healed.
      if (this.dirMtimes.size > 0) {
        for (const dir of this.subscribedUnion()) this.noteDirFresh(dir);
      }
      this.sendMessage(createMessage("file:tree:invalidated", { seq }));
      log.debug("tree resync for project %s — watcher reported an unnamed change", this.projectId);
      return;
    }

    // D6: filtered to the union of every attached client's subscribed
    // directories, but ONLY once every attached client has sent one —
    // see [everySubscribed]. An old app that never subscribes is therefore
    // never filtered (Trap 4), and a fresh flush with no client accounted
    // for at all sends everything.
    let outAdded = added;
    let outModified = modified;
    let outRemoved = removed;
    if (this.everySubscribed()) {
      outAdded = added.filter((n) => this.isSubscribed(dirnameKeyOf(n.path)));
      outModified = modified.filter((n) => this.isSubscribed(dirnameKeyOf(n.path)));
      // `|| isSubscribed(p)` is the enforced half of closure under removal: a
      // directory a client explicitly named is by definition one whose own
      // disappearance it must be told about, and its dirname need not be
      // subscribed — the app's collapse clears `childrenLoaded` on the
      // collapsed node alone, so it can hold `a/b` without `a`.
      outRemoved = removed.filter(
        (p) => this.isSubscribed(dirnameKeyOf(p)) || this.isSubscribed(p),
      );
      const total = added.length + modified.length + removed.length;
      const kept = outAdded.length + outModified.length + outRemoved.length;
      if (kept < total) {
        // A count, not the paths: a silently over-filtering tree is the
        // failure mode that reads as "the watcher stopped working", and the
        // count is what tells a future reader which half is wrong.
        log.debug(
          "tree:update — subscription filter dropped %d of %d entries for %s",
          total - kept,
          total,
          this.projectId,
        );
      }
    }

    // Read off the UNFILTERED delta: what this watcher saw is what it is now
    // current for, whatever D6 then dropped from the frame. Residual it cannot
    // close — a change LOST from a directory in the same window as one
    // delivered from it is hidden by the delivered one's refresh, and waits
    // for the next movement in that directory.
    if (this.dirMtimes.size > 0) {
      const union = this.subscribedUnion();
      const touched = new Set<string>();
      for (const node of added) touched.add(dirnameKeyOf(node.path));
      for (const node of modified) touched.add(dirnameKeyOf(node.path));
      for (const path of removed) touched.add(dirnameKeyOf(path));
      for (const dir of touched) if (union.has(dir)) this.noteDirFresh(dir);
    }

    // Sent even when the filter above drops everything: `seq` was already
    // bumped, so suppressing the frame here would still leave a receiver's
    // `sinceSeq` compare wondering whether it missed one, for the cost of one
    // small empty frame.
    this.sendMessage(
      createMessage("tree:update", {
        projectId: this.projectId,
        added: outAdded,
        modified: outModified,
        removed: outRemoved,
        seq,
      }),
    );

    log.debug(
      "tree:update — added: %d, modified: %d, removed: %d",
      outAdded.length,
      outModified.length,
      outRemoved.length,
    );
  }

  private toRelPath(absPath: string): string {
    return relative(this.projectRoot, absPath).replace(/\\/g, "/");
  }

  private makeFileNode(filePath: string, relPath: string): FileTreeNode | null {
    try {
      const stat = statSync(filePath);
      if (!stat.isFile()) return null;
      return {
        name: basename(filePath),
        path: relPath,
        type: "file",
        size: stat.size,
        extension: extname(filePath) || undefined,
      };
    } catch {
      return null;
    }
  }
}
