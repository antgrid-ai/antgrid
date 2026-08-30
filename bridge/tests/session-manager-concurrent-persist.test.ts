// bridge/tests/session-manager-concurrent-persist.test.ts
//
// sessions.json has more than one writer — the debounced synchronous flush, the
// awaited publish on the isolated-create/delete paths, and the static
// deletePersisted with no live core at all. Every other suite drives exactly one
// of them at a time, which is why they all passed while a publish could be torn
// apart by its sibling.
import { test, expect } from "bun:test";
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, readdirSync, rmSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { SessionManager } from "../src/session-manager";

const PROJECT = "projConcurrent";

function tempStore(): string {
  return mkdtempSync(join(tmpdir(), "antgrid-concurrent-persist-"));
}

function projectDir(store: string): string {
  return join(store, "agents", PROJECT);
}

function sessionsPath(store: string): string {
  return join(projectDir(store), "sessions.json");
}

function makeManager(store: string): SessionManager {
  return new SessionManager({
    projectId: PROJECT,
    storeDir: store,
    projectPath: store,
    terminalManager: {
      spawn: (cfg: { terminalId?: string }) => cfg.terminalId!,
      kill: () => {},
      forget: () => {},
      treeKilled: () => Promise.resolve(),
      has: () => false,
    } as any,
    agentSpec: { command: "claude", name: "claude-code" },
    sendMessage: () => {},
  });
}

/** The awaited publish, which is private because no client drives it directly —
 *  it is the commit half of an isolated create/delete. */
function publishAwaited(sm: SessionManager): Promise<void> {
  return (sm as any).flushNowOrThrow();
}

/** Everything the project dir holds that is not the published file: a scratch
 *  file surviving any write path means a writer left one behind. */
function scratchLeftBehind(store: string): string[] {
  return readdirSync(projectDir(store)).filter((e) => e !== "sessions.json");
}

function seed(store: string, sessions: unknown[]): void {
  mkdirSync(projectDir(store), { recursive: true });
  writeFileSync(sessionsPath(store), JSON.stringify({ version: 1, sessions }));
}

test("a flush firing inside an awaited publish leaves a complete file, and the publish still resolves", async () => {
  const store = tempStore();
  try {
    const sm = makeManager(store);
    // Large enough that the publish is not over within a single tick — the
    // hazard is a timer landing between writing the scratch file and renaming it.
    const ids: string[] = [];
    for (let i = 0; i < 200; i++) ids.push((sm.create(`Session ${i}`) as any).id as string);

    // One pass proves nothing: the window is narrow, so the property is asserted
    // over enough rounds that an unserialized writer is certain to land in one.
    for (let round = 0; round < 50; round++) {
      const publish = publishAwaited(sm);
      // Re-arm the debounce after the awaited writer's synchronous prologue has
      // cleared it, so the sibling writer has real work to publish.
      sm.rename(ids[round % ids.length]!, `Round ${round}`);
      const sibling = new Promise<void>((resolve) => {
        setTimeout(() => { sm.flushNow(); resolve(); }, 0);
      });

      const [published] = await Promise.allSettled([publish, sibling]);
      // Unserialized, the sibling renames the shared scratch file away and the
      // awaited publish fails ENOENT — rolling back a session that was fine.
      expect(published!.status === "rejected" ? String((published as PromiseRejectedResult).reason) : "fulfilled")
        .toBe("fulfilled");

      const raw = readFileSync(sessionsPath(store), "utf8");
      // A blended document is the other outcome, and it is worse than a throw:
      // parsePersistedContent answers it with [] and every session disappears.
      const parsed = JSON.parse(raw) as { sessions: unknown[] };
      expect(parsed.sessions.length).toBe(ids.length);
      expect(scratchLeftBehind(store)).toEqual([]);
    }
  } finally {
    rmSync(store, { recursive: true, force: true });
  }
});

test("concurrent deletePersisted calls compose instead of resurrecting a row", async () => {
  const store = tempStore();
  try {
    seed(store, [
      { id: "a", name: "A", createdAt: 1, lastUsedAt: 10, archived: false },
      { id: "b", name: "B", createdAt: 2, lastUsedAt: 20, archived: false },
      { id: "c", name: "C", createdAt: 3, lastUsedAt: 30, archived: false },
    ]);
    // host-server dispatches the sessions-delete RPC fire-and-forget, so two
    // Recent-tab deletes on a cold project genuinely run at once.
    const [removedA, removedB] = await Promise.all([
      SessionManager.deletePersisted(store, PROJECT, "a"),
      SessionManager.deletePersisted(store, PROJECT, "b"),
    ]);
    expect(removedA).toBe(true);
    expect(removedB).toBe(true);

    const left = await SessionManager.readPersisted(store, PROJECT, true);
    expect(left.map((s) => s.id)).toEqual(["c"]);
    expect(scratchLeftBehind(store)).toEqual([]);
  } finally {
    rmSync(store, { recursive: true, force: true });
  }
});

test("deletePersisted racing a live manager's flush leaves a parseable file", async () => {
  const store = tempStore();
  try {
    const sm = makeManager(store);
    for (let i = 0; i < 60; i++) sm.create(`Session ${i}`);
    await publishAwaited(sm);
    const victims = sm.list().map((s) => s.id);

    for (let round = 0; round < 25; round++) {
      const deleted = SessionManager.deletePersisted(store, PROJECT, victims[round]!);
      sm.rename(victims[victims.length - 1]!, `Round ${round}`);
      await Promise.all([deleted, publishAwaited(sm)]);

      const raw = readFileSync(sessionsPath(store), "utf8");
      expect(() => JSON.parse(raw)).not.toThrow();
      expect((JSON.parse(raw) as { sessions: unknown[] }).sessions.length).toBeGreaterThan(0);
      expect(scratchLeftBehind(store)).toEqual([]);
    }
  } finally {
    rmSync(store, { recursive: true, force: true });
  }
});

test("a debounced flush publishes state as of when it runs, not when it was armed", async () => {
  const store = tempStore();
  try {
    const sm = makeManager(store);
    const s = sm.create() as any;
    await publishAwaited(sm);

    // The whole serialization rests on flush() reading `entries` inside its own
    // body: a queued flush must publish current state, never the set as of the
    // moment its timer was armed. Hoisting that snapshot to the call site would
    // silently start republishing stale rows over newer ones.
    sm.rename(s.id, "Armed");
    await publishAwaited(sm);
    sm.rename(s.id, "Final");
    await new Promise((r) => setTimeout(r, 400));

    expect(makeManager(store).list()[0]!.name).toBe("Final");
    expect(scratchLeftBehind(store)).toEqual([]);
  } finally {
    rmSync(store, { recursive: true, force: true });
  }
});

test.skipIf(process.platform === "win32")("both writers publish the file 0o600", async () => {
  const store = tempStore();
  try {
    const sm = makeManager(store);
    sm.create();
    await publishAwaited(sm);
    expect(statSync(sessionsPath(store)).mode & 0o777).toBe(0o600);

    sm.rename(sm.list()[0]!.id, "Renamed");
    sm.flushNow();
    expect(statSync(sessionsPath(store)).mode & 0o777).toBe(0o600);
  } finally {
    rmSync(store, { recursive: true, force: true });
  }
});
