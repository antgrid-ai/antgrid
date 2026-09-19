import { readdirSync, lstatSync, readFileSync, existsSync, realpathSync, type Dirent } from "node:fs";
import { join, resolve, relative, extname, basename, sep } from "node:path";
import ignore, { type Ignore } from "ignore";

export type FileTreeNode = {
  name: string;
  path: string; // relative to project root
  type: "file" | "directory";
  size?: number;
  extension?: string;
  children?: FileTreeNode[];
  /** The listing stopped early: `children` is a complete, ordered prefix of
   * the directory, not the whole of it. See MAX_TREE_NODES. */
  truncated?: true;
};

const MAX_DEPTH = 10;

/** Nodes one tree may carry. Every checkout's tree is replayed to every app
 * that binds the project, so the largest checkout sets the cost of every
 * connect — and a worktree that grew a 20k-file data directory made that reply
 * megabytes, enough on a phone's uplink to hold the bridge's own relay pongs
 * behind it until the relay closed the socket. Past the budget the walk stops
 * where it is and marks each directory it cut short; nothing already listed is
 * dropped or reordered. */
export const MAX_TREE_NODES = 10_000;

/** Entries a single `listDirectory` call may return, regardless of the
 * budget it was handed — the per-directory ceiling under the on-demand
 * listing model. */
export const MAX_LISTING_ENTRIES = 2_000;
/** Total entries a `listDirectoryBatch` call may return across every listing
 * in the batch. See `allocateBudgets`. */
export const MAX_BATCH_NODES = 10_000;

const MAX_FILE_SIZE = 1_048_576; // 1MB
const MAX_BINARY_FILE_SIZE = 10_485_760; // 10MB

// Binary types we transport as base64 for rendering. Anything else binary is
// still rejected (the app has no viewer for it).
const RENDERABLE_BINARY_MIME: Record<string, string> = {
  ".png": "image/png",
  ".apng": "image/apng",
  ".jpg": "image/jpeg",
  ".jpeg": "image/jpeg",
  ".jfif": "image/jpeg",
  ".gif": "image/gif",
  ".webp": "image/webp",
  ".bmp": "image/bmp",
  ".ico": "image/x-icon",
  ".avif": "image/avif",
  ".pdf": "application/pdf",
};

/// The mime a staged/read file would be transported as, or undefined when the
/// app has no viewer for it. Exported so the upload path can answer
/// "is this previewable" from the SAME table `readFile` uses — an app-side
/// extension list would drift from it silently.
export function renderableBinaryMime(path: string): string | undefined {
  return RENDERABLE_BINARY_MIME[extname(path).toLowerCase()];
}

/// Raster image types `readFile` will serve from OUTSIDE the checkout root —
/// deliberately a narrower subset of [RENDERABLE_BINARY_MIME], for a path a
/// terminal program printed (an OSC 8 `file://` hyperlink target, e.g. an
/// image-generation tool's own output directory) rather than one the app
/// found by walking this checkout's tree. That distinction is exactly the
/// trust boundary: everything ELSE in this file assumes a path came from the
/// tree or from inside the checkout, and readFile's traversal guard exists
/// because a hyperlink's target is untrusted (whatever program is running in
/// the terminal chose it, not the user). Two are withheld even though
/// RENDERABLE_BINARY_MIME carries them: `.pdf` for its larger parser attack
/// surface, and `.ico` for having no real "generated output" use case here —
/// neither is worth the exposure for a path this app never chose to trust
/// with a checkout. `.svg` was never in RENDERABLE_BINARY_MIME to begin with
/// (it can embed a script), so it needs no separate exclusion here.
const EXTERNAL_SAFE_IMAGE_MIME: Record<string, string> = {
  ".png": "image/png",
  ".apng": "image/apng",
  ".jpg": "image/jpeg",
  ".jpeg": "image/jpeg",
  ".jfif": "image/jpeg",
  ".gif": "image/gif",
  ".webp": "image/webp",
  ".bmp": "image/bmp",
  ".avif": "image/avif",
};

