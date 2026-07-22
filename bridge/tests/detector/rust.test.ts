import { describe, it, expect } from "bun:test";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { rustDetector } from "../../src/detector/rust";

function mkCargo(cargo: string): string {
  const dir = mkdtempSync(join(tmpdir(), "antgrid-det-rs-"));
  writeFileSync(join(dir, "Cargo.toml"), cargo, "utf8");
  return dir;
}

describe("rustDetector", () => {
  it("returns null without Cargo.toml", async () => {
    const dir = mkdtempSync(join(tmpdir(), "antgrid-det-empty-"));
    expect(await rustDetector.detect({ cwd: dir })).toBeNull();
  });

  it("emits cargo run as service and test/build/check/clippy/fmt as commands", async () => {
    const dir = mkCargo(`[package]\nname = "app"\nversion = "0.1.0"\n`);
    const r = await rustDetector.detect({ cwd: dir });
    expect(r!.services.map((s) => s.command)).toContain("cargo run");
    const cmds = r!.commands.map((c) => c.command);
    expect(cmds).toEqual(expect.arrayContaining([
      "cargo test", "cargo build", "cargo check", "cargo clippy", "cargo fmt",
    ]));
  });
});
