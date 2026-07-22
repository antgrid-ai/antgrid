// bridge/tests/session-manager-delete-persisted.test.ts
import { test, expect } from "bun:test";
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, rmSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { SessionManager } from "../src/session-manager";

function seed(storeDir: string, projectId: string, sessions: unknown[]): void {
  const dir = join(storeDir, "agents", projectId);
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, "sessions.json"), JSON.stringify({ version: 1, sessions }));
}

test("deletePersisted removes the row and leaves the rest", async () => {
  const store = mkdtempSync(join(tmpdir(), "antgrid-del-persisted-"));
  try {
    seed(store, "projA", [
      { id: "a", name: "A", createdAt: 1, lastUsedAt: 10, archived: false },
      { id: "b", name: "B", createdAt: 2, lastUsedAt: 20, archived: false },
    ]);
    const removed = await SessionManager.deletePersisted(store, "projA", "a");
    expect(removed).toBe(true);
    const left = await SessionManager.readPersisted(store, "projA", true);
    expect(left.map((s) => s.id)).toEqual(["b"]);
    // Atomic write: the temp file is renamed into place, never left behind, and
    // the result is valid JSON (a torn write would make readPersisted return []).
    expect(existsSync(join(store, "agents", "projA", "sessions.json.tmp"))).toBe(false);
    const onDisk = readFileSync(join(store, "agents", "projA", "sessions.json"), "utf8");
    expect(() => JSON.parse(onDisk)).not.toThrow();
  } finally {
    rmSync(store, { recursive: true, force: true });
  }
});

test("deletePersisted returns false for a missing session id", async () => {
  const store = mkdtempSync(join(tmpdir(), "antgrid-del-persisted-"));
  try {
    seed(store, "projA", [{ id: "a", name: "A", createdAt: 1, lastUsedAt: 10, archived: false }]);
    expect(await SessionManager.deletePersisted(store, "projA", "ghost")).toBe(false);
  } finally {
    rmSync(store, { recursive: true, force: true });
  }
});

test("deletePersisted returns false for a missing file", async () => {
  const store = mkdtempSync(join(tmpdir(), "antgrid-del-persisted-"));
  try {
    expect(await SessionManager.deletePersisted(store, "ghost", "a")).toBe(false);
  } finally {
    rmSync(store, { recursive: true, force: true });
  }
});