/// Whether [path]'s extension is one `readFile` will serve from outside the
/// checkout root — see [EXTERNAL_SAFE_IMAGE_MIME].
export function externalSafeImageMime(path: string): string | undefined {
  return EXTERNAL_SAFE_IMAGE_MIME[extname(path).toLowerCase()];
}

const DEFAULT_IGNORES = [
  ".git",
  ".antgrid",
  "node_modules",
  ".DS_Store",
  "__pycache__",
  ".pytest_cache",
  ".venv",
  "venv",
  ".idea",
  ".vscode",
  "*.pyc",
  ".next",
  ".cache",
  ".parcel-cache",
  "*.swp",
  "*.swo",
  "Thumbs.db",
];

function readGitignore(dir: string): Ignore | null {
  const gitignorePath = join(dir, ".gitignore");
  if (!existsSync(gitignorePath)) return null;
  try {
    return ignore().add(readFileSync(gitignorePath, "utf8"));
  } catch {
    return null;
  }
}

/** The project's ignore rules as Git reads them: the defaults, the config's
 * excludes and the root `.gitignore`, plus each directory's own `.gitignore`,
 * whose patterns are anchored at that directory. A nested file is read on
 * first sight and kept for the life of the rules, exactly like the root's.
 * One deviation from Git, tolerated because it only ever hides: a nested
 * `!pattern` cannot re-include what an ancestor's rules excluded.
 *
 * `useGitignore: false` (the "show everything" variant, see D9/D10 in
 * docs/file-tree-lazy-expansion-spec.md) turns off both the root and nested
 * `.gitignore` consultation but keeps `DEFAULT_IGNORES` and config excludes.
 * Nothing in `antgrid.yaml` produces config excludes today; the parameter
 * stays because both `FileSearcher` constructions pass the Antgrid state dir
 * through it. */
export class IgnoreRules {
  private readonly nested = new Map<string, Ignore | null>();

  constructor(
    private readonly projectRoot: string,
    private readonly root: Ignore,
    private readonly useGitignore: boolean = true,
  ) {}

  /** `relPath` is root-relative with `/` separators and never the root itself
   * (`ignore` throws rather than answer for "" or a path that escapes). */
  ignores(relPath: string): boolean {
    if (this.root.ignores(relPath)) return true;
    if (!this.useGitignore) return false;
    const parts = relPath.split("/");
    for (let i = 1; i < parts.length; i++) {
      const rules = this.nestedFor(parts.slice(0, i).join("/"));
      if (rules?.ignores(parts.slice(i).join("/"))) return true;
    }
    return false;
  }

  private nestedFor(dir: string): Ignore | null {
    let rules = this.nested.get(dir);
    if (rules === undefined) {
      rules = readGitignore(join(this.projectRoot, dir));
      this.nested.set(dir, rules);
    }
    return rules;
  }
}

export type IgnoreRulesOptions = {
  /** Default true. False is the tree's "show everything" variant: git's
   * ignore rules (root AND nested) are skipped outright, not merely
   * unconsulted — see IgnoreRules' doc comment.
   *
   * It is narrower than the spec's "show everything": `DEFAULT_IGNORES` still
   * applies, so `node_modules`, `.venv`, `.next` and `.vscode` stay hidden
   * under both variants. Splitting that list into a floor and a convenience
   * set would change what `buildTree` — the whole-tree path every shipped app
   * still uses — returns, so it waits for the wave that retires that path. */
  gitignore?: boolean;
};

/** Each call re-reads the root `.gitignore` and builds a fresh matcher, and
 * the result lives exactly as long as the caller that holds it. A
 * process-global cache keyed by path would both outlive a deleted managed
 * worktree and hand a rebuilt watcher the rules from before the user's last
 * `.gitignore` edit — rebuilding the watcher is the only gesture that picks
 * such an edit up. */
