// Launches the Aspire apphost with ANTGRID_APP_TARGETS set, cross-platform.
// npm's inline env-var syntax differs between cmd.exe and sh, so a script is
// the portable way to set the flag the package.json convenience scripts need.
//
//   bun run scripts/aspire-targets.ts <targets>
//     e.g. "android"  or  "windows,android"
//
// apphost.ts reads ANTGRID_APP_TARGETS to decide which Flutter app resources
// to start (see aspire/apphost.ts → parseTargets).
import { spawn } from "node:child_process";
import { resolve } from "node:path";

const targets = process.argv[2];
if (!targets) {
  console.error('usage: aspire-targets <comma-separated targets>  e.g. "windows,android"');
  process.exit(2);
}

const aspireDir = resolve(import.meta.dir, "..", "aspire");
// shell:true on Windows so the `aspire` launcher shim (aspire.cmd) resolves.
const child = spawn("aspire", ["run"], {
  cwd: aspireDir,
  stdio: "inherit",
  env: { ...process.env, ANTGRID_APP_TARGETS: targets },
  shell: process.platform === "win32",
});
child.on("exit", (code, signal) => process.exit(code ?? (signal ? 1 : 0)));
