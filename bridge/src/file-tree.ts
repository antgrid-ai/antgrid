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
};

const MAX_DEPTH = 10;
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

export function loadIgnoreRules(projectRoot: string, configExcludes: string[]): Ignore {
  const ig = ignore();

  ig.add(DEFAULT_IGNORES);
  if (configExcludes.length > 0) ig.add(configExcludes);

  const gitignorePath = join(projectRoot, ".gitignore");
  if (existsSync(gitignorePath)) {
    try {
      const content = readFileSync(gitignorePath, "utf8");
      ig.add(content);
    } catch {
      // ignore read errors
    }
  }

  return ig;
}

export function buildTree(
  absPath: string,
  projectRoot: string,
  ig: Ignore,
  depth = 0,
): FileTreeNode | null {
  if (depth > MAX_DEPTH) return null;

  let stat;
  try {
    stat = lstatSync(absPath);
  } catch {
    return null;
  }

  if (stat.isSymbolicLink()) return null;

  const relPath = relative(projectRoot, absPath);
  const name = absPath === projectRoot ? "" : basename(absPath);

  // Check ignore rules (skip for the root itself)
  if (relPath && relPath !== "." && ig.ignores(relPath.replace(/\\/g, "/"))) {
    return null;
  }

  if (stat.isFile()) {
    return {
      name,
      path: relPath.replace(/\\/g, "/"),
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

    const children: FileTreeNode[] = [];
    for (const entry of entries) {
      const child = buildTree(join(absPath, entry), projectRoot, ig, depth + 1);
      if (child) children.push(child);
    }

    // Sort: directories first, then files, alphabetical within each group
    children.sort((a, b) => {
      if (a.type !== b.type) return a.type === "directory" ? -1 : 1;
      return a.name.localeCompare(b.name);
    });

    return {
      name: name || basename(projectRoot),
      path: relPath.replace(/\\/g, "/") || ".",
      type: "directory",
      children,
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
  // Path traversal protection
  const absPath = resolve(projectRoot, relPath);
  const normalizedRoot = resolve(projectRoot);
  if (absPath !== normalizedRoot && !absPath.startsWith(normalizedRoot + sep)) {
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
