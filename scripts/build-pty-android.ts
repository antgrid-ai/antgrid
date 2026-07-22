/**
 * Build 16 KB-aligned Android `libportable_pty_rs.so` overrides.
 *
 *   bun run scripts/build-pty-android.ts [--targets arm64,x64,arm] [--force]
 *
 * Why this exists
 * ---------------
 * `portable_pty`'s build hook downloads a prebuilt `.so` from its GitHub
 * releases. Those binaries are linked with a 4 KB max-page-size, so they fail
 * Android 15's 16 KB page-size alignment check ("LOAD segment not aligned")
 * and block Play submission. (Everything else we bundle — Flutter engine,
 * ghostty_vte, ML Kit/CameraX/DataStore — is already 16 KB-aligned.)
 *
 * The hook checks a local `.prebuilt/<platform>/<lib>` directory BEFORE
 * downloading. This script rebuilds the crate from source with NDK r28+ (whose
 * lld defaults to 16 KB) plus explicit `max-page-size=16384`, and drops the
 * result there. Tracking issue upstream: kingwill101/dart_terminal#17.
 *
 * Idempotent: skips a target whose prebuilt already exists and is aligned.
 * Non-fatal: if Rust or a 16 KB-capable NDK is missing, it warns and exits 0
 * so web-only `npm run setup` runs are not blocked.
 */
import { existsSync, mkdirSync, readFileSync, copyFileSync, rmSync, cpSync, writeFileSync, readdirSync } from "node:fs";
import { resolve, join } from "node:path";
import { spawnSync, type SpawnSyncReturns } from "node:child_process";
import { tmpdir, homedir } from "node:os";

const ROOT = resolve(import.meta.dirname, "..");
const APP = resolve(ROOT, "app");
// API floor the override lib is compiled against. Must equal the app's
// flutter.minSdkVersion (currently 24) AND stay >= 23: portable_pty links
// openpty/forkpty, which Bionic only exposes from API 23. minSdkVersion lives
// in Flutter config as a symbol (not a literal we can parse), so this is
// duplicated here; a wrong value surfaces as a missing clang wrapper →
// existsSync(clang) guard → "failed" (falls back to upstream), not silently.
const ANDROID_API = 24;
const MIN_NDK_MAJOR = 28; // r28+ defaults LOAD p_align to 16 KB
const PAGE = 16384;
const IS_WIN = process.platform === "win32";

interface Target {
  /** CLI alias */ alias: string;
  /** Rust target triple */ triple: string;
  /** NDK clang wrapper stem (NB: differs from triple for armv7) */ clangStem: string;
  /** `.prebuilt/<label>/` directory name the hook searches */ platformLabel: string;
}

const TARGETS: Record<string, Target> = {
  arm64: { alias: "arm64", triple: "aarch64-linux-android", clangStem: "aarch64-linux-android", platformLabel: "android-arm64" },
  x64: { alias: "x64", triple: "x86_64-linux-android", clangStem: "x86_64-linux-android", platformLabel: "android-x64" },
  arm: { alias: "arm", triple: "armv7-linux-androideabi", clangStem: "armv7a-linux-androideabi", platformLabel: "android-arm" },
};

const LIB_NAME = "libportable_pty_rs.so";

function warn(m: string) { console.warn(`  [build-pty-android] ${m}`); }
function info(m: string) { console.log(`  [build-pty-android] ${m}`); }

function run(cmd: string, args: string[], opts: { cwd?: string; env?: NodeJS.ProcessEnv } = {}): SpawnSyncReturns<string> {
  const env = opts.env ?? process.env;
  if (IS_WIN) {
    // shell:true is load-bearing on Windows — cargo/rustup/where are .cmd/.bat
    // shims spawnSync cannot launch directly. But shell:true makes cmd.exe
    // word-split the command line, so quote any token with whitespace (NDK or
    // tmp paths under "C:\Program Files" / a spaced username). env values ride
    // the environment block, not the command line, so they need no quoting.
    const q = (s: string) => (/\s/.test(s) ? `"${s}"` : s);
    return spawnSync(q(cmd), args.map(q), { encoding: "utf8", cwd: opts.cwd, env, shell: true });
  }
  return spawnSync(cmd, args, { encoding: "utf8", cwd: opts.cwd, env });
}

