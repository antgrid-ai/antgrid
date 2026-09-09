import { readdirSync, lstatSync, readFileSync, existsSync } from "node:fs";
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
 * `!pattern` cannot re-include what an ancestor's rules excluded. */
export class IgnoreRules {
  private readonly nested = new Map<string, Ignore | null>();

  constructor(
    private readonly projectRoot: string,
    private readonly root: Ignore,
  ) {}

  /** `relPath` is root-relative with `/` separators and never the root itself
   * (`ignore` throws rather than answer for "" or a path that escapes). */
  ignores(relPath: string): boolean {
    if (this.root.ignores(relPath)) return true;
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

export function loadIgnoreRules(projectRoot: string, configExcludes: string[]): IgnoreRules {
  const ig = ignore();
  ig.add(DEFAULT_IGNORES);
  if (configExcludes.length > 0) ig.add(configExcludes);
  const rootGitignore = readGitignore(projectRoot);
  if (rootGitignore) ig.add(rootGitignore);
  return new IgnoreRules(projectRoot, ig);
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
