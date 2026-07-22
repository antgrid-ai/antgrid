import { describe, it, expect } from "bun:test";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { dockerDetector } from "../../src/detector/docker";

describe("dockerDetector", () => {
  it("returns null without Dockerfile or compose file", async () => {
    const dir = mkdtempSync(join(tmpdir(), "antgrid-det-empty-"));
    expect(await dockerDetector.detect({ cwd: dir })).toBeNull();
  });
  it("docker-compose.yml → compose up service + compose build command", async () => {
    const dir = mkdtempSync(join(tmpdir(), "antgrid-det-do-"));
    writeFileSync(join(dir, "docker-compose.yml"), "services:\n  web:\n    image: nginx\n", "utf8");
    const r = await dockerDetector.detect({ cwd: dir });
    expect(r!.services.map((s) => s.command)).toContain("docker compose up");
    expect(r!.commands.map((c) => c.command)).toContain("docker compose build");
  });
  it("Dockerfile only → build command, no service", async () => {
    const dir = mkdtempSync(join(tmpdir(), "antgrid-det-do2-"));
    writeFileSync(join(dir, "Dockerfile"), "FROM node:20\n", "utf8");
    const r = await dockerDetector.detect({ cwd: dir });
    expect(r!.services.length).toBe(0);
    expect(r!.commands.map((c) => c.command)).toContain("docker build .");
  });
});
