import { describe, it, expect } from "bun:test";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { makefileDetector } from "../../src/detector/makefile";

describe("makefileDetector", () => {
  it("returns null without Makefile", async () => {
    const dir = mkdtempSync(join(tmpdir(), "antgrid-det-empty-"));
    expect(await makefileDetector.detect({ cwd: dir })).toBeNull();
  });

  it("parses top-level targets into commands, classifies dev/watch as services", async () => {
    const dir = mkdtempSync(join(tmpdir(), "antgrid-det-mk-"));
    writeFileSync(join(dir, "Makefile"), [
      "test:",
      "\tgo test ./...",
      "",
      "dev:",
      "\tair",
      "",
      ".PHONY: deploy",
      "deploy:",
      "\t./deploy.sh",
      "",
    ].join("\n"), "utf8");
    const r = await makefileDetector.detect({ cwd: dir });
    expect(r!.services.map((s) => s.name)).toContain("dev");
    expect(r!.commands.map((c) => c.name).sort()).toEqual(["deploy", "test"]);
  });
});
