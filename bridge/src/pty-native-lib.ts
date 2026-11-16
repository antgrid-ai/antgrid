import { existsSync, readFileSync, statSync } from "node:fs";
import { readdir, stat, unlink } from "node:fs/promises";
import { tmpdir } from "node:os";
import { extname, join } from "node:path";
import { resolveAbDir } from "./antgrid-dir";
import { atomicWriteFile } from "./discovery";

// bun-pty `dlopen`s its native library at import time. In a `--compile` binary
// that library is an embedded `$bunfs` path, and Bun can only load it by
// extracting a copy to the OS temp dir under a fresh random name
// (`.<16 hex>-<n>.dll`) that it never deletes or reuses. So bun-pty is loaded
// only here, on the first PTY spawn, and in a compiled build it is pointed at
// one content-addressed copy through `BUN_PTY_LIB`, which it honours before its
// embedded one.

type BunPty = typeof import("bun-pty");

const PTY_LIB_ENV = "BUN_PTY_LIB";
// Bun's extraction name; the size match in the sweep keeps it to our library.
const LEAKED_NAME = /^\.[0-9a-f]{16}-[0-9a-f]+\.(dll|so|dylib)$/i;
// Clear of a copy another launch has extracted but not yet loaded.
const SWEEP_MIN_AGE_MS = 10 * 60_000;

const compiled = process.env.ANTGRID_BRIDGE_COMPILED === "1";

let bunPty: BunPty | undefined;

export function loadBunPty(): BunPty {
  if (bunPty) return bunPty;
  const inherited = process.env[PTY_LIB_ENV];
  // bun-pty would use an existing inherited path itself, so leave that alone.
  const cached = compiled && !(inherited && existsSync(inherited)) ? materialisePtyLib() : null;
  if (cached) process.env[PTY_LIB_ENV] = cached;
  try {
    bunPty = require("bun-pty") as BunPty;
  } finally {
    // Left set, every PTY's shell would inherit a path into this build's cache,
    // and a bridge run from source in that shell would load the wrong library.
    if (cached) {
      if (inherited === undefined) delete process.env[PTY_LIB_ENV];
      else process.env[PTY_LIB_ENV] = inherited;
    }
  }
  return bunPty;
}

function embeddedPtyLibPath(): string {
  // Copied verbatim from bun-pty's own loader so the bundler resolves the SAME
  // asset (embedded once, not twice). The inline ternary is load-bearing: Bun
  // folds `process.platform`/`process.arch` at compile time and embeds only the
  // matching file (sursaone/bun-pty#19).
  // @ts-ignore - Bun's require returns the embedded path for a binary file
  return require(`bun-pty/rust-pty/target/release/${process.platform === "win32" ? "rust_pty.dll" : process.platform === "darwin" ? (process.arch === "arm64" ? "librust_pty_arm64.dylib" : "librust_pty.dylib") : process.arch === "arm64" ? "librust_pty_arm64.so" : "librust_pty.so"}`);
}

/** The cached copy's path, or null to let bun-pty extract its own: one leaked
 *  file, but terminals still work. */
function materialisePtyLib(): string | null {
  try {
    const embedded = embeddedPtyLibPath();
    const bytes = readFileSync(embedded);
    const digest = new Bun.CryptoHasher("sha256").update(bytes).digest("hex").slice(0, 16);
    const target = join(resolveAbDir(), "native", digest, `rust_pty${extname(embedded)}`);
    if (!holdsBytes(target, bytes)) {
      // Another bridge may win the race and hold the target loaded, which
      // Windows will not let us replace. Its copy is whole, so that is fine.
      try { atomicWriteFile(target, bytes, { dirMode: 0o700 }); } catch {}
    }
    return holdsBytes(target, bytes) ? target : null;
  } catch {
    return null;
  }
}

/** By content, not size: bun-pty swallows a failed dlopen, so a same-size bad
 *  copy accepted here would leave every launch unable to start a terminal. */
function holdsBytes(path: string, bytes: Buffer): boolean {
  try {
    return readFileSync(path).equals(bytes);
  } catch {
    return false;
  }
}

function sizeOf(path: string): number | null {
  try {
    return statSync(path).size;
  } catch {
    return null;
  }
}

function compiledPtyLibSize(): number | null {
  if (!compiled) return null;
  try {
    return sizeOf(embeddedPtyLibPath());
  } catch {
    return null;
  }
}

/** Removes the copies Bun extracted before the library was cached, which stay
 *  in temp forever. Bun never reuses an extracted name, so an unlocked one is
 *  garbage; a copy still held by a running process fails to unlink on Windows
 *  and is skipped. Returns how many were removed. */
export async function sweepLeakedPtyLibs(
  dir = tmpdir(),
  size: number | null = compiledPtyLibSize(),
): Promise<number> {
  if (size === null) return 0;
  const cutoff = Date.now() - SWEEP_MIN_AGE_MS;
  let removed = 0;
  for (const name of await readdir(dir).catch(() => [] as string[])) {
    if (!LEAKED_NAME.test(name)) continue;
    const path = join(dir, name);
    try {
      const st = await stat(path);
      if (!st.isFile() || st.size !== size || st.mtimeMs > cutoff) continue;
      await unlink(path);
      removed++;
    } catch {
      // Locked by a live process, or gone already.
    }
  }
  return removed;
}
