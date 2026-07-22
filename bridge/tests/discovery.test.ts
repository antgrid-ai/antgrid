import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { mkdtempSync, rmSync, existsSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { atomicWriteFile } from "../src/discovery";

let dir: string;
beforeEach(() => { dir = mkdtempSync(join(tmpdir(), "antgrid-disc-")); });
afterEach(() => { rmSync(dir, { recursive: true, force: true }); });

describe("atomicWriteFile", () => {
  test("writes the content to the target path", () => {
    const path = join(dir, "out.json");
    atomicWriteFile(path, "hello");
    expect(readFileSync(path, "utf8")).toBe("hello");
  });

  test("write is atomic (no .tmp left behind)", () => {
    const path = join(dir, "out.json");
    atomicWriteFile(path, "x", { dirMode: 0o700, fileMode: 0o600 });
    expect(existsSync(path + ".tmp")).toBe(false);
    expect(existsSync(path)).toBe(true);
  });

  test("creates missing parent directories", () => {
    const path = join(dir, "nested", "deep", "out.json");
    atomicWriteFile(path, "y");
    expect(readFileSync(path, "utf8")).toBe("y");
  });
});