function which(cmd: string): boolean {
  const r = run(IS_WIN ? "where" : "which", [cmd]);
  return r.status === 0;
}

/** portable_pty version resolved in app/pubspec.lock (e.g. "0.0.5"). */
function resolvePortablePtyVersion(): string {
  const lock = readFileSync(join(APP, "pubspec.lock"), "utf8");
  // Isolate portable_pty's own block: package keys are 2-space-indented, their
  // fields 4+. Slice from the key to the next 2-space sibling key (or EOF), then
  // read the 4-space `version:` inside — so we never pick up a neighbor's.
  // Line-anchored (^...$/m) rather than literal "\n" so CRLF locks parse too.
  const key = lock.match(/^ {2}portable_pty:[ \t]*$/m);
  if (!key) throw new Error("portable_pty not found in app/pubspec.lock");
  const rest = lock.slice(key.index! + key[0].length);
  const nextSibling = rest.search(/^ {2}\S/m);
  const block = nextSibling === -1 ? rest : rest.slice(0, nextSibling);
  const m = block.match(/^ {4}version:\s*"?([0-9][^"\s]*)"?/m);
  if (!m) throw new Error("Could not find portable_pty version in app/pubspec.lock");
  return m[1];
}

/** Locate the unpacked portable_pty crate (vendored path override or pub cache). */
function resolveCrateDir(version: string): string {
  // The app pins portable_pty via a `dependency_overrides` path entry to a
  // vendored fork (packages/portable_pty/), so the crate lives in-repo and is
  // ABSENT from the pub cache. Check the override location first; fall back to
  // the pub cache for an unoverridden (pristine pub.dev) resolution.
  const vendored = join(ROOT, "packages", "portable_pty", "rust");
  if (existsSync(join(vendored, "Cargo.toml"))) return vendored;

  const caches = [
    process.env.PUB_CACHE,
    IS_WIN ? join(process.env.LOCALAPPDATA ?? join(homedir(), "AppData/Local"), "Pub/Cache") : undefined,
    join(homedir(), ".pub-cache"),
  ].filter(Boolean) as string[];
  for (const c of caches) {
    const dir = join(c, "hosted", "pub.dev", `portable_pty-${version}`, "rust");
    if (existsSync(join(dir, "Cargo.toml"))) return dir;
  }
  throw new Error(
    `portable_pty-${version}/rust not found in packages/portable_pty/rust or the pub cache. ` +
      `Run \`flutter pub get\` in app/ first.`,
  );
}

/** Resolve the Android SDK root from local.properties or env. */
function resolveSdkRoot(): string | null {
  const lp = join(APP, "android", "local.properties");
  if (existsSync(lp)) {
    const m = readFileSync(lp, "utf8").match(/^sdk\.dir=(.+)$/m);
    if (m) return m[1].replace(/\\\\/g, "\\").replace(/\\:/g, ":").trim();
  }
  return process.env.ANDROID_SDK_ROOT ?? process.env.ANDROID_HOME ?? null;
}

/** Highest installed NDK with major >= MIN_NDK_MAJOR. */
function resolveNdk(): { dir: string; major: number } | null {
  const explicit = process.env.ANDROID_NDK_HOME ?? process.env.ANDROID_NDK_ROOT;
  const candidates: string[] = [];
  if (explicit) candidates.push(explicit);
  const sdk = resolveSdkRoot();
  if (sdk) {
    const ndkRoot = join(sdk, "ndk");
    if (existsSync(ndkRoot)) {
      for (const v of readdirSync(ndkRoot)) candidates.push(join(ndkRoot, v));
    }
  }
  let best: { dir: string; major: number } | null = null;
  for (const dir of candidates) {
    const ver = dir.split(/[\\/]/).pop() ?? "";
    const major = parseInt(ver.split(".")[0], 10);
    if (!Number.isFinite(major)) continue;
    if (major >= MIN_NDK_MAJOR && existsSync(join(dir, "toolchains", "llvm"))) {
      if (!best || major > best.major) best = { dir, major };
    }
  }
  return best;
}

