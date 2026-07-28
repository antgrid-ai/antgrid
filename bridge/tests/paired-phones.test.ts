import { describe, it, expect } from "bun:test";
import { mkdtempSync, rmSync, statSync, writeFileSync, mkdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { loadPairedPhones } from "../src/paired-phones";
import { __setRootForTest } from "../src/logger";

/** Capture pino JSONL lines written during `fn`, bypassing the "warn" spy
 *  approach that can't observe calls made through a component child logger. */
function captureLogLines(fn: () => void): string[] {
  const lines: string[] = [];
  __setRootForTest({
    write(s: string): boolean {
      lines.push(s);
      return true;
    },
  }, "debug");
  try {
    fn();
  } finally {
    __setRootForTest(process.stdout);
  }
  return lines;
}

/** Write a paired-phones.json with the given raw phone rows and return the abDir. */
function seedFile(phones: unknown[]): string {
  const dir = mkdtempSync(join(tmpdir(), "antgrid-pp-"));
  const agents = join(dir, "agents");
  mkdirSync(agents, { recursive: true });
  writeFileSync(join(agents, "paired-phones.json"), JSON.stringify({ version: 1, phones }, null, 2));
  return dir;
}

function tempAbDir() {
  return mkdtempSync(join(tmpdir(), "antgrid-pp-"));
}

describe("paired-phones store (machine-level)", () => {
  it("returns empty list when file missing", () => {
    const dir = tempAbDir();
    const store = loadPairedPhones(dir);
    expect(store.list()).toEqual([]);
    rmSync(dir, { recursive: true });
  });

  it("upsert defaults allowedProjects to [] and round-trips through disk", () => {
    const dir = tempAbDir();
    const store = loadPairedPhones(dir);
    store.upsert({
      phonePubkey: "pk1", phoneDeviceId: "d1", label: "A",
      pairedAt: "2026-01-01T00:00:00Z", lastSeenAt: "2026-01-01T00:00:00Z",
    });
    expect(store.get("pk1")?.allowedProjects).toEqual([]);
    const fresh = loadPairedPhones(dir);
    expect(fresh.list().length).toBe(1);
    expect(fresh.get("pk1")?.allowedProjects).toEqual([]);
    rmSync(dir, { recursive: true });
  });

  it("upsert round-trips an explicit allowedProjects list", () => {
    const dir = tempAbDir();
    const store = loadPairedPhones(dir);
    store.upsert({
      phonePubkey: "pk-admit",
      phoneDeviceId: "d-admit",
      pairedAt: "x",
      lastSeenAt: "x",
      allowedProjects: ["projA"],
    });

    const fresh = loadPairedPhones(dir);
    expect(fresh.get("pk-admit")?.allowedProjects).toEqual(["projA"]);
    rmSync(dir, { recursive: true });
  });

  it("file lives at agents/paired-phones.json (no projectId segment)", () => {
    const dir = tempAbDir();
    loadPairedPhones(dir).upsert({
      phonePubkey: "pk1", phoneDeviceId: "d1",
      pairedAt: "2026-01-01T00:00:00Z", lastSeenAt: "2026-01-01T00:00:00Z",
    });
    const path = join(dir, "agents", "paired-phones.json");
    expect(statSync(path).isFile()).toBe(true);
    rmSync(dir, { recursive: true });
  });

  it("recovers from corrupt file as empty list", () => {
    const dir = tempAbDir();
    const agents = join(dir, "agents");
    mkdirSync(agents, { recursive: true });
    writeFileSync(join(agents, "paired-phones.json"), "{not json");
    expect(loadPairedPhones(dir).list()).toEqual([]);
    rmSync(dir, { recursive: true });
  });

  it("upsert with a new pubkey for the same device REPLACES the row (no orphan)", () => {
    const dir = tempAbDir();
    const store = loadPairedPhones(dir);
    store.upsert({
      phonePubkey: "old-pk", phoneDeviceId: "device-1",
      pairedAt: "2026-01-01T00:00:00Z", lastSeenAt: "2026-01-01T00:00:00Z",
      allowedProjects: ["projA"],
      pushToken: "tok-old", pushPubkey: "ppk-old", pushProvider: "fcm",
    });
    store.upsert({
      phonePubkey: "new-pk", phoneDeviceId: "device-1",
      pairedAt: "2026-02-01T00:00:00Z", lastSeenAt: "2026-02-01T00:00:00Z",
      allowedProjects: ["projA"],
      pushToken: "tok-new", pushPubkey: "ppk-new", pushProvider: "fcm",
    });
    const rows = store.list();
    expect(rows).toHaveLength(1);
    expect(rows[0]!.phonePubkey).toBe("new-pk");
    expect(store.get("old-pk")).toBeUndefined();
    // Survives a fresh load from disk.
    expect(loadPairedPhones(dir).list()).toHaveLength(1);
    rmSync(dir, { recursive: true });
  });

  it("upsert does not collapse distinct devices that share no phoneDeviceId", () => {
    const dir = tempAbDir();
    const store = loadPairedPhones(dir);
    store.upsert({
      phonePubkey: "pk-a", phoneDeviceId: "device-a",
      pairedAt: "x", lastSeenAt: "x", allowedProjects: [],
    });
    store.upsert({
      phonePubkey: "pk-b", phoneDeviceId: "device-b",
      pairedAt: "x", lastSeenAt: "x", allowedProjects: [],
    });
    expect(store.list()).toHaveLength(2);
    rmSync(dir, { recursive: true });
  });

  it("upsert with a truthy id does not evict legacy rows that have no phoneDeviceId", () => {
    const dir = seedFile([
      { phonePubkey: "legacy1", phoneDeviceId: "", pairedAt: "x", lastSeenAt: "x", admission: "pair-code", allowedProjects: [] },
      { phonePubkey: "legacy2", phoneDeviceId: "", pairedAt: "x", lastSeenAt: "x", admission: "pair-code", allowedProjects: [] },
    ]);
    const store = loadPairedPhones(dir);
    store.upsert({
      phonePubkey: "modern", phoneDeviceId: "device-real",
      pairedAt: "x", lastSeenAt: "x", allowedProjects: [],
    });
    expect(store.list().map((p) => p.phonePubkey).sort()).toEqual(["legacy1", "legacy2", "modern"]);
    rmSync(dir, { recursive: true });
  });

  it("remove persists to disk (fresh load reflects deletion)", () => {
    const dir = tempAbDir();
    const store = loadPairedPhones(dir);
    store.upsert({
      phonePubkey: "pk1", phoneDeviceId: "d1",
      pairedAt: "2026-01-01T00:00:00Z", lastSeenAt: "2026-01-01T00:00:00Z",
    });
    store.remove("pk1");
    expect(loadPairedPhones(dir).list()).toEqual([]);
    rmSync(dir, { recursive: true });
  });
});

describe("paired-phones allowlist helpers", () => {
  function seeded() {
    const dir = tempAbDir();
    const store = loadPairedPhones(dir);
    store.upsert({
      phonePubkey: "pk1", phoneDeviceId: "d1",
      pairedAt: "2026-01-01T00:00:00Z", lastSeenAt: "2026-01-01T00:00:00Z",
      allowedProjects: [],
    });
    return { dir, store };
  }

  it("isAllowed is false until a project is allowed, true after", () => {
    const { dir, store } = seeded();
    expect(store.isAllowed("pk1", "projA")).toBe(false);
    store.allowProject("pk1", "projA");
    expect(store.isAllowed("pk1", "projA")).toBe(true);
    rmSync(dir, { recursive: true });
  });

  it("allowProject is idempotent (no duplicate entries)", () => {
    const { dir, store } = seeded();
    store.allowProject("pk1", "projA");
    store.allowProject("pk1", "projA");
    expect(store.get("pk1")?.allowedProjects).toEqual(["projA"]);
    rmSync(dir, { recursive: true });
  });

  it("denyProject removes the project, returns true, and persists", () => {
    const { dir, store } = seeded();
    store.allowProject("pk1", "projA");
    expect(store.denyProject("pk1", "projA")).toBe(true);
    expect(store.isAllowed("pk1", "projA")).toBe(false);
    expect(loadPairedPhones(dir).isAllowed("pk1", "projA")).toBe(false);
    rmSync(dir, { recursive: true });
  });

  it("denyProject returns false when the grant or phone is absent (no-op)", () => {
    const { dir, store } = seeded();
    expect(store.denyProject("pk1", "projA")).toBe(false); // never granted
    expect(store.denyProject("nope", "projA")).toBe(false); // unknown phone
    rmSync(dir, { recursive: true });
  });

  it("isAllowed is false for an unknown phone", () => {
    const { dir, store } = seeded();
    expect(store.isAllowed("nope", "projA")).toBe(false);
    rmSync(dir, { recursive: true });
  });
});

describe("paired-phones same-account batch grants", () => {
  // Every stored phone is same-account admitted now (the pair-code admission
  // variant is gone), so these bulk helpers reach every phone unconditionally.
  function twoPhones() {
    const dir = seedFile([
      { phonePubkey: "p1", phoneDeviceId: "d-1", pairedAt: "x", lastSeenAt: "x", allowedProjects: [] },
      { phonePubkey: "p2", phoneDeviceId: "d-2", pairedAt: "x", lastSeenAt: "x", allowedProjects: ["projA"] },
    ]);
    return { dir, store: loadPairedPhones(dir) };
  }

  it("every stored phone is same-account admitted; the bulk grant reaches all of them", () => {
    const dir = tempAbDir();
    const store = loadPairedPhones(dir);
    // no `admission` field — UpsertPhone no longer has one
    store.upsert({ phonePubkey: "A", phoneDeviceId: "d1", label: "p1", pairedAt: "x", lastSeenAt: "x" });
    store.upsert({ phonePubkey: "B", phoneDeviceId: "d2", label: "p2", pairedAt: "x", lastSeenAt: "x" });
    expect(store.allowProjectForSameAccount("proj-1")).toBe(true);
    expect(store.list().every((p) => p.allowedProjects.includes("proj-1"))).toBe(true);
    rmSync(dir, { recursive: true });
  });

  it("allowProjectForSameAccount grants every phone missing it and persists", () => {
    const { dir, store } = twoPhones();
    expect(store.allowProjectForSameAccount("projB")).toBe(true);
    const fresh = loadPairedPhones(dir);
    expect(fresh.get("p1")?.allowedProjects).toEqual(["projB"]);
    expect(fresh.get("p2")?.allowedProjects.sort()).toEqual(["projA", "projB"]);
    // idempotent: re-granting reports no change
    expect(store.allowProjectForSameAccount("projB")).toBe(false);
    rmSync(dir, { recursive: true });
  });

  it("denyProjectForSameAccount revokes the project from every phone that has it", () => {
    const { dir, store } = twoPhones();
    store.allowProjectForSameAccount("projA"); // p1 now has projA too; p2 already had it
    expect(store.denyProjectForSameAccount("projA")).toBe(true);
    const fresh = loadPairedPhones(dir);
    expect(fresh.get("p1")?.allowedProjects).toEqual([]);
    expect(fresh.get("p2")?.allowedProjects).toEqual([]);
    // no grant left anywhere → no-op
    expect(store.denyProjectForSameAccount("projA")).toBe(false);
    rmSync(dir, { recursive: true });
  });
});

describe("paired-phones lastSeen touch", () => {
  const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

  function seededPhone(dir: string) {
    writeFileSync(
      join(dir, "agents", "paired-phones.json"),
      JSON.stringify({ version: 1, phones: [{ phonePubkey: "pk1", phoneDeviceId: "d1", pairedAt: "2026-01-01T00:00:00.000Z", lastSeenAt: "2026-01-01T00:00:00.000Z", allowedProjects: ["projA"] }] }, null, 2),
    );
  }

  it("updates the row in memory without writing to disk until flushed", () => {
    const dir = seedFile([{ phonePubkey: "pk1", phoneDeviceId: "d1", pairedAt: "old", lastSeenAt: "old", allowedProjects: [] }]);
    const store = loadPairedPhones(dir, { lastSeenFlushMs: 60_000 });
    store.touchLastSeen("pk1", "2026-07-27T10:00:00.000Z");

    expect(store.get("pk1")?.lastSeenAt).toBe("2026-07-27T10:00:00.000Z");
    expect(loadPairedPhones(dir).get("pk1")?.lastSeenAt).toBe("old");

    store.flushLastSeen();
    expect(loadPairedPhones(dir).get("pk1")?.lastSeenAt).toBe("2026-07-27T10:00:00.000Z");
    store.close();
    rmSync(dir, { recursive: true });
  });

  it("close() persists a touch that the coalescing timer has not fired for yet", () => {
    const dir = seedFile([{ phonePubkey: "pk1", phoneDeviceId: "d1", pairedAt: "old", lastSeenAt: "old", allowedProjects: [] }]);
    const store = loadPairedPhones(dir, { lastSeenFlushMs: 60_000 });
    store.touchLastSeen("pk1", "2026-07-27T11:00:00.000Z");
    store.close();
    expect(loadPairedPhones(dir).get("pk1")?.lastSeenAt).toBe("2026-07-27T11:00:00.000Z");
    rmSync(dir, { recursive: true });
  });

  it("is a no-op for an unknown phone (no row invented, nothing to flush)", () => {
    const dir = seedFile([{ phonePubkey: "pk1", phoneDeviceId: "d1", pairedAt: "old", lastSeenAt: "old", allowedProjects: [] }]);
    const store = loadPairedPhones(dir, { lastSeenFlushMs: 60_000 });
    store.touchLastSeen("nope");
    store.flushLastSeen();
    expect(loadPairedPhones(dir).list().map((p) => p.phonePubkey)).toEqual(["pk1"]);
    expect(loadPairedPhones(dir).get("pk1")?.lastSeenAt).toBe("old");
    rmSync(dir, { recursive: true });
  });

  it("the touch flush does not fire the watcher (a rekey must not re-advertise)", async () => {
    const dir = seedFile([{ phonePubkey: "pk1", phoneDeviceId: "d1", pairedAt: "old", lastSeenAt: "old", allowedProjects: [] }]);
    const store = loadPairedPhones(dir, { lastSeenFlushMs: 1 });
    let changes = 0;
    const stop = store.watch(() => { changes++; });

    store.touchLastSeen("pk1", "2026-07-27T12:00:00.000Z");
    store.flushLastSeen();
    await sleep(200);
    expect(changes).toBe(0);

    // ...but a real external edit still notifies.
    seededPhone(dir);
    await sleep(200);
    expect(changes).toBe(1);

    stop();
    store.close();
    rmSync(dir, { recursive: true });
  });

  it("an allowlist write still fires the watcher after a silent touch flush", async () => {
    const dir = seedFile([{ phonePubkey: "pk1", phoneDeviceId: "d1", pairedAt: "old", lastSeenAt: "old", allowedProjects: [] }]);
    const store = loadPairedPhones(dir);
    let changes = 0;
    const stop = store.watch(() => { changes++; });

    store.touchLastSeen("pk1", "2026-07-27T13:00:00.000Z");
    store.flushLastSeen();
    store.allowProject("pk1", "projA");
    await sleep(200);
    expect(changes).toBe(1);

    stop();
    store.close();
    rmSync(dir, { recursive: true });
  });

  it("the touch flush merges onto disk instead of clobbering a concurrent CLI grant", () => {
    const dir = seedFile([{ phonePubkey: "pk1", phoneDeviceId: "d1", pairedAt: "old", lastSeenAt: "old", allowedProjects: [] }]);
    const store = loadPairedPhones(dir, { lastSeenFlushMs: 60_000 });
    store.touchLastSeen("pk1", "2026-07-27T15:00:00.000Z");
    // The CLI process grants a project and writes the file. Our timer then
    // fires — with no watcher reload in between (it debounces 50ms), so the
    // flush must read disk rather than trust its own copy.
    seededPhone(dir);
    store.flushLastSeen();

    const fresh = loadPairedPhones(dir);
    expect(fresh.get("pk1")?.allowedProjects).toEqual(["projA"]); // grant survives
    expect(fresh.get("pk1")?.lastSeenAt).toBe("2026-07-27T15:00:00.000Z"); // touch applied
    rmSync(dir, { recursive: true });
  });

  it("the touch flush recreates a deleted file rather than wiping known rows", () => {
    const dir = seedFile([{ phonePubkey: "pk1", phoneDeviceId: "d1", pairedAt: "old", lastSeenAt: "old", allowedProjects: ["projA"] }]);
    const store = loadPairedPhones(dir, { lastSeenFlushMs: 60_000 });
    store.touchLastSeen("pk1", "2026-07-27T16:00:00.000Z");
    rmSync(join(dir, "agents", "paired-phones.json"));
    store.flushLastSeen();

    const fresh = loadPairedPhones(dir);
    expect(fresh.get("pk1")?.allowedProjects).toEqual(["projA"]);
    expect(fresh.get("pk1")?.lastSeenAt).toBe("2026-07-27T16:00:00.000Z");
    rmSync(dir, { recursive: true });
  });

  it("an external reload does not roll back an unflushed touch", async () => {
    const dir = seedFile([{ phonePubkey: "pk1", phoneDeviceId: "d1", pairedAt: "old", lastSeenAt: "old", allowedProjects: [] }]);
    const store = loadPairedPhones(dir, { lastSeenFlushMs: 60_000 });
    const stop = store.watch(() => {});

    store.touchLastSeen("pk1", "2026-07-27T14:00:00.000Z");
    // A CLI `phones allow` writes the file it loaded BEFORE our touch landed.
    seededPhone(dir);
    await sleep(200);

    expect(store.get("pk1")?.allowedProjects).toEqual(["projA"]); // external edit applied
    expect(store.get("pk1")?.lastSeenAt).toBe("2026-07-27T14:00:00.000Z"); // touch preserved

    stop();
    store.close();
    rmSync(dir, { recursive: true });
  });
});

describe("paired-phones touch-flush watcher suppression", () => {
  const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

  /** Simulate a separate `antgrid phones` process writing the file. Goes through
   *  the same serializer the store's flush() uses, so an allow-then-deny of one
   *  project round-trips the bytes EXACTLY — which is what makes the stale-
   *  snapshot bug below reachable. */
  function cliWrite(dir: string, allowedProjects: string[], lastSeenAt: string) {
    writeFileSync(
      join(dir, "agents", "paired-phones.json"),
      JSON.stringify({ version: 1, phones: [{ phonePubkey: "pk1", phoneDeviceId: "d1", pairedAt: "p", lastSeenAt, allowedProjects }] }, null, 2),
    );
  }

  it("a deny that restores the touched bytes still revokes (snapshot is one-shot)", async () => {
    const dir = seedFile([{ phonePubkey: "pk1", phoneDeviceId: "d1", pairedAt: "p", lastSeenAt: "old", allowedProjects: [] }]);
    const store = loadPairedPhones(dir, { lastSeenFlushMs: 60_000 });
    const stop = store.watch(() => {});

    store.touchLastSeen("pk1", "T1");
    store.flushLastSeen(); // arms the silence snapshot with bytes R
    await sleep(200);

    cliWrite(dir, ["projX"], "T1"); // allow → R'
    await sleep(200);
    expect(store.isAllowed("pk1", "projX")).toBe(true);

    cliWrite(dir, [], "T1"); // deny → byte-identical to R again
    await sleep(200);
    // A snapshot left armed would match here, skip the reload, and leave the
    // gate admitting projX until the host restarts.
    expect(store.isAllowed("pk1", "projX")).toBe(false);

    stop();
    store.close();
    rmSync(dir, { recursive: true });
  });

  it("a deny still revokes after an external write pre-empted our own event", async () => {
    const dir = seedFile([{ phonePubkey: "pk1", phoneDeviceId: "d1", pairedAt: "p", lastSeenAt: "old", allowedProjects: [] }]);
    const store = loadPairedPhones(dir, { lastSeenFlushMs: 60_000 });
    const stop = store.watch(() => {});

    store.touchLastSeen("pk1", "T1");
    store.flushLastSeen(); // arms the silence snapshot with bytes R
    // No sleep: the allow lands INSIDE the 50ms debounce, so the one watcher
    // callback reads R' and our snapshot is never the bytes it compares
    // against — the case that leaves it armed if it clears only on a match.
    cliWrite(dir, ["projX"], "T1");
    await sleep(200);
    expect(store.isAllowed("pk1", "projX")).toBe(true);

    cliWrite(dir, [], "T1"); // deny → byte-identical to R
    await sleep(200);
    expect(store.isAllowed("pk1", "projX")).toBe(false);

    stop();
    store.close();
    rmSync(dir, { recursive: true });
  });

  it("removing the last phone is not undone by an in-flight touch flush", () => {
    const dir = seedFile([{ phonePubkey: "pk1", phoneDeviceId: "d1", pairedAt: "p", lastSeenAt: "old", allowedProjects: ["projX"] }]);
    const store = loadPairedPhones(dir, { lastSeenFlushMs: 60_000 });

    store.touchLastSeen("pk1", "T2");
    // `phones remove` empties the file; our timer fires inside the watcher's
    // debounce, before any reload. An empty file is a real state, not a failed
    // read — treating it as one writes the removed row (grants included) back.
    writeFileSync(join(dir, "agents", "paired-phones.json"), JSON.stringify({ version: 1, phones: [] }, null, 2));
    store.flushLastSeen();

    expect(loadPairedPhones(dir).list()).toEqual([]);
    store.close();
    rmSync(dir, { recursive: true });
  });

  it("a torn read does not let the touch flush wipe the store", () => {
    const dir = seedFile([
      { phonePubkey: "pk1", phoneDeviceId: "d1", pairedAt: "p", lastSeenAt: "old", allowedProjects: ["projX", "projY"] },
      { phonePubkey: "pk2", phoneDeviceId: "d2", pairedAt: "p", lastSeenAt: "old", allowedProjects: ["projX"] },
    ]);
    const store = loadPairedPhones(dir, { lastSeenFlushMs: 60_000 });

    store.touchLastSeen("pk1", "T4");
    // A concurrent `antgrid phones` writeFileSync has truncated the file and our
    // timer fires mid-write. Zero rows here means "could not read", not "no
    // phones" — adopting it would flush every row and grant away for good.
    // Same landing spot as an EBUSY/EPERM open on Windows.
    writeFileSync(join(dir, "agents", "paired-phones.json"), "");
    store.flushLastSeen();

    expect(store.list().map((p) => p.phonePubkey).sort()).toEqual(["pk1", "pk2"]);
    const fresh = loadPairedPhones(dir);
    expect(fresh.get("pk1")?.allowedProjects).toEqual(["projX", "projY"]);
    expect(fresh.get("pk1")?.lastSeenAt).toBe("T4");
    expect(fresh.get("pk2")?.allowedProjects).toEqual(["projX"]);

    store.close();
    rmSync(dir, { recursive: true });
  });

  it("a flush that absorbs a concurrent grant still notifies", async () => {
    const dir = seedFile([{ phonePubkey: "pk1", phoneDeviceId: "d1", pairedAt: "p", lastSeenAt: "old", allowedProjects: [] }]);
    const store = loadPairedPhones(dir, { lastSeenFlushMs: 60_000 });
    let changes = 0;
    const stop = store.watch(() => { changes++; });

    store.touchLastSeen("pk1", "T3");
    cliWrite(dir, ["projX"], "old"); // allow lands first...
    store.flushLastSeen();           // ...and the timer merges it before the debounce
    await sleep(200);

    // The write we just made carries someone else's authorization change, so
    // the watcher event it triggers is that change's ONLY notification.
    expect(changes).toBe(1);
    expect(store.isAllowed("pk1", "projX")).toBe(true);

    stop();
    store.close();
    rmSync(dir, { recursive: true });
  });
});

describe("paired-phones stale on-disk rows", () => {
  it("tolerates a stale admission key on disk instead of rejecting the row", () => {
    const dir = seedFile([
      { phonePubkey: "legacy", phoneDeviceId: "d-old", pairedAt: "x", lastSeenAt: "x", admission: "pair-code", allowedProjects: ["projA"] },
      { phonePubkey: "modern", phoneDeviceId: "d-new", pairedAt: "x", lastSeenAt: "x", allowedProjects: [] },
    ]);
    let store!: ReturnType<typeof loadPairedPhones>;
    const lines = captureLogLines(() => {
      store = loadPairedPhones(dir);
    });
    // Both rows survive — a stale `admission` key is ignored, not a rejection reason.
    expect(store.list().map((p) => p.phonePubkey).sort()).toEqual(["legacy", "modern"]);
    expect(store.get("legacy")?.allowedProjects).toEqual(["projA"]);
    const warnLines = lines.filter((l) => (JSON.parse(l) as { level: number }).level === 40);
    expect(warnLines).toHaveLength(0);
    rmSync(dir, { recursive: true });
  });

  it("round-trips every PairedPhone field through a flush and sheds a stale admission key", () => {
    const dir = seedFile([
      {
        phonePubkey: "pk1",
        phoneDeviceId: "d1",
        label: "A",
        pairedAt: "2026-01-01T00:00:00Z",
        lastSeenAt: "2026-01-01T00:00:00Z",
        allowedProjects: [],
        pushPubkey: "push-pk",
        pushToken: "push-tok",
        pushProvider: "fcm",
        pushUpdatedAt: "2026-01-02T00:00:00Z",
        admission: "pair-code",
      },
    ]);
    const store = loadPairedPhones(dir);
    // Force a flush so the reload below exercises the on-disk read path, not
    // in-memory state.
    store.allowProject("pk1", "projA");

    const fresh = loadPairedPhones(dir);
    expect(fresh.get("pk1")).toEqual({
      phonePubkey: "pk1",
      phoneDeviceId: "d1",
      label: "A",
      pairedAt: "2026-01-01T00:00:00Z",
      lastSeenAt: "2026-01-01T00:00:00Z",
      allowedProjects: ["projA"],
      pushPubkey: "push-pk",
      pushToken: "push-tok",
      pushProvider: "fcm",
      pushUpdatedAt: "2026-01-02T00:00:00Z",
    });
    rmSync(dir, { recursive: true });
  });
});
