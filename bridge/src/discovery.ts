import { writeFileSync, renameSync, mkdirSync } from "node:fs";
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
  const tmp = path + ".tmp";
  writeFileSync(tmp, content, opts.fileMode === undefined ? "utf8" : { encoding: "utf8", mode: opts.fileMode });
  renameSync(tmp, path);
}
