import { describe, it, expect } from "bun:test";
import { mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { ConfigController, computeDiff, type ConfigDiff } from "../src/config-controller";

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
    c.write({ agent: { tool: "codex" } });
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

describe("ConfigController.watch", () => {
  const settle = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));
  // The 100ms debounce plus filesystem-event latency. Generously over both, so a
  // loaded CI box does not turn a real signal into a flake.
  const OBSERVED = 4000;
  // A window a real event would have landed inside several times over, used only
  // by the tests asserting that NOTHING fires.
  const QUIET = 800;

  async function waitFor(predicate: () => boolean): Promise<boolean> {
    const deadline = Date.now() + OBSERVED;
    while (Date.now() < deadline && !predicate()) await settle(20);
    return predicate();
  }

  it("still observes a save after the file was REPLACED BY RENAME", async () => {
    const dir = tmp();
    const path = join(dir, "antgrid.yaml");
    writeFileSync(path, "agent:\n  tool: claude-code\n", "utf8");
    const c = new ConfigController(path);
    let changes = 0;
    c.watch(() => { changes++; });
    try {
      // write() publishes atomically — a scratch file renamed over the target —
      // so the first save REPLACES the inode. On Linux an inotify watch is keyed
      // to the inode it was armed on, so a watch armed on the file path goes
      // deaf here and every later save is invisible for the life of the process.
      // A file-path watch survives this on Windows and macOS (libuv subscribes
      // to the parent directory there), so this is a Linux regression guard —
      // and CI runs the bridge suite on ubuntu-latest.
      c.write({ agent: { tool: "codex" } });
      expect(await waitFor(() => changes >= 1)).toBe(true);
      const afterFirst = changes;
      c.write({ agent: { tool: "claude-code" } });
      expect(await waitFor(() => changes > afterFirst)).toBe(true);
    } finally {
      c.stopWatch();
    }
  }, 30000);

  it("carries the real diff across a rename", async () => {
    const dir = tmp();
    const path = join(dir, "antgrid.yaml");
    writeFileSync(path, "agent:\n  tool: claude-code\n", "utf8");
    const c = new ConfigController(path);
    const diffs: ConfigDiff[] = [];
    c.watch((_r, diff) => { diffs.push(diff); });
    try {
      c.write({ agent: { tool: "claude-code" }, services: [{ name: "dev", command: "bun run dev" }] });
      expect(await waitFor(() => diffs.length >= 1)).toBe(true);
      // Against the seeded lastConfig, not against {} — a fix that changed what
      // wakes the watcher could still have broken what it compares.
      expect(diffs[0]!.servicesAdded.map((s) => s.name)).toEqual(["dev"]);
      expect(diffs[0]!.agentRestartRequired).toBe(false);
    } finally {
      c.stopWatch();
    }
  }, 30000);

  it("reports agentRestartRequired across a rename", async () => {
    const dir = tmp();
    const path = join(dir, "antgrid.yaml");
    writeFileSync(path, "agent:\n  tool: claude-code\n", "utf8");
    const c = new ConfigController(path);
    const diffs: ConfigDiff[] = [];
    c.watch((_r, diff) => { diffs.push(diff); });
    try {
      // The one diff field with a destructive consequence: agent-core stops every
      // running session on it.
      c.write({ agent: { tool: "codex" } });
      expect(await waitFor(() => diffs.length >= 1)).toBe(true);
      expect(diffs[0]!.agentRestartRequired).toBe(true);
    } finally {
      c.stopWatch();
    }
  }, 30000);

  it("observes the scratch file atomicWriteFile renames from", async () => {
    const dir = tmp();
    const path = join(dir, "antgrid.yaml");
    writeFileSync(path, "agent:\n  tool: claude-code\n", "utf8");
    const c = new ConfigController(path);
    let changes = 0;
    c.watch(() => { changes++; });
    try {
      // Accepted, not filtered. Windows names ONLY the scratch file when the
      // rename target does not yet exist, so dropping it would make a config's
      // first creation invisible — and config:write applies nothing itself.
      // Within a real save the debounce folds this into the target's own event.
      writeFileSync(`${path}.${process.pid}.tmp`, "agent:\n  tool: codex\n", "utf8");
      await settle(QUIET);
      expect(changes).toBeGreaterThan(0);
    } finally {
      c.stopWatch();
    }
  }, 30000);

  it("observes a save whose on-disk name differs only by case", async () => {
    const dir = tmp();
    const path = join(dir, "antgrid.yaml");
    const c = new ConfigController(path);
    let changes = 0;
    c.watch(() => { changes++; });
    try {
      // antgrid.yaml is user-authored, so a repo may carry `Antgrid.yaml`. Every
      // other access resolves it case-insensitively on Windows and macOS, so an
      // exact compare here would read the file happily and then go deaf to it.
      writeFileSync(join(dir, "Antgrid.yaml"), "agent:\n  tool: codex\n", "utf8");
      await settle(QUIET);
      expect(changes).toBeGreaterThan(0);
    } finally {
      c.stopWatch();
    }
  }, 30000);

  it("ignores a sibling whose name merely ends in the config's name", async () => {
    const dir = tmp();
    const path = join(dir, "antgrid.yaml");
    const c = new ConfigController(path);
    let changes = 0;
    // Armed before the config exists on purpose: that is the state the old
    // fallback arm's endsWith filter served, and it is the only divergence
    // between a file-path watch and this one that Windows can observe — the
    // inode replacement the test above pins is invisible there.
    c.watch(() => { changes++; });
    try {
      writeFileSync(join(dir, "my-antgrid.yaml"), "agent:\n  tool: codex\n", "utf8");
      await settle(QUIET);
      expect(changes).toBe(0);
    } finally {
      c.stopWatch();
    }
  }, 30000);

  it("observes a config that did not exist when the watch was armed", async () => {
    const dir = tmp();
    const path = join(dir, "antgrid.yaml");
    const c = new ConfigController(path);
    let changes = 0;
    c.watch(() => { changes++; });
    try {
      // A project with no antgrid.yaml yet — what the deleted catch-arm covered.
      // Created in place rather than through write(): a rename onto a target
      // that does not exist yet reports only the SCRATCH name on Windows, so
      // the first appearance of the file is unobservable there by any filter.
      writeFileSync(path, "agent:\n  tool: claude-code\n", "utf8");
      expect(await waitFor(() => changes >= 1)).toBe(true);
    } finally {
      c.stopWatch();
    }
  }, 30000);

  it("coalesces the several raw events one atomic save produces", async () => {
    const dir = tmp();
    const path = join(dir, "antgrid.yaml");
    writeFileSync(path, "agent:\n  tool: claude-code\n", "utf8");
    const c = new ConfigController(path);
    let changes = 0;
    c.watch(() => { changes++; });
    try {
      // A directory watch sees the scratch file's create and the rename onto the
      // target, and two saves land well inside the debounce — one config:changed
      // push, not four.
      c.write({ agent: { tool: "codex" } });
      c.write({ agent: { tool: "claude-code" } });
      expect(await waitFor(() => changes >= 1)).toBe(true);
      await settle(QUIET);
      expect(changes).toBe(1);
    } finally {
      c.stopWatch();
    }
  }, 30000);
});
