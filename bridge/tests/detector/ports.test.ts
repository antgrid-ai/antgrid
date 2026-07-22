import { describe, it, expect } from "bun:test";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { inferFrameworkPort, envPort, NON_PREVIEW_PORTS } from "../../src/detector/ports";

describe("inferFrameworkPort", () => {
  it("returns framework defaults from deps", () => {
    expect(inferFrameworkPort({ next: "14" })).toBe(3000);
    expect(inferFrameworkPort({ vite: "5" })).toBe(5173);
    expect(inferFrameworkPort({ nuxt: "3" })).toBe(3000);
    expect(inferFrameworkPort({ remix: "2" })).toBe(3000);
    expect(inferFrameworkPort({ astro: "4" })).toBe(4321);
  });
  it("returns null on unknown deps", () => {
    expect(inferFrameworkPort({ express: "4" })).toBeNull();
  });
});

describe("envPort", () => {
  it("reads PORT= from .env", () => {
    const dir = mkdtempSync(join(tmpdir(), "antgrid-env-"));
    writeFileSync(join(dir, ".env"), "FOO=1\nPORT=4040\n", "utf8");
    expect(envPort(dir)).toBe(4040);
  });
  it("falls back to .env.example", () => {
    const dir = mkdtempSync(join(tmpdir(), "antgrid-env-ex-"));
    writeFileSync(join(dir, ".env.example"), "PORT=5555\n", "utf8");
    expect(envPort(dir)).toBe(5555);
  });
  it("returns null when absent", () => {
    const dir = mkdtempSync(join(tmpdir(), "antgrid-noenv-"));
    expect(envPort(dir)).toBeNull();
  });
});

describe("NON_PREVIEW_PORTS", () => {
  it("lists db/cache/debug ports", () => {
    [5432, 3306, 27017, 6379, 9229, 5005, 9092].forEach((p) =>
      expect(NON_PREVIEW_PORTS).toContain(p),
    );
  });
});
