import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const directory = mkdtempSync(join(tmpdir(), "antgrid-asset-smoke-"));
try {
  const executable = join(directory, process.platform === "win32" ? "smoke.exe" : "smoke");
  const build = Bun.spawn([process.execPath, "build", join(import.meta.dir, "smoke-assets.ts"), "--compile", "--outfile", executable], { stdout: "inherit", stderr: "inherit" });
  if (await build.exited !== 0) throw new Error("Asset smoke compilation failed");
  const probe = Bun.spawn([executable, join(directory, "assets")], { cwd: directory, stdout: "inherit", stderr: "inherit" });
  if (await probe.exited !== 0) throw new Error("Compiled asset smoke failed");
} finally {
  rmSync(directory, { recursive: true, force: true });
}
