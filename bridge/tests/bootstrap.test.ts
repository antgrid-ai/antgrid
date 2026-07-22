import { describe, it, expect } from "bun:test";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { buildConfigFromBootstrap, type BootstrapIO } from "../src/bootstrap";

function scripted(answers: unknown[]): BootstrapIO {
  const queue = [...answers];
  return {
    async selectAgent() { return queue.shift() as any; },
    async agentFlags()  { return queue.shift() as any; },
    async confirmCandidate() { return queue.shift() as any; },
    async confirmPort()      { return queue.shift() as any; },
    async confirmSave()      { return queue.shift() as any; },
    log: () => {},
  };
}

describe("buildConfigFromBootstrap", () => {
  it("produces a minimal config in a detected Next.js project", async () => {
    const dir = mkdtempSync(join(tmpdir(), "antgrid-boot-"));
    writeFileSync(join(dir, "package.json"), JSON.stringify({
      scripts: { dev: "next dev", test: "vitest run", build: "next build" },
      dependencies: { next: "^14" },
    }), "utf8");

    // `dev` is detected as a long-running process but services are disabled in
    // init, so it is not prompted for and never scaffolded. Only commands and
    // ports are confirmed.
    const io = scripted([
      "claude-code",
      ["--dangerously-skip-permissions"],
      { kind: "command", name: "test", accept: "yes" },
      { kind: "command", name: "build", accept: "yes" },
      { port: 3000, accept: "yes" },
      false,
    ]);

    const cfg = await buildConfigFromBootstrap({ cwd: dir, io });
    expect(cfg.agent?.tool).toBe("claude-code");
    expect(cfg.agent?.flags).toEqual(["--dangerously-skip-permissions"]);
    expect(cfg.services).toBeUndefined();
    expect(cfg.commands?.map((c) => c.name).sort()).toEqual(["build", "test"]);
    expect(cfg.ports?.[0].port).toBe(3000);
  });

  it("never scaffolds a services block (services disabled in init)", async () => {
    const dir = mkdtempSync(join(tmpdir(), "antgrid-boot-noservices-"));
    writeFileSync(join(dir, "package.json"), JSON.stringify({
      scripts: { dev: "next dev" }, dependencies: { next: "14" },
    }), "utf8");
    // Only `dev` (a long-running process) is detected — no command prompts.
    const io = scripted([
      "none",
      [],
      { port: 3000, accept: "yes" },
      false,
    ]);
    const cfg = await buildConfigFromBootstrap({ cwd: dir, io });
    expect(cfg.services).toBeUndefined();
    expect(cfg.commands ?? []).toEqual([]);
  });
});
