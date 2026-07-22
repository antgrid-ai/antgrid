import { test, expect } from "bun:test";
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { SessionManager } from "../src/session-manager";

function seed(storeDir: string, projectId: string, sessions: unknown[]): void {
  const dir = join(storeDir, "agents", projectId);
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, "sessions.json"), JSON.stringify({ version: 1, sessions }));
}

test("readPersisted returns active sessions sorted by lastUsedAt desc, running:false", async () => {
  const store = mkdtempSync(join(tmpdir(), "antgrid-read-persisted-"));
  try {
    seed(store, "projA", [
      { id: "a", name: "A", createdAt: 1, lastUsedAt: 10, archived: false },
      { id: "b", name: "B", createdAt: 2, lastUsedAt: 99, archived: false },
      { id: "c", name: "C", createdAt: 3, lastUsedAt: 50, archived: true },
    ]);
    const out = await SessionManager.readPersisted(store, "projA");
    expect(out.map((s) => s.id)).toEqual(["b", "a"]); // archived excluded, recency order
    expect(out.every((s) => s.running === false)).toBe(true);
  } finally {
    rmSync(store, { recursive: true, force: true });
  }
});

test("readPersisted includeArchived returns archived too", async () => {
  const store = mkdtempSync(join(tmpdir(), "antgrid-read-persisted-"));
  try {
    seed(store, "projA", [
      { id: "a", name: "A", createdAt: 1, lastUsedAt: 10, archived: false },
      { id: "c", name: "C", createdAt: 3, lastUsedAt: 50, archived: true },
    ]);
    const out = await SessionManager.readPersisted(store, "projA", true);
    expect(out.map((s) => s.id)).toEqual(["c", "a"]);
  } finally {
    rmSync(store, { recursive: true, force: true });
  }
});

test("readPersisted carries agentSessionId through for a chat session", async () => {
  const store = mkdtempSync(join(tmpdir(), "antgrid-read-persisted-"));
  try {
    seed(store, "projA", [
      {
        id: "a",
        name: "A",
        createdAt: 1,
        lastUsedAt: 10,
        archived: false,
        mode: "chat",
        tool: "claude",
        agentSessionId: "claude-sess-1",
      },
    ]);
    const out = await SessionManager.readPersisted(store, "projA");
    // The peek is the ONLY session source a second device has before focus, and
    // the app gates transcript hydration on agentSessionId (see the app's
    // hydrateAttachedChatIfNeeded) — dropping it here renders an empty
    // transcript for a session started on another device.
    expect(out[0]?.agentSessionId).toBe("claude-sess-1");
  } finally {
    rmSync(store, { recursive: true, force: true });
  }
});

test("readPersisted returns [] for a missing file", async () => {
  const store = mkdtempSync(join(tmpdir(), "antgrid-read-persisted-"));
  try {
    expect(await SessionManager.readPersisted(store, "ghost")).toEqual([]);
  } finally {
    rmSync(store, { recursive: true, force: true });
  }
});

test("readPersisted keeps valid rows while skipping a malformed one", async () => {
  const store = mkdtempSync(join(tmpdir(), "antgrid-read-persisted-"));
  try {
    seed(store, "projA", [
      { id: "a", name: "A", createdAt: 1, lastUsedAt: 10, archived: false },
      { id: "", name: "no-id", createdAt: 2, lastUsedAt: 20, archived: false }, // dropped
      "not-an-object", // dropped
      { id: "b", name: "B", createdAt: 3, lastUsedAt: 5, archived: false },
    ]);
    const out = await SessionManager.readPersisted(store, "projA");
    expect(out.map((s) => s.id)).toEqual(["a", "b"]);
  } finally {
    rmSync(store, { recursive: true, force: true });
  }
});
