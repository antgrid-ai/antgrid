import { describe, it, expect } from "bun:test";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { nodeDetector } from "../../src/detector/node";

function makeProject(pkg: object): string {
  const dir = mkdtempSync(join(tmpdir(), "antgrid-det-node-"));
  writeFileSync(join(dir, "package.json"), JSON.stringify(pkg), "utf8");
  return dir;
}

describe("nodeDetector", () => {
  it("returns null without package.json", async () => {
    const dir = mkdtempSync(join(tmpdir(), "antgrid-det-empty-"));
    expect(await nodeDetector.detect({ cwd: dir })).toBeNull();
  });

  it("splits scripts into services and commands", async () => {
    const dir = makeProject({
      scripts: {
        dev: "next dev",
        build: "next build",
        test: "vitest run",
        lint: "eslint .",
        generate: "graphql-codegen",
      },
    });
    const r = await nodeDetector.detect({ cwd: dir });
    expect(r).not.toBeNull();
    expect(r!.services.map((s) => s.name)).toEqual(["dev"]);
    expect(r!.commands.map((c) => c.name).sort()).toEqual(["build", "lint", "test"]);
    expect(r!.skipped.map((s) => s.name)).toEqual(["generate"]);
  });

  it("infers default Next.js port 3000", async () => {
    const dir = makeProject({
      scripts: { dev: "next dev" },
      dependencies: { next: "^14" },
    });
    const r = await nodeDetector.detect({ cwd: dir });
    expect(r!.ports).toContain(3000);
  });

  it("prefers .env PORT over framework default", async () => {
    const dir = makeProject({ scripts: { dev: "next dev" } });
    writeFileSync(join(dir, ".env"), "PORT=4000\n", "utf8");
    const r = await nodeDetector.detect({ cwd: dir });
    expect(r!.ports).toContain(4000);
    expect(r!.ports).not.toContain(3000);
  });
});
