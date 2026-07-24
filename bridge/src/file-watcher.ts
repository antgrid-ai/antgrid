import chokidar, { type FSWatcher } from "chokidar";
import { relative, extname, basename, join } from "node:path";
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

type PendingChanges = {
  added: Map<string, FileTreeNode>;
  modified: Map<string, FileTreeNode>;
  removed: Set<string>;
};

export class FileWatcher {
  private projectRoot: string;
  private projectId: string;
  private sendMessage: (msg: AbMessage) => void;
  private connState: ConnState;
  private watcher: FSWatcher | null = null;
  private nativeWatcher: NodeFSWatcher | null = null;
  private ig: ReturnType<typeof loadIgnoreRules>;
  private pending: PendingChanges = {
    added: new Map(),
    modified: new Map(),
    removed: new Set(),
  };
  private debounceTimer: ReturnType<typeof setTimeout> | null = null;

  constructor(
    project: ProjectInfo,
    sendMessage: (msg: AbMessage) => void,
    connState: ConnState,
  ) {
    this.projectRoot = project.path;
    this.projectId = project.id;
    this.sendMessage = sendMessage;
    this.connState = connState;
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

  sendFullTree(): void {
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
    );
    log.info("Sent full file tree for project %s", this.projectId);
  }

  startWatching(): void {
    // macOS: chokidar v5 watches each directory with its own non-recursive
    // fs.watch() call, and on macOS every fs.watch() is a distinct libuv
    // FSEventStream. On a large repo that storm of per-directory FSEventStream
    // create/start/stop calls saturates the CoreServices FSEvents thread and
    // contends the allocator lock with bun's main JS thread, freezing the host
    // event loop for tens of seconds — long enough that the loopback control
    // socket is never accept()ed and the app's first project open times out
    // (the macOS cold-open hang). Node's recursive fs.watch uses a SINGLE
    // recursive FSEventStream regardless of tree size, sidestepping the storm.
    // Recursive mode is supported only on macOS and Windows; Linux keeps
    // chokidar (its inotify-per-dir backend doesn't have this cost).
    if (process.platform === "darwin") {
      this.startNativeRecursiveWatch();
      return;
    }
    this.startChokidarWatch();
  }

  private startChokidarWatch(): void {
    const ignoredFn = (path: string): boolean => {
      const rel = relative(this.projectRoot, path).replace(/\\/g, "/");
      if (!rel || rel === ".") return false;
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
          if (filename == null) return;
          // filename is relative to projectRoot (string under the default
          // encoding; String() also covers a Buffer if the platform yields one).
          const rel = String(filename).replace(/\\/g, "/");
          if (!rel || rel === ".") return;
          // The recursive stream sees the whole tree (FSEvents can't prune at
          // the OS level); apply the same ignore rules chokidar's `ignored`
          // would, so node_modules/build/etc. churn is dropped cheaply here.
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

  stop(): void {
    if (this.debounceTimer) {
      clearTimeout(this.debounceTimer);
      this.debounceTimer = null;
    }
    this.pending.added.clear();
    this.pending.modified.clear();
    this.pending.removed.clear();
    this.watcher?.close();
    this.watcher = null;
    this.nativeWatcher?.close();
    this.nativeWatcher = null;
    log.info("File watcher stopped for %s", this.projectId);
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

    const added = Array.from(this.pending.added.values());
    const modified = Array.from(this.pending.modified.values());
    const removed = Array.from(this.pending.removed);

    // Reset pending
    this.pending.added.clear();
    this.pending.modified.clear();
    this.pending.removed.clear();

    if (added.length === 0 && modified.length === 0 && removed.length === 0) return;

    const seq = this.connState.bumpFileSeq();
    if (this.connState.suppressed) {
      // Drop the update; the next tree-snapshot reply will reflect the current tree.
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
