import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { existsSync, mkdtempSync, rmSync, utimesSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { sweepLeakedPtyLibs } from "../src/pty-native-lib";

const SIZE = 64;
const OLD = new Date(Date.now() - 60 * 60_000);

let dir: string;

function put(name: string, size: number, mtime: Date): string {
  const path = join(dir, name);
  writeFileSync(path, new Uint8Array(size));
  utimesSync(path, mtime, mtime);
  return path;
}

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), "pty-sweep-"));
});

afterEach(() => {
  rmSync(dir, { recursive: true, force: true });
});

describe("sweepLeakedPtyLibs", () => {
  test("removes an old Bun-extracted copy of our library", async () => {
    const leaked = put(".2f4c8e1a9b3d7f60-00000000.dll", SIZE, OLD);
    const leakedSo = put(".0123456789abcdef-0000001a.so", SIZE, OLD);
    const upperCounter = put(".0123456789abcdef-0000001A.dylib", SIZE, OLD);

    expect(await sweepLeakedPtyLibs(dir, SIZE)).toBe(3);
    for (const path of [leaked, leakedSo, upperCounter]) expect(existsSync(path)).toBe(false);
  });

  test("leaves a copy young enough to be mid-launch", async () => {
    const fresh = put(".2f4c8e1a9b3d7f60-00000000.dll", SIZE, new Date());

    expect(await sweepLeakedPtyLibs(dir, SIZE)).toBe(0);
    expect(existsSync(fresh)).toBe(true);
  });

  test("leaves another library and files that are not Bun extractions", async () => {
    const otherSize = put(".2f4c8e1a9b3d7f60-00000000.dll", SIZE + 1, OLD);
    const notBunName = put("rust_pty.dll", SIZE, OLD);
    const shortHash = put(".2f4c8e1a-00000000.dll", SIZE, OLD);
    const otherExt = put(".2f4c8e1a9b3d7f60-00000000.node", SIZE, OLD);

    expect(await sweepLeakedPtyLibs(dir, SIZE)).toBe(0);
    for (const path of [otherSize, notBunName, shortHash, otherExt]) expect(existsSync(path)).toBe(true);
  });

  test("does nothing outside a compiled build", async () => {
    const leaked = put(".2f4c8e1a9b3d7f60-00000000.dll", SIZE, OLD);

    expect(await sweepLeakedPtyLibs(dir)).toBe(0);
    expect(existsSync(leaked)).toBe(true);
  });
});
