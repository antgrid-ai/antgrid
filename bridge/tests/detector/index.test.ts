import { describe, it, expect } from "bun:test";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { runDetectors } from "../../src/detector";

describe("runDetectors", () => {
  it("merges results from multiple detectors (node + docker)", async () => {
    const dir = mkdtempSync(join(tmpdir(), "antgrid-det-ix-"));
    writeFileSync(join(dir, "package.json"), JSON.stringify({
      scripts: { dev: "next dev", test: "vitest run" },
    }), "utf8");
    writeFileSync(join(dir, "docker-compose.yml"), "services:\n  x:\n    image: y\n", "utf8");

    const r = await runDetectors(dir);
    expect(r.services.map((s) => s.name).sort()).toEqual(["compose", "dev"]);
    expect(r.commands.map((c) => c.name).sort()).toEqual(["compose-build", "test"]);
  });

  it("produces empty lists on an unrecognized project", async () => {
    const dir = mkdtempSync(join(tmpdir(), "antgrid-det-empty-"));
    const r = await runDetectors(dir);
    expect(r.services).toEqual([]);
    expect(r.commands).toEqual([]);
    expect(r.ports).toEqual([]);
  });
});
