import { test, expect, afterEach } from "bun:test";
import { mkdtempSync, rmSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { HostFileSchema, hostFilePath, writeHostFile, readHostFile, removeHostFile } from "../src/host-discovery";

let prevDir: string | undefined;
let dir: string;
afterEach(() => {
  if (prevDir === undefined) delete process.env.ANTGRID_DIR; else process.env.ANTGRID_DIR = prevDir;
  if (dir) rmSync(dir, { recursive: true, force: true });
});

function withTempAbDir(): string {
  prevDir = process.env.ANTGRID_DIR;
  dir = mkdtempSync(join(tmpdir(), "antgrid-host-"));
  process.env.ANTGRID_DIR = dir;
  return dir;
}

test("writeHostFile then readHostFile round-trips", () => {
  withTempAbDir();
  const path = hostFilePath();
  const data = { version: 1 as const, pid: 123, controlPort: 54321, token: "tok", startedAt: "2026-06-11T00:00:00Z", agentVersion: "0.1.0" };
  writeHostFile(path, data);
  expect(existsSync(path)).toBe(true);
  expect(readHostFile(path)).toEqual(data);
});

test("ownerBuild round-trips, and its absence parses rather than failing", () => {
  withTempAbDir();
  const path = hostFilePath();
  const base = { version: 1 as const, pid: 1, controlPort: 2, token: "t", startedAt: "x", agentVersion: "0.1.0" };
  writeHostFile(path, { ...base, ownerBuild: "1.20662.412 (0f3b1c)" });
  expect(readHostFile(path)?.ownerBuild).toBe("1.20662.412 (0f3b1c)");
  // A host started outside the app carries no stamp; the app reads that as
  // "not this install" and respawns, so it must parse, not fail.
  writeHostFile(path, base);
  expect(readHostFile(path)?.ownerBuild).toBeUndefined();
});

test("readHostFile returns null for missing or malformed file", () => {
  withTempAbDir();
  const path = hostFilePath();
  expect(readHostFile(path)).toBeNull();
});

test("removeHostFile deletes the file (best-effort, no throw when absent)", () => {
  withTempAbDir();
  const path = hostFilePath();
  writeHostFile(path, { version: 1, pid: 1, controlPort: 2, token: "t", startedAt: "x", agentVersion: "0.1.0" });
  removeHostFile(path);
  expect(existsSync(path)).toBe(false);
  expect(() => removeHostFile(path)).not.toThrow();
});

test("HostFileSchema rejects an out-of-range port", () => {
  expect(HostFileSchema.safeParse({ version: 1, pid: 1, controlPort: 0, token: "t", startedAt: "x", agentVersion: "0.1.0" }).success).toBe(false);
});
