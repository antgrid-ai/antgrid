import { describe, it, expect } from "bun:test";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { rubyDetector } from "../../src/detector/ruby";

describe("rubyDetector", () => {
  it("returns null without Gemfile", async () => {
    const dir = mkdtempSync(join(tmpdir(), "antgrid-det-empty-"));
    expect(await rubyDetector.detect({ cwd: dir })).toBeNull();
  });
  it("detects Rails and emits rails server + rspec/db:migrate", async () => {
    const dir = mkdtempSync(join(tmpdir(), "antgrid-det-rb-"));
    writeFileSync(join(dir, "Gemfile"), "gem 'rails'\n", "utf8");
    const r = await rubyDetector.detect({ cwd: dir });
    expect(r!.services.map((s) => s.command)).toContain("bundle exec rails server");
    expect(r!.commands.map((c) => c.command)).toEqual(
      expect.arrayContaining([
        "bundle exec rspec",
        "bundle exec rails db:migrate",
      ]),
    );
    expect(r!.ports).toContain(3000);
  });
});
