import { describe, it, expect } from "bun:test";
import { mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { ConfigController, computeDiff } from "../src/config-controller";

function tmp() {
  return mkdtempSync(join(tmpdir(), "antgrid-cfg-ctrl-"));
}

describe("ConfigController.read", () => {
  it("returns ok:false with missing:true when file is missing", () => {
    const dir = tmp();
    const c = new ConfigController(join(dir, "antgrid.yaml"));
    const r = c.read();
    expect(r.ok).toBe(false);
    if (!r.ok) expect(r.missing).toBe(true);
  });

  it("returns ok:true with parsed config", () => {
    const dir = tmp();
    const path = join(dir, "antgrid.yaml");
    writeFileSync(path, "agent:\n  tool: claude-code\n", "utf8");
    const c = new ConfigController(path);
    const r = c.read();
    expect(r.ok).toBe(true);
    if (r.ok) expect(r.config.agent?.tool).toBe("claude-code");
  });

  it("returns ok:false with raw + error on invalid yaml", () => {
    const dir = tmp();
    const path = join(dir, "antgrid.yaml");
    writeFileSync(path, "agent:\n  tool: [unterminated\n", "utf8");
    const c = new ConfigController(path);
    const r = c.read();
    expect(r.ok).toBe(false);
    if (!r.ok && !r.missing) {
      expect(r.raw).toContain("unterminated");
      expect(r.error).toBeTruthy();
    }
  });

  it("returns ok:false on schema violation (extra field)", () => {
    const dir = tmp();
    const path = join(dir, "antgrid.yaml");
    writeFileSync(path, "terminals:\n  - name: x\n", "utf8");
    const c = new ConfigController(path);
    const r = c.read();
    expect(r.ok).toBe(false);
    if (!r.ok && !r.missing) {
      expect(r.error).toMatch(/Unrecognized|terminals/);
    }
  });
});

describe("ConfigController.write", () => {
  it("writes valid config atomically", () => {
    const dir = tmp();
    const path = join(dir, "antgrid.yaml");
    const c = new ConfigController(path);
    const r = c.write({ agent: { tool: "claude-code" } });
    expect(r.ok).toBe(true);
    expect(readFileSync(path, "utf8")).toContain("tool: claude-code");
  });

  it("rejects invalid config (extra field) before writing", () => {
    const dir = tmp();
    const path = join(dir, "antgrid.yaml");
    const c = new ConfigController(path);
    const r = c.write({ bogus: true } as never);
    expect(r.ok).toBe(false);
    if (!r.ok) expect(r.errors.length).toBeGreaterThan(0);
  });
});

describe("ConfigController.computeDiff", () => {
  it("flags agentRestartRequired when agent.tool changes", () => {
    const d = computeDiff(
      { agent: { tool: "claude-code" } },
      { agent: { tool: "codex" } },
    );
    expect(d.agentRestartRequired).toBe(true);
  });

  it("does NOT flag agentRestartRequired when only services change", () => {
    const d = computeDiff(
      { agent: { tool: "claude-code" }, services: [] },
      { agent: { tool: "claude-code" }, services: [{ name: "dev", command: "x" }] },
    );
    expect(d.agentRestartRequired).toBe(false);
    expect(d.servicesAdded).toEqual([{ name: "dev", command: "x" }]);
  });

  it("detects removed and modified services", () => {
    const d = computeDiff(
      { services: [{ name: "a", command: "old" }, { name: "b", command: "x" }] },
      { services: [{ name: "b", command: "y" }] },
    );
    expect(d.servicesRemoved).toEqual(["a"]);
    expect(d.servicesModified.map((s) => s.name)).toEqual(["b"]);
  });
});

describe("ConfigController.stopWatch", () => {
  const settle = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

  it("clears a debounced read so nothing touches the file after the watcher closes", async () => {
    const dir = tmp();
    const path = join(dir, "antgrid.yaml");
    writeFileSync(path, "agent:\n  tool: claude-code\n", "utf8");
    const c = new ConfigController(path);
    let changes = 0;
    c.watch(() => { changes++; });

    // Touch, then stop inside the 100ms debounce. The timer used to be a bare
    // closure local that stopWatch could not reach, so it still fired — and its
    // first act is to READ the watched file. For a managed checkout that file
    // sits inside the directory `git worktree remove` is by then sweeping,
    // which is the open handle the whole delete path exists to avoid.
    writeFileSync(path, "agent:\n  tool: codex\n", "utf8");
    // Long enough for fs.watch to deliver and ARM the debounce, short enough
    // that it has not fired. Stopping before the event lands proves nothing:
    // there would be no timer to leak.
    await settle(40);
    c.stopWatch();
    await settle(250);
    expect(changes).toBe(0);
  });

  it("answers rather than throws when the path exists but cannot be read", () => {
    const dir = tmp();
    const path = join(dir, "antgrid.yaml");
    // Passes existsSync, fails readFileSync — standing in for the real race,
    // where the file is unlinked between the two while its checkout is being
    // deleted. `read()` runs from a bare setTimeout in watch(), so a throw here
    // is an uncaught exception on the bridge's main loop.
    mkdirSync(path);
    const c = new ConfigController(path);
    const r = c.read();
    expect(r.ok).toBe(false);
    if (!r.ok) expect(r.missing).toBe(true);
  });
});