export function loadIgnoreRules(
  projectRoot: string,
  configExcludes: string[],
  opts: IgnoreRulesOptions = {},
): IgnoreRules {
  const gitignore = opts.gitignore !== false;
  const ig = ignore();
  ig.add(DEFAULT_IGNORES);
  if (configExcludes.length > 0) ig.add(configExcludes);
  if (gitignore) {
    const rootGitignore = readGitignore(projectRoot);
    if (rootGitignore) ig.add(rootGitignore);
  }
  return new IgnoreRules(projectRoot, ig, gitignore);
}

export function buildTree(
  absPath: string,
  projectRoot: string,
  rules: IgnoreRules,
  budget = MAX_TREE_NODES,
): FileTreeNode | null {
  return walk(absPath, projectRoot, rules, 0, { left: budget });
}

function walk(
  absPath: string,
  projectRoot: string,
  rules: IgnoreRules,
  depth: number,
  budget: { left: number },
): FileTreeNode | null {
  if (depth > MAX_DEPTH) return null;

  let stat;
  try {
    stat = lstatSync(absPath);
  } catch {
    return null;
  }

  if (stat.isSymbolicLink()) return null;

  const relPath = relative(projectRoot, absPath).replace(/\\/g, "/");
  const name = absPath === projectRoot ? "" : basename(absPath);

  // Check ignore rules (skip for the root itself)
  if (relPath && relPath !== "." && rules.ignores(relPath)) {
    return null;
  }

  if (stat.isFile()) {
    budget.left--;
    return {
      name,
      path: relPath,
      type: "file",
      size: stat.size,
      extension: extname(name) || undefined,
    };
  }

  if (stat.isDirectory()) {
    let entries: string[];
    try {
      entries = readdirSync(absPath);
    } catch {
      return null;
    }
    budget.left--;

    // Walk in name order so a budget cut is deterministic: what survives is
    // always the same leading run of the listing, not whatever the filesystem
    // happened to enumerate first. Code-unit order, not `localeCompare`: this
    // runs once per directory of every full tree build, and the collator is
    // both far slower and dependent on the host's ICU data — which would make
    // the cut differ between machines.
    entries.sort();
    const children: FileTreeNode[] = [];
    let truncated = false;
    // The depth guard at the top of this function drops every child of a
    // directory sitting at the cap and cannot say WHY it returned null, so the
    // cut is marked here, where the cap is still in view. An ignored entry is
    // not a cut — it was never going to be sent.
    if (depth === MAX_DEPTH) {
      truncated = entries.some((entry) =>
        !rules.ignores(relative(projectRoot, join(absPath, entry)).replace(/\\/g, "/")),
      );
    }
    for (const entry of entries) {
      if (budget.left <= 0) {
        truncated = true;
        break;
      }
      const child = walk(join(absPath, entry), projectRoot, rules, depth + 1, budget);
      if (child) children.push(child);
    }

    // Sort: directories first, then files, alphabetical within each group
    children.sort((a, b) => {
      if (a.type !== b.type) return a.type === "directory" ? -1 : 1;
      return a.name.localeCompare(b.name);
    });

    return {
      name: name || basename(projectRoot),
      path: relPath || ".",
      type: "directory",
      children,
      ...(truncated ? { truncated: true as const } : {}),
    };
  }

  return null;
}

export type DirectoryListing = {
  path: string;
  children: FileTreeNode[];
  /** Cut at the caller-supplied budget — `children` is an ordered prefix, not
   * the whole directory. See MAX_LISTING_ENTRIES / MAX_BATCH_NODES. */
  truncated?: true;
  /** The directory does not exist, or its resolved path escaped the
   * checkout. Distinct from a genuinely empty directory, which answers
   * `children: []` with no `missing` flag — collapsing the two leaves a
   * deleted folder spinning forever in the app. */
  missing?: true;
};

/** Entries one `listDirectory` call may EXAMINE before it gives up and marks
 * the directory truncated. The budget bounds what a listing RETURNS, which is
 * a different number the moment most of a directory is filtered out: a
 * `__pycache__` holding thousands of `*.pyc` files returns nothing and would
 * otherwise pay for every entry, once per path in the batch, on the same loop
 * that carries PTY reads and relay pongs. */