function ndkHostTag(): string {
  switch (process.platform) {
    case "win32": return "windows-x86_64";
    case "darwin": return "darwin-x86_64";
    default: return "linux-x86_64";
  }
}

function ndkBin(ndkDir: string): string {
  return join(ndkDir, "toolchains", "llvm", "prebuilt", ndkHostTag(), "bin");
}

function clangPath(ndkDir: string, t: Target): string {
  const base = `${t.clangStem}${ANDROID_API}-clang`;
  return join(ndkBin(ndkDir), IS_WIN ? `${base}.cmd` : base);
}

function readelfPath(ndkDir: string): string {
  return join(ndkBin(ndkDir), IS_WIN ? "llvm-readelf.exe" : "llvm-readelf");
}

/**
 * Max LOAD-segment p_align (bytes) of an ELF, via llvm-readelf.
 * Returns null when readelf could not run — a tooling failure that must NOT be
 * conflated with a genuinely 4 KB-aligned (0x1000) library.
 */
function maxLoadAlign(readelf: string, so: string): number | null {
  const r = run(readelf, ["-lW", so]);
  if (r.status !== 0) return null;
  let max = 0;
  for (const line of r.stdout.split(/\r?\n/)) {
    const cols = line.trim().split(/\s+/);
    if (cols[0] !== "LOAD") continue;
    const a = parseInt(cols[cols.length - 1], 16);
    if (Number.isFinite(a) && a > max) max = a;
  }
  return max;
}

function ensureRustTarget(triple: string): boolean {
  const installed = run("rustup", ["target", "list", "--installed"]);
  if (installed.status === 0 && installed.stdout.includes(triple)) return true;
  info(`rustup target add ${triple}`);
  return run("rustup", ["target", "add", triple]).status === 0;
}

function buildTarget(t: Target, crateDir: string, ndk: { dir: string; major: number }, readelf: string, force: boolean): "built" | "skipped" | "failed" {
  const destDir = join(APP, ".prebuilt", t.platformLabel);
  const dest = join(destDir, LIB_NAME);
  if (!force && existsSync(dest)) {
    const cached = maxLoadAlign(readelf, dest);
    if (cached !== null && cached >= PAGE) {
      info(`${t.platformLabel}: already aligned, skipping (use --force to rebuild)`);
      return "skipped";
    }
  }
  if (!ensureRustTarget(t.triple)) { warn(`${t.platformLabel}: could not add rust target ${t.triple}`); return "failed"; }

  const clang = clangPath(ndk.dir, t);
  if (!existsSync(clang)) { warn(`${t.platformLabel}: clang wrapper not found: ${clang}`); return "failed"; }

  // Build in a temp copy: build.rs writes bindings.h into the crate dir, and we
  // do not want to mutate the read-only pub cache.
  const work = join(tmpdir(), `pty-${t.platformLabel}`);
  rmSync(work, { recursive: true, force: true });
  cpSync(crateDir, work, { recursive: true });
  mkdirSync(join(work, ".cargo"), { recursive: true });
  const fwd = clang.replace(/\\/g, "/");
  writeFileSync(join(work, ".cargo", "config.toml"),
    `[target.${t.triple}]\n` +
    `linker = "${fwd}"\n` +
    // NDK r28+ already defaults to 16 KB; set it explicitly so the alignment
    // does not silently regress if the toolchain default changes.
    `rustflags = ["-C", "link-arg=-Wl,-z,max-page-size=${PAGE}", "-C", "link-arg=-Wl,-z,common-page-size=${PAGE}"]\n`);

  const triplEnv = t.triple.replace(/-/g, "_");
  const env: NodeJS.ProcessEnv = {
    ...process.env,
    [`CC_${triplEnv}`]: clang,
    [`AR_${triplEnv}`]: join(ndkBin(ndk.dir), IS_WIN ? "llvm-ar.exe" : "llvm-ar"),
  };

  info(`${t.platformLabel}: cargo build --release --target ${t.triple} (NDK r${ndk.major})`);
  const build = run("cargo", ["build", "--release", "--target", t.triple], { cwd: work, env });
  if (build.status !== 0) { warn(`${t.platformLabel}: cargo build failed\n${build.stderr ?? ""}`); return "failed"; }

  const out = join(work, "target", t.triple, "release", LIB_NAME);
  if (!existsSync(out)) { warn(`${t.platformLabel}: expected output missing: ${out}`); return "failed"; }
  const align = maxLoadAlign(readelf, out);
  if (align === null) { warn(`${t.platformLabel}: could not run llvm-readelf to verify alignment (${readelf})`); return "failed"; }
  if (align < PAGE) { warn(`${t.platformLabel}: built lib is 0x${align.toString(16)}-aligned, expected >= ${PAGE}`); return "failed"; }

  mkdirSync(destDir, { recursive: true });
  copyFileSync(out, dest);
  info(`${t.platformLabel}: wrote ${dest} (p_align=0x${align.toString(16)})`);
  return "built";
}

