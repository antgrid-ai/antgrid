import { writeFileSync, renameSync, mkdirSync, chmodSync, rmSync, statSync } from "node:fs";
import { dirname } from "node:path";

export interface AtomicWriteOptions {
  dirMode?: number;
  fileMode?: number;
}

// SECURITY: callers pass tokens/loopback ports through this helper (e.g.
// host.json). The `fileMode` arg (typically 0o600) protects the file on POSIX,
// but is effectively a no-op on Windows — the file inherits the parent ACL,
// which by default grants read access to the local `Users` group. On a
// multi-user Windows machine, any other local user could read the token and
// impersonate the App. Trust model on Windows is therefore "any process
// running as the same user has full agent access". For multi-user Windows
// hardening, restrict the containing dir via `icacls` to the current user.
export function atomicWriteFile(path: string, content: string, opts: AtomicWriteOptions = {}): void {
  mkdirSync(dirname(path), { recursive: true, mode: opts.dirMode });
  // Scoped to the pid rather than shared: the `antgrid` CLI writes these same
  // stores while the host is running, and one scratch file both processes
  // truncate is renamed into place as a blend of the two. Reusing a single name
  // per pid keeps it self-reclaiming — a write interrupted by a kill (the
  // routine teardown on Windows) leaves at most one stale file per target, which
  // the next write overwrites. Nothing in the tree sweeps these.
  const tmp = `${path}.${process.pid}.tmp`;
  try {
    writeFileSync(tmp, content, opts.fileMode === undefined ? "utf8" : { encoding: "utf8", mode: opts.fileMode });
    // `mode` applies only where open(2) creates the file, and the scratch name
    // is reused, so a leftover from a killed write keeps whatever mode it had.
    // Never fatal: a filesystem that refuses chmod must not stop the store from
    // persisting, which is what discarding the scratch file below would do.
    if (opts.fileMode !== undefined && process.platform !== "win32") {
      try { chmodSync(tmp, opts.fileMode); } catch { /* best-effort */ }
    }
    renameWithRetry(tmp, path);
  } catch (err) {
    // Cleanup must never become the reported failure — it would name the scratch
    // path for a fault that happened to the target.
    try { rmSync(tmp, { force: true }); } catch { /* best-effort */ }
    throw err;
  }
}

// Windows refuses a rename whose target another process holds open — a plain
// reader is enough — as a MoveFileEx sharing violation surfaced as
// EPERM/EBUSY/EACCES, and the `antgrid` CLI reads these stores while the host
// writes them. The contending handle usually closes in microseconds, so the
// first attempts retry with no delay at all and the sleeping tail only covers a
// reader descheduled mid-read. Empty on POSIX, where rename(2) is atomic against
// a concurrent rename and uses these codes only for permanent faults (an
// unwritable parent, a sticky-bit denial).
const RENAME_RETRY_DELAYS_MS = process.platform === "win32" ? [0, 0, 0, 1, 2, 5, 10, 25, 50] : [];

function renameWithRetry(tmp: string, path: string): void {
  let judgedTarget = false;
  for (const delay of RENAME_RETRY_DELAYS_MS) {
    try {
      renameSync(tmp, path);
      return;
    } catch (err) {
      const code = (err as NodeJS.ErrnoException | undefined)?.code;
      if (code !== "EPERM" && code !== "EBUSY" && code !== "EACCES") throw err;
      if (!judgedTarget) {
        judgedTarget = true;
        if (targetRefusesReplacement(path)) throw err;
      }
      // Synchronous by necessity — the whole helper is sync, and its callers sit
      // on paths (client-hello admission, `mobile-access:set`) that persist
      // before they answer. Every millisecond blocks the whole event loop.
      if (delay > 0) Bun.sleepSync(delay);
    }
  }
  renameSync(tmp, path);
}

/** Whether the target will refuse a replacement however long we wait. Windows
 *  reports a read-only file and a directory in the way with the same
 *  EPERM/EACCES as a transient sharing violation, so without this the whole
 *  ladder is spent blocking the event loop on a write that cannot land — on
 *  every agent launch, for a hook config a backup restore left read-only.
 *  Anything we cannot stat is left to the retry, which fails closed. */
function targetRefusesReplacement(path: string): boolean {
  try {
    const target = statSync(path);
    return target.isDirectory() || (target.mode & 0o200) === 0;
  } catch {
    return false;
  }
}
