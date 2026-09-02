import chokidar, { type FSWatcher } from "chokidar";
import { relative, resolve, sep, extname, basename, join, isAbsolute } from "node:path";
import { statSync, watch as fsWatch, type FSWatcher as NodeFSWatcher } from "node:fs";
import { logger } from "./logger";
const log = logger.child({ component: "file-watcher" });
import { createMessage, type AbMessage } from "./protocol";
import {
  loadIgnoreRules,
  buildTree,
  readFile,
  type FileTreeNode,
} from "./file-tree";
import type { ConnState } from "./conn-state";
export interface ProjectInfo {
  path: string;
  id: string;
  name?: string;
}

const DEBOUNCE_MS = 100;

/** The watcher's one outbound hook. `opts.force` is honoured only by senders
 *  that publish through a deduping bus; a plain sender may ignore it. */
type SendTreeMessage = (msg: AbMessage, opts?: { force?: boolean }) => void;

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
  private pending: PendingChanges = {
    added: new Map(),
    modified: new Map(),
    removed: new Set(),
  };
  private debounceTimer: ReturnType<typeof setTimeout> | null = null;
  /** Set when the native recursive watcher reports a change with no path —
   *  see [startNativeRecursiveWatch] — so [flushBatch] falls back to a full
   *  resync instead of sending an incremental batch it knows is incomplete. */
  private needsFullResync = false;

  constructor(
    project: ProjectInfo,
    sendMessage: SendTreeMessage,
    connState: ConnState,
    onFilesChanged?: () => void,
  ) {
    this.projectRoot = project.path;
    this.projectId = project.id;
    this.sendMessage = sendMessage;
    this.connState = connState;
    this.onFilesChanged = onFilesChanged;
    this.ig = loadIgnoreRules(this.projectRoot, []);
  }

  getTreeSnapshot(): { tree: FileTreeNode; seq: number } {
    const root = buildTree(this.projectRoot, this.projectRoot, this.ig);
    if (!root) {
      return {
        tree: { name: "", path: "", type: "directory", children: [] },
        seq: this.connState.fileSeq,
      };
    }
    return { tree: root, seq: this.connState.fileSeq };
  }

  /** [opts.force] bypasses the bus's payload-equality dedup — for the re-sync
   *  paths, where an unchanged tree is exactly what has to reach the wire. */
  sendFullTree(opts: { force?: boolean } = {}): void {
    const root = buildTree(this.projectRoot, this.projectRoot, this.ig);
    if (!root) {
      log.error("Failed to build file tree for %s", this.projectRoot);
      return;
    }

    this.sendMessage(
      createMessage("tree:full", {
        projectId: this.projectId,
        root,
      }),
      opts,
    );
    log.info("Sent full file tree for project %s", this.projectId);
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
      depth: 10,
      ignored: ignoredFn,
    });

    this.watcher
      .on("add", (filePath) => this.onFileAdded(filePath))
      .on("change", (filePath) => this.onFileModified(filePath))
      .on("unlink", (filePath) => this.onFileRemoved(filePath))
      .on("addDir", (dirPath) => this.onDirAdded(dirPath))
      .on("unlinkDir", (dirPath) => this.onFileRemoved(dirPath))
      .on("error", (err) => log.error("File watcher error: %s", err));

    log.info("File watcher started for %s", this.projectRoot);
  }

  private startNativeRecursiveWatch(): void {
    try {
      this.nativeWatcher = fsWatch(
        this.projectRoot,
        { recursive: true, persistent: true },
        (_event, filename) => {
          if (filename == null) {
            // Windows' (and reportedly macOS's) recursive fs.watch reports
            // exactly this — a change with no path — when its internal
            // notification buffer overflows: a burst of filesystem activity
            // (a new directory landing with many files in one go is enough,
            // measured on Windows) drops the per-file events instead of
            // queuing them, rather than raising an error. There is no path to
            // diff here, so treat it as "something changed, scope unknown"
            // and let flushBatch fall back to a full resync — otherwise some
            // of the affected files never appear until the app's own
            // pull-to-refresh forces a rebuild from disk.
            this.needsFullResync = true;
            this.scheduleBatch();
            return;
          }
          // Usually relative to projectRoot (String() also covers a Buffer if
          // the platform yields one) — but Windows also delivers the ABSOLUTE
          // watched root for events on the directory itself, so re-derive
          // rather than trust it.
          const raw = String(filename);
          const rel = (isAbsolute(raw) ? relative(this.projectRoot, raw) : raw)
            .replace(/\\/g, "/");
          // `ignore` THROWS on a path that isn't root-relative instead of
          // answering, and this callback runs on a libuv event with no caller
          // to catch it — an unhandled RangeError that takes the watcher down
          // (the chokidar path guards the same way for the same reason). The
          // root itself and anything above it are honestly "not ignored", but
          // there is also nothing under them to report.
          if (!rel || rel === "." || rel === ".." || rel.startsWith("../")) return;
          // The recursive stream sees the whole tree (the OS can't prune at the
          // subscription level); apply the same ignore rules chokidar's
          // `ignored` would, so node_modules/build/etc. churn is dropped here.
          if (this.ig.ignores(rel)) return;
          this.onNativeChange(join(this.projectRoot, rel));
        },
      );
      this.nativeWatcher.on("error", (err) =>
        log.error("File watcher error: %s", err),
      );
      log.info(
        "File watcher started (native recursive) for %s",
        this.projectRoot,
      );
    } catch (err) {
      log.error(
        "native recursive watch failed (%s); falling back to chokidar",
        err,
      );
      this.startChokidarWatch();
    }
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
   *  resolve at all. Mirrors [readFile]'s own traversal guard. */
  handleResolvePathRequest(requestId: string, rawPath: string): void {
    const absPath = resolve(this.projectRoot, rawPath);
    const normalizedRoot = resolve(this.projectRoot);
    const insideRoot =
      absPath === normalizedRoot || absPath.startsWith(normalizedRoot + sep);
    let relPath: string | null = null;
    let isDirectory = false;
    if (insideRoot) {
      relPath =
        absPath === normalizedRoot ? "" : this.toRelPath(absPath);
      try {
        isDirectory = statSync(absPath).isDirectory();
      } catch {
        // Doesn't exist (yet) — still a valid path to point the Files tab at.
      }
    }
    this.sendMessage(
      createMessage("file:resolve-path-result", {
        projectId: this.projectId,
        requestId,
        relPath,
        isDirectory,
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
    this.debounceTimer = setTimeout(() => this.flushBatch(), DEBOUNCE_MS);
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

    // Ahead of the suppression gate below, and not gated by it: git status is
    // not a heavy-stream frame, and its cache is what a reconnecting app is
    // replayed from — a backgrounded phone must not come back to a snapshot
    // taken before the agent's last edit.
    this.onFilesChanged?.();

    const seq = this.connState.bumpFileSeq();
    if (this.connState.suppressed) {
      // Drop the update; the next tree-snapshot reply will reflect the current tree.
      return;
    }

    if (fullResync) {
      // The watcher lost track of what actually changed (see the null-filename
      // branch above) — whatever named add/modify/remove this same tick also
      // captured is incomplete at best, so send the real thing instead: the
      // same full tree a manual pull-to-refresh would rebuild.
      this.sendFullTree({ force: true });
      log.debug("tree resync for project %s — watcher reported an unnamed change", this.projectId);
      return;
    }

    this.sendMessage(
      createMessage("tree:update", {
        projectId: this.projectId,
        added,
        modified,
        removed,
        seq,
      }),
    );

    log.debug(
      "tree:update — added: %d, modified: %d, removed: %d",
      added.length,
      modified.length,
      removed.length,
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