const MAX_LISTING_SCAN = 20_000;

function containedBy(absPath: string, root: string): boolean {
  // Case-folded on Windows, mirroring `FileWatcher.handleResolvePathRequest` —
  // the only other containment check in the bridge that folds — because a
  // checkout-relative path and the root it is checked against can arrive with
  // different casing for the same drive letter.
  const cmpPath = process.platform === "win32" ? absPath.toLowerCase() : absPath;
  const cmpRoot = process.platform === "win32" ? root.toLowerCase() : root;
  return cmpPath === cmpRoot || cmpPath.startsWith(cmpRoot + sep);
}

/** Resolves `relPath` (checkout-relative, `/`-separated; `""` is the root)
 * against `projectRoot` and confirms containment, REJECTING anything that
 * would resolve outside it rather than clamping it back in.
 *
 * Containment is decided on the REAL path, not only the lexical one:
 * `resolve()` does not follow links and `lstat`'s symlink refusal inspects
 * only a path's final component, so `vendor/etc` with `vendor` a link out of
 * the checkout is lexically inside it and would enumerate whatever it points
 * at — one directory per request, each reply naming the next. */
function guardedAbsolutePath(relPath: string, projectRoot: string): string | null {
  if (relPath.startsWith("/") || relPath.startsWith("\\") || /^[a-zA-Z]:/.test(relPath)) {
    return null;
  }
  if (relPath.split(/[/\\]/).includes("..")) {
    return null;
  }

  const normalizedRoot = resolve(projectRoot);
  const absPath = relPath === "" ? normalizedRoot : resolve(normalizedRoot, relPath);
  if (!containedBy(absPath, normalizedRoot)) return null;

  try {
    if (!containedBy(realpathSync.native(absPath), realpathSync.native(normalizedRoot))) return null;
  } catch {
    // A path that cannot be resolved cannot be vouched for either.
    return null;
  }

  // The LEXICAL path is what the caller reads from: its entries' `relative()`
  // spelling is the one the app asked about and will ask about again.
  return absPath;
}

/** Depth-1 listing of one directory. There is no cross-call cache: every
 * expand re-lists from disk, whether or not the caller already holds
 * children for the path — the on-demand tree's only refresh gesture is
 * collapse-then-expand, and a cache-hit branch here would remove it (see the
 * spec's D2/D14 and Trap 10). */
