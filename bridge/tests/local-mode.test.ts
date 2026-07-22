import { describe, expect, it } from "bun:test";
import { mkdtemp, rm } from "node:fs/promises";
import { existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { spawn } from "node:child_process";
import { computeProjectId } from "../src/project-id";

describe("local mode smoke", () => {
  it("starts the agent with mode=local and publishes host.json", async () => {
    // Create an isolated temp dir as the project folder (no antgrid.yaml needed
    // — the agent falls back to DEFAULT_CONFIG in local mode).
    const dir = await mkdtemp(join(tmpdir(), "antgrid-local-"));

    // Isolate ANTGRID_DIR so the agent writes host.json to a temp dir, never
    // the real ~/.antgrid (which a developer's running host may own).
    const abDir = await mkdtemp(join(tmpdir(), "antgrid-local-home-"));

    const projectId = computeProjectId(dir);

    const agentEntry = resolve(__dirname, "..", "src", "index.ts");

    // Use bun directly — the agent workspace uses Bun and .ts files are not
    // runnable by Node without a TS loader.
    const child = spawn("bun", [agentEntry], {
      env: { ...process.env, ANTGRID_DIR: abDir },
      stdio: ["pipe", "pipe", "pipe"],
    });

    let stderr = "";
    let stdout = "";
    child.stderr.on("data", (b: Buffer) => (stderr += b.toString()));
    child.stdout.on("data", (b: Buffer) => (stdout += b.toString()));

    // Write the local bootstrap payload to stdin then close it.
    const payload =
      JSON.stringify({ firstProject: { projectId, projectPath: dir, mode: "local" } }) + "\n";
    child.stdin.write(payload);
    child.stdin.end();

    // The host publishes host.json under ANTGRID_DIR (= abDir here).
    const discPath = join(abDir, "host.json");

    // Poll up to 10 s (100 × 100 ms) for host.json to appear.
    let discovered = false;
    for (let i = 0; i < 100; i++) {
      if (existsSync(discPath)) {
        discovered = true;
        break;
      }
      await new Promise((r) => setTimeout(r, 100));
    }

    // Tear down the agent gracefully.
    child.kill("SIGTERM");
    await new Promise<void>((r) => child.once("exit", () => r()));

    // Clean up temp dirs (best-effort).
    await rm(dir, { recursive: true, force: true });
    try { await rm(abDir, { recursive: true, force: true }); } catch { /* best-effort */ }

    if (!discovered) {
      // Emit diagnostics to help debug failures.
      console.error("stderr:", stderr.slice(0, 2000));
      console.error("stdout:", stdout.slice(0, 2000));
    }

    expect(discovered).toBe(true);
    // Verify that no OAuth / relay error noise polluted stderr.
    expect(stderr.toLowerCase()).not.toMatch(/oauth/);
  }, 15_000);
});
