import { describe, it, expect } from "bun:test";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { goDetector } from "../../src/detector/go";

describe("goDetector", () => {
  it("returns null without go.mod", async () => {
    const dir = mkdtempSync(join(tmpdir(), "antgrid-det-empty-"));
    expect(await goDetector.detect({ cwd: dir })).toBeNull();
  });
  it("emits go run service and go test/build/vet commands", async () => {
    const dir = mkdtempSync(join(tmpdir(), "antgrid-det-go-"));
    writeFileSync(join(dir, "go.mod"), "module example.com/x\n", "utf8");
    const r = await goDetector.detect({ cwd: dir });
    expect(r!.services.map((s) => s.command)).toContain("go run .");
    expect(r!.commands.map((c) => c.command)).toEqual(
      expect.arrayContaining(["go test ./...", "go build ./...", "go vet ./..."]),
    );
  });
});
