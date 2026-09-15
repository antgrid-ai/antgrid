import { existsSync, statSync } from "node:fs";
import { join } from "node:path";
import { platform } from "node:os";

export function findOnPath(bin: string, pathDirs: string[], exts = [".exe", ".cmd", ".bat", ".ps1"]): string | null {
  const candidates = platform() === "win32" ? exts.map((extension) => bin + extension) : [bin];
  for (const directory of pathDirs) {
    for (const candidate of candidates) {
      const path = join(directory, candidate);
      try { if (existsSync(path) && statSync(path).isFile()) return path; } catch { /* Ignore inaccessible PATH entries. */ }
    }
  }
  return null;
}
