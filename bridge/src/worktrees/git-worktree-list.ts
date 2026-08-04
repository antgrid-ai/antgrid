import { realpathSync } from "node:fs";

export interface GitWorktreeRecord {
  path: string;
  head: string | null;
  branch: string | null;
  bare: boolean;
  detached: boolean;
  locked: boolean;
  prunable: boolean;
}

function canonicalPath(path: string): string {
  try {
    // native avoids the surprising \"\\?\\\" prefix on Windows paths.
    return realpathSync.native(path);
  } catch {
    return path;
  }
}

/** Parse the machine-readable output of `git worktree list --porcelain -z`.
 * Git emits a `worktree` field first for every record; using that boundary also
 * accepts Git versions which omit the optional blank record separator. */
export function parseWorktreeList(raw: string): GitWorktreeRecord[] {
  const records: GitWorktreeRecord[] = [];
  let current: GitWorktreeRecord | undefined;

  const finish = () => {
    if (current) records.push(current);
    current = undefined;
  };

  for (const field of raw.split("\0")) {
    if (!field) continue;
    const [key, ...rest] = field.split(" ");
    const value = rest.join(" ");
    if (key === "worktree") {
      finish();
      current = {
        path: canonicalPath(value),
        head: null,
        branch: null,
        bare: false,
        detached: false,
        locked: false,
        prunable: false,
      };
      continue;
    }
    if (!current) continue;
    switch (key) {
      case "HEAD": current.head = value || null; break;
      case "branch": current.branch = value || null; break;
      case "bare": current.bare = true; break;
      case "detached": current.detached = true; break;
      case "locked": current.locked = true; break;
      case "prunable": current.prunable = true; break;
    }
  }
  finish();
  return records;
}
