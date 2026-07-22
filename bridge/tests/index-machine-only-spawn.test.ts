import { test, expect, afterEach } from "bun:test";
import { mkdtempSync, rmSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

let proc: ReturnType<typeof Bun.spawn> | null = null;
let abDir: string | null = null;

afterEach(() => {
  try { proc?.kill(); } catch {}
  proc = null;
  if (abDir) { rmSync(abDir, { recursive: true, force: true }); abDir = null; }
});

test("project-less payload boots the control plane without opening a project", async () => {
  abDir = mkdtempSync(join(tmpdir(), "antgrid-idx-machineonly-"));
  const entry = join(import.meta.dir, "..", "src", "index.ts");

  proc = Bun.spawn(["bun", entry], {
    env: { ...process.env, ANTGRID_DIR: abDir },
    stdin: "pipe",
    stdout: "pipe",
    stderr: "pipe",
  });

  // Project-less, machine-less payload: warm local host only.
  // Cast needed: Bun's spawn types stdin as `number | FileSink`; we passed
  // "pipe" so it's always a FileSink at runtime.
  const stdin = proc.stdin as import("bun").FileSink;
  stdin.write(new TextEncoder().encode(JSON.stringify({}) + "\n"));
  await stdin.end();

  // Poll for host.json (written the instant the control plane binds). 15s ceiling
  // leaves headroom for a cold `bun` boot on CI. host.json lives directly under
  // ANTGRID_DIR (host-discovery.ts hostFilePath() = join(resolveAbDir(), "host.json")) —
  // NOT under an `agents/` subdir (that's only paired-phones.json).
  const hostJson = join(abDir, "host.json");
  const deadline = Date.now() + 15_000;
  let appeared = false;
  while (Date.now() < deadline) {
    if (existsSync(hostJson)) { appeared = true; break; }
    if (proc.exitCode !== null) break; // process died early
    await new Promise((r) => setTimeout(r, 100));
  }

  expect(proc.exitCode).toBeNull(); // still running — did NOT exit on a missing project
  expect(appeared).toBe(true);
});