/**
 * The hook does not track `.prebuilt/` as an input, so a previously-cached
 * (4 KB) build would otherwise survive. Drop the portable_pty hook cache so the
 * next `flutter build` re-runs it and picks up the override. (A first-ever
 * setup run has no cache; this is a no-op then.)
 */
function invalidateHookCache() {
  for (const p of [
    join(APP, ".dart_tool", "hooks_runner", "portable_pty"),
    join(APP, ".dart_tool", "hooks_runner", "shared", "portable_pty"),
  ]) {
    rmSync(p, { recursive: true, force: true });
  }
}

function main() {
  const args = process.argv.slice(2);
  const force = args.includes("--force");
  const targetsArg = args.find((a) => a.startsWith("--targets="))?.split("=")[1]
    ?? (args.includes("--targets") ? args[args.indexOf("--targets") + 1] : undefined);
  const aliases = (targetsArg ?? "arm64,x64").split(",").map((s) => s.trim()).filter(Boolean);

  const selected: Target[] = [];
  for (const a of aliases) {
    const t = TARGETS[a];
    if (!t) { warn(`unknown target "${a}" (known: ${Object.keys(TARGETS).join(", ")})`); continue; }
    selected.push(t);
  }
  if (selected.length === 0) { warn("no valid targets"); return; }

  console.log("=== build-pty-android (16 KB-aligned PTY overrides) ===");

  if (!which("rustup") || !which("cargo")) {
    warn("Rust (rustup/cargo) not found — skipping. Install from https://rustup.rs to enable 16 KB Android builds.");
    return;
  }
  const ndk = resolveNdk();
  if (!ndk) {
    warn(`No NDK r${MIN_NDK_MAJOR}+ found (checked ANDROID_NDK_HOME and <sdk>/ndk/*). Skipping.`);
    return;
  }
  const readelf = readelfPath(ndk.dir);

  let version: string, crateDir: string;
  try {
    version = resolvePortablePtyVersion();
    crateDir = resolveCrateDir(version);
  } catch (e) {
    warn(`${(e as Error).message} — skipping.`);
    return;
  }
  info(`portable_pty ${version} @ ${crateDir}`);

  // Per-target try/catch: a filesystem error (e.g. a locked temp dir from a
  // prior cargo run on Windows) downgrades that one target to "failed" instead
  // of aborting the whole run and the remaining ABIs.
  const results = selected.map((t) => {
    try {
      return [t.platformLabel, buildTarget(t, crateDir, ndk, readelf, force)] as const;
    } catch (e) {
      warn(`${t.platformLabel}: ${(e as Error).message}`);
      return [t.platformLabel, "failed"] as const;
    }
  });
  if (results.some(([, r]) => r === "built")) invalidateHookCache();

  console.log("\n  Summary:");
  for (const [label, r] of results) console.log(`    ${label}: ${r}`);
  if (results.some(([, r]) => r === "failed")) {
    console.log("\n  Some targets failed; the 4 KB upstream prebuilt will be used for those ABIs.");
  } else {
    console.log("\n  Done. Run a clean `flutter build apk` if you had already built before this ran.");
  }
}

// Best-effort by contract: never let an unexpected throw break `npm run setup`.
try {
  main();
} catch (e) {
  warn(`unexpected error, skipping: ${(e as Error).stack ?? (e as Error).message}`);
}