export function listDirectory(
  relPath: string,
  projectRoot: string,
  rules: IgnoreRules,
  budget: number = MAX_LISTING_ENTRIES,
): DirectoryListing {
  const absPath = guardedAbsolutePath(relPath, projectRoot);
  if (absPath === null) {
    return { path: relPath, children: [], missing: true };
  }

  let stat;
  try {
    stat = lstatSync(absPath);
  } catch {
    return { path: relPath, children: [], missing: true };
  }
  // A symlinked "directory" is refused the same way walk() refuses a
  // symlinked file — never followed, never listed.
  if (stat.isSymbolicLink() || !stat.isDirectory()) {
    return { path: relPath, children: [], missing: true };
  }

  let entries: Dirent[];
  try {
    // withFileTypes so an entry the ignore rules are about to drop costs no
    // stat at all: readdir already carries each entry's kind, and only an
    // entry that survives every filter is ever stat'd, for its size.
    entries = readdirSync(absPath, { withFileTypes: true });
  } catch {
    return { path: relPath, children: [], missing: true };
  }

  // Code-unit order first so a budget cut is deterministic and
  // machine-independent — the same reason walk() sorts entries this way
  // before its own cut. The display order (directories first, then
  // localeCompare) is applied afterwards, over the surviving entries only.
  entries.sort((a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0));

  const relDir = relative(projectRoot, absPath).replace(/\\/g, "/");
  const relPrefix = relDir === "" ? "" : `${relDir}/`;
  const cap = Math.min(Math.max(budget, 0), MAX_LISTING_ENTRIES);
  const children: FileTreeNode[] = [];
  let truncated = false;
  let scanned = 0;

  for (const entry of entries) {
    if (scanned >= MAX_LISTING_SCAN) {
      truncated = true;
      break;
    }
    scanned++;
    if (entry.isSymbolicLink()) continue;

    const childRel = relPrefix + entry.name;
    if (rules.ignores(childRel)) continue;

    // The cap bites only once an entry has survived every filter, so a
    // directory whose remaining entries were all going to be dropped anyway
    // is not reported truncated — walk()'s depth probe draws the same line,
    // and the app paints a "there is more here" affordance from this flag.
    if (children.length >= cap) {
      truncated = true;
      break;
    }

    if (entry.isDirectory()) {
      children.push({ name: entry.name, path: childRel, type: "directory" });
      continue;
    }
    // A file needs its size, and an entry whose kind readdir declined to
    // report (some filesystems answer UNKNOWN) needs its kind — one stat
    // covers both, and only a surviving entry ever pays for it.
    let childStat;
    try {
      childStat = lstatSync(join(absPath, entry.name));
    } catch {
      continue;
    }
    if (childStat.isSymbolicLink()) continue;
    if (childStat.isDirectory()) {
      children.push({ name: entry.name, path: childRel, type: "directory" });
      continue;
    }
    if (!childStat.isFile()) continue;
    children.push({
      name: entry.name,
      path: childRel,
      type: "file",
      size: childStat.size,
      extension: extname(entry.name) || undefined,
    });
  }

  children.sort((a, b) => {
    if (a.type !== b.type) return a.type === "directory" ? -1 : 1;
    return a.name.localeCompare(b.name);
  });

  return {
    path: relPath,
    children,
    ...(truncated ? { truncated: true as const } : {}),
  };
}

/** Splits `total` fair-share-first across `pathCount` listings: each gets
 * `floor(total / pathCount)`, floored back up to 1 so a batch bigger than the
 * budget still returns something for every path rather than `pathCount`
 * empty listings. This is only the fair-share half of the allocation — the
 * remainder-by-need half (a listing that used less than its share handing
 * the surplus to a listing the share cut, in request order) needs the
 * listings' actual sizes and lives in `listDirectoryBatch`. */
export function allocateBudgets(pathCount: number, total: number): number[] {
  if (pathCount <= 0) return [];
  const fairShare = Math.max(1, Math.floor(total / pathCount));
  return new Array(pathCount).fill(fairShare);
}

/** Lists every DISTINCT path in `paths` under one shared `totalBudget`,
 * fair-share first and remainder by need: first-come would let one huge
 * directory starve the other 63 in a batch, so every listing starts with an
 * equal share and a listing that finishes under its share hands the surplus
 * to the next listing the share cut, walking the batch in REQUEST ORDER.
 *
 * Duplicates collapse before any of that: a path repeated n times would
 * otherwise multiply the whole batch's cost by n for an answer the caller
 * already holds. The result has one entry per DISTINCT path, not one per
 * element of `paths`. */
export function listDirectoryBatch(
  paths: string[],
  projectRoot: string,
  rules: IgnoreRules,
  totalBudget: number = MAX_BATCH_NODES,
): DirectoryListing[] {
  const unique = [...new Set(paths)];
  const n = unique.length;
  if (n === 0) return [];
  const budgets = allocateBudgets(n, totalBudget);
  const results = unique.map((p, i) => listDirectory(p, projectRoot, rules, budgets[i]));

  let surplus = 0;
  for (let i = 0; i < n; i++) {
    if (!results[i].truncated) surplus += budgets[i] - results[i].children.length;
  }
  for (let i = 0; i < n && surplus > 0; i++) {
    if (!results[i].truncated) continue;
    // A listing already at the per-directory ceiling cannot return one more
    // entry however much surplus it is offered, and re-listing it would pay a
    // full readdir to hand back exactly what it already has.
    const headroom = MAX_LISTING_ENTRIES - budgets[i];
    if (headroom <= 0) continue;
    const grant = Math.min(surplus, headroom);
    const before = results[i].children.length;
    results[i] = listDirectory(unique[i], projectRoot, rules, budgets[i] + grant);
    surplus -= results[i].children.length - before;
  }

  return results;
}

