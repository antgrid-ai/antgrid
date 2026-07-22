import { createHash, type BinaryLike } from "node:crypto";
import { realpathSync } from "node:fs";

export interface ProjectIdOptions {
  /** Override realpath resolver (for tests). Defaults to fs.realpathSync. */
  realpath?: (p: string) => string;
  /** Force case-insensitive normalization (defaults: true on win32 / darwin). */
  caseInsensitive?: boolean;
}

export function computeProjectId(folder: string, opts: ProjectIdOptions = {}): string {
  const resolver = opts.realpath ?? ((p) => {
    try { return realpathSync(p); } catch { return p; }
  });
  const caseInsensitive = opts.caseInsensitive
    ?? (process.platform === "win32" || process.platform === "darwin");

  let resolved = resolver(folder);
  if (caseInsensitive) resolved = resolved.toLowerCase();

  return createHash("sha256").update(resolved as BinaryLike).digest("hex").slice(0, 16);
}

/** True when `id` is safe to use as a single path segment under `agents/`: no
 *  path separators, no `..` traversal, and no leading-dot/hidden name. Shared
 *  defense-in-depth for any phone-supplied projectId that becomes a filesystem
 *  path (the allowlist already confines it to catalog ids, which are 16-char
 *  hex — but every verb that joins a projectId into a path must gate on this). */
export function isSafeProjectId(id: string): boolean {
  return /^[A-Za-z0-9_-][A-Za-z0-9._-]*$/.test(id) && !id.includes("..");
}
