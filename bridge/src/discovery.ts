import { writeFileSync, renameSync, mkdirSync, chmodSync, rmSync, statSync, readdirSync } from "node:fs";
import { basename, dirname, join } from "node:path";

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
  reapAbandonedScratch(path);
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

/** Whether an `fs.watch` event naming `eventName` should be treated as touching
 *  `fileName`. Every directory watcher over a file [atomicWriteFile] publishes
 *  MUST filter through this rather than comparing the name itself.
 *
 *  It over-accepts in three deliberate ways, because a spurious hit costs one
 *  re-read of a fixed path while a dropped one is a watcher that has silently
 *  gone deaf:
 *
 *  - The `<name>.<pid>.tmp` scratch a publish renames from. Measured on Linux:
 *    for one rename-publish into a watched directory, Node delivers four events
 *    ending in `rename:<name>`, but Bun delivers exactly ONE — `rename:
 *    <name>.<pid>.tmp` — and never names the target at all. Windows reports only
 *    the scratch too when the target does not yet exist. So on the runtime the
 *    bridge actually ships, an exact-name filter never fires.
 *  - Case-insensitively. A user-authored target (antgrid.yaml) may be on disk in
 *    another case, and every other access resolves it case-insensitively on
 *    Windows and macOS — so an exact compare would read the file happily and
 *    then ignore every save to it.
 *  - A nameless event (inotify IN_ATTRIB on the directory itself), which carries
 *    nothing to filter on. */
export function isWatchEventFor(eventName: string | Buffer | null | undefined, fileName: string): boolean {
  if (!eventName) return true;
  const n = eventName.toString().toLowerCase();
  const f = fileName.toLowerCase();
  return n === f || (n.startsWith(`${f}.`) && n.endsWith(".tmp"));
}

const reaped = new Set<string>();

/** Drop scratch files a bridge was killed before it could rename. Rename is
 *  atomic only within a filesystem, so the scratch file cannot be moved off the
 *  target's own directory — and those directories belong to the user: the git
 *  working tree holding `antgrid.yaml` (where a leaked `.tmp` shows up in
 *  `git status` and can be committed), `~/.claude` and friends, and <abDir>,
 *  where the leak is a full copy of the control-plane token that
 *  `removeHostFile` never reaps. This is not a crash path: force-kill IS the
 *  routine teardown, since the app's job object sweeps the host tree as it exits.
 *
 *  Once per target per process — the readdir is work the write itself does not
 *  need, and anything a live writer loses it immediately rewrites. A pid still
 *  running is left alone, so pid reuse can only ever make us KEEP a stale file,
 *  never delete one being written. */
function reapAbandonedScratch(path: string): void {
  if (reaped.has(path)) return;
  reaped.add(path);
  const dir = dirname(path);
  const prefix = `${basename(path)}.`;
  try {
    for (const entry of readdirSync(dir)) {
      if (!entry.startsWith(prefix) || !entry.endsWith(".tmp")) continue;
      // Deliberately excludes the pre-<pid> shared `<path>.tmp` (it parses as 0):
      // a bridge old enough to still write that name could be writing it now, and
      // nothing in its name says otherwise.
      const pid = Number(entry.slice(prefix.length, entry.length - ".tmp".length));
      if (!Number.isInteger(pid) || pid <= 0 || pid === process.pid || isRunning(pid)) continue;
      try { rmSync(join(dir, entry), { force: true }); } catch { /* best-effort */ }
    }
  } catch { /* best-effort: a store must still publish on a directory we cannot list */ }
}

function isRunning(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch (err) {
    // EPERM is another user's process — running, and none of our business.
    return (err as NodeJS.ErrnoException).code === "EPERM";
  }
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
