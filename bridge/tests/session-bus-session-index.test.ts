// bridge/tests/session-bus-session-index.test.ts
import { test, expect } from "bun:test";
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { SessionBusSessionIndex } from "../src/session-bus/session-index";
import type { SessionEntry } from "../src/protocol";

function tmpAbDir(): string {
  return mkdtempSync(join(tmpdir(), "ab-session-index-"));
}

/** A persisted sessions.json row — just the fields `readPersisted` reads off
 *  disk, matching the fixture shape `session-manager-read-persisted.test.ts`
 *  already uses. */
function seedPersisted(abDir: string, projectId: string, sessions: unknown[]): void {
  const dir = join(abDir, "agents", projectId);
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, "sessions.json"), JSON.stringify({ version: 1, sessions }));
}

/** A live `SessionEntry` for a warm project's stub — only the fields `lookup`
 *  reads (`id`, `name`) matter here, so the rest is cast rather than filled in. */
function liveEntry(id: string, name: string): SessionEntry {
  return { id, name } as unknown as SessionEntry;
}

/** A cold index: `liveSessions` answers null for every project, so every
 *  lookup falls to whatever `hydrate`/`noteProject` recorded on disk. */
function coldIndex(): SessionBusSessionIndex {
  return new SessionBusSessionIndex({ liveSessions: () => null });
}

test("hydrate resolves a session from disk for a project with no warm core", async () => {
  const abDir = tmpAbDir();
  try {
    seedPersisted(abDir, "proj-a", [{ id: "sess-a", name: "A", createdAt: 1, lastUsedAt: 1, archived: false }]);
    seedPersisted(abDir, "proj-b", [{ id: "sess-b", name: "B", createdAt: 1, lastUsedAt: 1, archived: false }]);
    const index = coldIndex();
    await index.hydrate(abDir, [
      { id: "proj-a", label: "Project A" },
      { id: "proj-b", label: "Project B" },
    ]);
    expect(index.lookup("sess-a")).toEqual({ projectId: "proj-a", projectLabel: "Project A", sessionName: "A" });
    expect(index.lookup("sess-b")).toEqual({ projectId: "proj-b", projectLabel: "Project B", sessionName: "B" });
  } finally {
    rmSync(abDir, { recursive: true, force: true });
  }
});

test("an id this machine has never heard of resolves null", async () => {
  const abDir = tmpAbDir();
  try {
    seedPersisted(abDir, "proj-a", [{ id: "sess-a", name: "A", createdAt: 1, lastUsedAt: 1, archived: false }]);
    const index = coldIndex();
    await index.hydrate(abDir, [{ id: "proj-a", label: "Project A" }]);
    expect(index.lookup("no-such-session")).toBeNull();
  } finally {
    rmSync(abDir, { recursive: true, force: true });
  }
});

test("a session created after hydrate still resolves for a warm project", async () => {
  // The staleness MUST-FIX 3 exists to close: SessionManager flushes
  // sessions.json on a debounced timer, so a session created in a warm core
  // minutes after hydrate would be absent from any disk-derived snapshot.
  // `lookup` must not go through the disk map for a project it can ask live.
  const abDir = tmpAbDir();
  try {
    seedPersisted(abDir, "proj-a", []); // nothing on disk yet when hydrate ran
    const live = new Map<string, SessionEntry[]>([["proj-a", [liveEntry("sess-new", "New")]]]);
    const index = new SessionBusSessionIndex({ liveSessions: (id) => live.get(id) ?? null });
    await index.hydrate(abDir, [{ id: "proj-a", label: "Project A" }]);
    expect(index.lookup("sess-new")).toEqual({ projectId: "proj-a", projectLabel: "Project A", sessionName: "New" });
  } finally {
    rmSync(abDir, { recursive: true, force: true });
  }
});

test("a warm project's stale disk snapshot is never consulted", async () => {
  // The mirror of the case above: a session that left a warm project (e.g.
  // deleted) must not keep resolving off a hydrate-time snapshot that still
  // lists it, once that project can be asked live.
  const abDir = tmpAbDir();
  try {
    seedPersisted(abDir, "proj-a", [{ id: "sess-gone", name: "Gone", createdAt: 1, lastUsedAt: 1, archived: false }]);
    const live = new Map<string, SessionEntry[]>([["proj-a", []]]); // warm, and empty right now
    const index = new SessionBusSessionIndex({ liveSessions: (id) => live.get(id) ?? null });
    await index.hydrate(abDir, [{ id: "proj-a", label: "Project A" }]);
    expect(index.lookup("sess-gone")).toBeNull();
  } finally {
    rmSync(abDir, { recursive: true, force: true });
  }
});

test("noteProject registers a project hydrate never saw", () => {
  const index = coldIndex();
  index.noteProject("proj-new", "New Project", [liveEntry("sess-x", "X")]);
  expect(index.lookup("sess-x")).toEqual({ projectId: "proj-new", projectLabel: "New Project", sessionName: "X" });
});

test("forgetProject drops every row it knew about that project", () => {
  const index = coldIndex();
  index.noteProject("proj-gone", "Gone", [liveEntry("sess-x", "X")]);
  index.forgetProject("proj-gone");
  expect(index.lookup("sess-x")).toBeNull();
});