const BINARY_CHECK_BYTES = 8192;

function isBinaryBuffer(buf: Buffer): boolean {
  const len = Math.min(buf.length, BINARY_CHECK_BYTES);
  for (let i = 0; i < len; i++) {
    if (buf[i] === 0) return true;
  }
  return false;
}

type ReadFileResult = {
  content: string | null;
  size: number;
  error?: string;
  encoding?: "utf8" | "base64";
  mimeType?: string;
};

function tooLarge(size: number, cap: number): ReadFileResult {
  return { content: null, size, error: `File too large (${size} bytes, max ${cap})` };
}

export function readFile(
  projectRoot: string,
  relPath: string,
): ReadFileResult {
  // Path traversal protection — except for a recognized image extension,
  // which may be served from outside the checkout root entirely. See
  // EXTERNAL_SAFE_IMAGE_MIME for why this narrow carve-out is safe where a
  // general one would not be: `file:read`'s caller for this case is always
  // FileService.openPreview off a resolved `externalImagePath` (see
  // `file-watcher.ts`'s handleResolvePathRequest), never a bare user-typed
  // path, and the extension gate rules out anything that could carry a
  // script (.svg) or a heavier parser (.pdf).
  const absPath = resolve(projectRoot, relPath);
  const normalizedRoot = resolve(projectRoot);
  const insideRoot =
    absPath === normalizedRoot || absPath.startsWith(normalizedRoot + sep);
  if (!insideRoot && !externalSafeImageMime(absPath)) {
    return { content: null, size: 0, error: "Path traversal denied" };
  }

  try {
    const lstat = lstatSync(absPath);

    if (lstat.isSymbolicLink()) {
      return { content: null, size: 0, error: "Symbolic links are not followed" };
    }

    if (!lstat.isFile()) {
      return { content: null, size: 0, error: "Not a file" };
    }

    const stat = lstat;

    const mime = RENDERABLE_BINARY_MIME[extname(absPath).toLowerCase()];

    if (mime) {
      if (stat.size > MAX_BINARY_FILE_SIZE) {
        return tooLarge(stat.size, MAX_BINARY_FILE_SIZE);
      }
      const buf = readFileSync(absPath);
      // Trust the extension only after a content check: a text file with an
      // image/pdf extension (e.g. notes.ico) would otherwise be base64-shipped
      // up to the 10MB binary cap and render as a broken image. Fall through to
      // the text path (and its 1MB cap) so it's shown as source instead.
      if (isBinaryBuffer(buf)) {
        return {
          content: buf.toString("base64"),
          size: stat.size,
          encoding: "base64",
          mimeType: mime,
        };
      }
      if (stat.size > MAX_FILE_SIZE) {
        return tooLarge(stat.size, MAX_FILE_SIZE);
      }
      return { content: buf.toString("utf8"), size: stat.size, encoding: "utf8" };
    }

    if (stat.size > MAX_FILE_SIZE) {
      return tooLarge(stat.size, MAX_FILE_SIZE);
    }

    const buf = readFileSync(absPath);
    if (isBinaryBuffer(buf)) {
      return { content: null, size: stat.size, error: "Binary file" };
    }
    return { content: buf.toString("utf8"), size: stat.size, encoding: "utf8" };
  } catch (err: unknown) {
    const code = (err as NodeJS.ErrnoException).code;
    if (code === "ENOENT") {
      return { content: null, size: 0, error: "File not found" };
    }
    if (code === "EACCES") {
      return { content: null, size: 0, error: "Permission denied" };
    }
    return { content: null, size: 0, error: `Read error: ${code || String(err)}` };
  }
}

export function countNodes(node: FileTreeNode): number {
  let count = 1;
  if (node.children) {
    for (const child of node.children) {
      count += countNodes(child);
    }
  }
  return count;
}
