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

test("a session created while a project was warm still resolves once it goes cold", async () => {
  // The cold edge, which is the only place the fallback set can learn a session
  // that never existed at start: the live answer disappears with the core, so a
  // snapshot taken only at start would answer every session created since as
  // unknown the instant the project is stopped or evicted.
  const abDir = tmpAbDir();
  try {
    seedPersisted(abDir, "proj-a", [{ id: "sess-old", name: "Old", createdAt: 1, lastUsedAt: 1, archived: false }]);
    let warm: SessionEntry[] | null = [liveEntry("sess-old", "Old")];
    const index = new SessionBusSessionIndex({ liveSessions: (id) => (id === "proj-a" ? warm : null) });
    await index.hydrate(abDir, [{ id: "proj-a", label: "Project A" }]);
    index.noteProject("proj-a", "Project A", warm); // core start

    warm = [liveEntry("sess-old", "Old"), liveEntry("sess-new", "New")]; // created while warm
    expect(index.lookup("sess-new")).toEqual({ projectId: "proj-a", projectLabel: "Project A", sessionName: "New" });

    index.noteProject("proj-a", "Project A", warm); // cold edge, before the core is dropped
    warm = null; // stopped or evicted
    expect(index.lookup("sess-new")).toEqual({ projectId: "proj-a", projectLabel: "Project A", sessionName: "New" });
  } finally {
    rmSync(abDir, { recursive: true, force: true });
  }
});

test("a core that cannot answer yet leaves the recorded set alone", async () => {
  // `ProjectCore.listSessions` answers null before a core finishes initialising.
  // Reading that as "this project has zero sessions" would durably overwrite
  // hydrate's correct disk snapshot and leave the project unaddressable while
  // cold, so null must mean "no answer", never "empty".
  const abDir = tmpAbDir();
  try {
    seedPersisted(abDir, "proj-a", [{ id: "sess-a", name: "A", createdAt: 1, lastUsedAt: 1, archived: false }]);
    const index = coldIndex();
    await index.hydrate(abDir, [{ id: "proj-a", label: "Project A" }]);
    index.noteProject("proj-a", "Project A", null);
    expect(index.lookup("sess-a")).toEqual({ projectId: "proj-a", projectLabel: "Project A", sessionName: "A" });
  } finally {
    rmSync(abDir, { recursive: true, force: true });
  }
});

test("forgetSession drops a session deleted while its project was cold", async () => {
  // The cold-delete edge: `noteProject` never runs for a project that is not
  // warm, so without this the deleted row keeps resolving for the rest of the
  // process — `self()` still answers, the peer's next retry applies, and the
  // message log is written back into the directory the delete just swept.
  const abDir = tmpAbDir();
  try {
    seedPersisted(abDir, "proj-a", [
      { id: "sess-doomed", name: "Doomed", createdAt: 1, lastUsedAt: 1, archived: false },
      { id: "sess-kept", name: "Kept", createdAt: 1, lastUsedAt: 1, archived: false },
    ]);
    const index = coldIndex();
    await index.hydrate(abDir, [{ id: "proj-a", label: "Project A" }]);
    index.forgetSession("proj-a", "sess-doomed");
    expect(index.lookup("sess-doomed")).toBeNull();
    expect(index.lookup("sess-kept")).toEqual({ projectId: "proj-a", projectLabel: "Project A", sessionName: "Kept" });
  } finally {
    rmSync(abDir, { recursive: true, force: true });
  }
});

test("forgetSession leaves another project's identically named session alone", () => {
  // The same trap `removeSessionBusSession` has: the id alone does not say
  // whose row it is, and a delete resolved against the wrong project would
  // quietly unaddress a live session somewhere else on the machine.
  const index = coldIndex();
  index.noteProject("proj-a", "A", [liveEntry("sess-shared", "In A")]);
  index.noteProject("proj-b", "B", [liveEntry("sess-shared", "In B")]);
  index.forgetSession("proj-a", "sess-shared");
  expect(index.lookup("sess-shared")).toEqual({ projectId: "proj-b", projectLabel: "B", sessionName: "In B" });
});
