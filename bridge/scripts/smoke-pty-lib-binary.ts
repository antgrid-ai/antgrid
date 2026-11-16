// Proves a compiled bridge leaves nothing in the OS temp dir. bun-pty dlopens
// its native library at import, and a compiled binary can only load the
// embedded copy by extracting it to temp under a fresh name per load.
// `src/pty-native-lib.ts` therefore loads bun-pty only on the first PTY spawn
// and points it at one cached copy through `BUN_PTY_LIB`. Both halves lean on
// bun-pty internals (it honours the variable, and our `require` names the same
// asset it does), so an upgrade can bring the leak back with every unit test
// still green.
import { mkdirSync, mkdtempSync, readdirSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

const binaryArg = process.argv[2];
if (!binaryArg) throw new Error("usage: smoke-pty-lib-binary.ts <bridge-binary>");
const binary = resolve(binaryArg);

const repo = resolve(import.meta.dir, "..", "..");
const root = mkdtempSync(join(tmpdir(), "pty-lib-smoke-"));
// A temp dir of its own, rather than a before/after count of the real one,
// which any concurrent Bun process on the machine can move.
const temp = join(root, "temp");
const abDir = join(root, "antgrid");
const ptyExe = join(root, process.platform === "win32" ? "pty-smoke.exe" : "pty-smoke");

const { BUN_PTY_LIB: _, ...inherited } = process.env;
const env = { ...inherited, TMP: temp, TEMP: temp, TMPDIR: temp, ANTGRID_DIR: abDir };

function run(argv: string[]): string {
  const child = Bun.spawnSync(argv, { env, cwd: root, stdout: "pipe", stderr: "pipe" });
  const stdout = child.stdout.toString();
  const stderr = child.stderr.toString();
  if (child.exitCode !== 0) throw new Error(`${argv.join(" ")} exited ${child.exitCode}: ${stdout}${stderr}`);
  // bun-pty swallows a failed dlopen and only prints this.
  if (stderr.includes("Failed to load lib")) throw new Error(`bun-pty could not load its library: ${stderr}`);
  const leaked = readdirSync(temp);
  if (leaked.length > 0) throw new Error(`${argv.join(" ")} left files in temp: ${leaked.join(", ")}`);
  return stdout;
}

try {
  mkdirSync(temp);

  // A launch that spawns no terminal must not load bun-pty at all.
  run([binary, "--version"]);

  const build = Bun.spawnSync(
    ["bun", "build", "bridge/scripts/smoke-pty-lib-entry.ts", "--compile", "--outfile", ptyExe,
      "--define", 'process.env.ANTGRID_BRIDGE_COMPILED="1"'],
    { cwd: repo, stdout: "inherit", stderr: "inherit" },
  );
  if (build.exitCode !== 0) throw new Error("compile failed");

  // Twice: the first spawn materialises the cache, the second must reuse it.
  for (const _launch of [1, 2]) {
    const stdout = run([ptyExe]);
    if (!stdout.includes("pty-ok")) throw new Error(`pty spawn produced no output: ${stdout}`);
    if (!stdout.includes("BUN_PTY_LIB=<unset>")) throw new Error(`BUN_PTY_LIB leaked into the process env: ${stdout}`);
  }

  const native = join(abDir, "native");
  const cached = readdirSync(native).flatMap((digest) => readdirSync(join(native, digest)).map((f) => join(digest, f)));
  if (cached.length !== 1) throw new Error(`expected exactly one cached pty library, found: ${JSON.stringify(cached)}`);

  console.log(`compiled bridge pty library smoke passed (${cached[0]})`);
} finally {
  rmSync(root, { recursive: true, force: true });
}
