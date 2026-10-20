import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

// Proves bun --compile embeds the db-serialize worker. The worker is reached
// through `new Worker(...)`, not an import, so it is bundled only when it is
// listed as a build entrypoint, and `bun test` against source cannot show that.
// Built from the repo root with the same entrypoint list as the bridge build,
// because the embedded worker path is the one given on the command line.

const root = resolve(import.meta.dir, "..", "..");
const worker = "packages/antgrid-agents/src/agents/handoff/db-serialize-worker.ts";
const out = mkdtempSync(join(tmpdir(), "antgrid-db-smoke-"));
const exe = join(out, process.platform === "win32" ? "smoke.exe" : "smoke");

try {
  const build = Bun.spawnSync(
    ["bun", "build", "bridge/scripts/smoke-db-serialize-entry.ts", worker, "--compile", "--outfile", exe],
    { cwd: root, stdout: "inherit", stderr: "inherit" },
  );
  if (build.exitCode !== 0) throw new Error("compile failed");
  const run = Bun.spawnSync([exe], { cwd: root, stdout: "pipe", stderr: "pipe" });
  const stdout = run.stdout.toString();
  if (run.exitCode !== 0 || !stdout.includes("db serializer worker ok")) {
    throw new Error(`compiled worker smoke failed (exit ${run.exitCode}): ${stdout}${run.stderr.toString()}`);
  }
  console.log(stdout.trim());
} finally {
  rmSync(out, { recursive: true, force: true });
}
