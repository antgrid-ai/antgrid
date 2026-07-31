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

  it("upsert round-trips a row through disk", () => {
    const dir = tempAbDir();
    const store = loadPairedPhones(dir);
    store.upsert({
      phonePubkey: "pk1", phoneDeviceId: "d1", label: "A",
      pairedAt: "2026-01-01T00:00:00Z", lastSeenAt: "2026-01-01T00:00:00Z",
    });
    const fresh = loadPairedPhones(dir);
    expect(fresh.list().length).toBe(1);
    expect(fresh.get("pk1")?.label).toBe("A");
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
      pushToken: "tok-old", pushPubkey: "ppk-old", pushProvider: "fcm",
    });
    store.upsert({
      phonePubkey: "new-pk", phoneDeviceId: "device-1",
      pairedAt: "2026-02-01T00:00:00Z", lastSeenAt: "2026-02-01T00:00:00Z",
      pushToken: "tok-new", pushPubkey: "ppk-new", pushProvider: "fcm",
    });
    const rows = store.list();
    expect(rows).toHaveLength(1);
    expect(rows[0]!.phonePubkey).toBe("new-pk");
    expect(rows[0]!.pushToken).toBe("tok-new");
    expect(store.get("old-pk")).toBeUndefined();
    // Survives a fresh load from disk.
    expect(loadPairedPhones(dir).list()).toHaveLength(1);
    rmSync(dir, { recursive: true });
  });

  it("upsert does not collapse distinct devices that share no phoneDeviceId", () => {
    const dir = tempAbDir();
    const store = loadPairedPhones(dir);
    store.upsert({ phonePubkey: "pk-a", phoneDeviceId: "device-a", pairedAt: "x", lastSeenAt: "x" });
    store.upsert({ phonePubkey: "pk-b", phoneDeviceId: "device-b", pairedAt: "x", lastSeenAt: "x" });
    expect(store.list()).toHaveLength(2);
    rmSync(dir, { recursive: true });
  });

  it("upsert with a truthy id does not evict legacy rows that have no phoneDeviceId", () => {
    const dir = seedFile([
      { phonePubkey: "legacy1", phoneDeviceId: "", pairedAt: "x", lastSeenAt: "x", admission: "pair-code" },
      { phonePubkey: "legacy2", phoneDeviceId: "", pairedAt: "x", lastSeenAt: "x", admission: "pair-code" },
    ]);
    const store = loadPairedPhones(dir);
    store.upsert({ phonePubkey: "modern", phoneDeviceId: "device-real", pairedAt: "x", lastSeenAt: "x" });
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

describe("paired-phones lastSeen touch", () => {
  const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

  /** Poll for a notification instead of sleeping a fixed window. The chain is an
   *  OS watch event plus a 50ms debounce, and event delivery is delayed 1:1 by
   *  anything stalling the loop — a neighbouring suite blocking ~170ms is enough
   *  to push the debounce past a 200ms deadline and fail with `changes` at 0.
   *  Only positive assertions can poll; a "stayed 0" check still has to sit out
   *  a real window, but a late event there can only weaken it, never fail it. */
  async function waitForChanges(read: () => number, want: number): Promise<number> {
    for (let i = 0; i < 300 && read() < want; i++) await sleep(10);
    return read();
  }

  /** Simulate a separate `antgrid phones` process rewriting the row. */
  function externalEdit(dir: string, label: string) {
    writeFileSync(
      join(dir, "agents", "paired-phones.json"),
      JSON.stringify({ version: 1, phones: [{ phonePubkey: "pk1", phoneDeviceId: "d1", label, pairedAt: "2026-01-01T00:00:00.000Z", lastSeenAt: "2026-01-01T00:00:00.000Z" }] }, null, 2),
    );
  }

  it("updates the row in memory without writing to disk until flushed", () => {
    const dir = seedFile([{ phonePubkey: "pk1", phoneDeviceId: "d1", pairedAt: "old", lastSeenAt: "old" }]);
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
    const dir = seedFile([{ phonePubkey: "pk1", phoneDeviceId: "d1", pairedAt: "old", lastSeenAt: "old" }]);
    const store = loadPairedPhones(dir, { lastSeenFlushMs: 60_000 });
    store.touchLastSeen("pk1", "2026-07-27T11:00:00.000Z");
    store.close();
    expect(loadPairedPhones(dir).get("pk1")?.lastSeenAt).toBe("2026-07-27T11:00:00.000Z");
    rmSync(dir, { recursive: true });
  });

  it("is a no-op for an unknown phone (no row invented, nothing to flush)", () => {
    const dir = seedFile([{ phonePubkey: "pk1", phoneDeviceId: "d1", pairedAt: "old", lastSeenAt: "old" }]);
    const store = loadPairedPhones(dir, { lastSeenFlushMs: 60_000 });
    store.touchLastSeen("nope");
    store.flushLastSeen();
    expect(loadPairedPhones(dir).list().map((p) => p.phonePubkey)).toEqual(["pk1"]);
    expect(loadPairedPhones(dir).get("pk1")?.lastSeenAt).toBe("old");
    rmSync(dir, { recursive: true });
  });

  it("the touch flush does not fire the watcher (a rekey must not re-advertise)", async () => {
    const dir = seedFile([{ phonePubkey: "pk1", phoneDeviceId: "d1", pairedAt: "old", lastSeenAt: "old" }]);
    const store = loadPairedPhones(dir, { lastSeenFlushMs: 1 });
    let changes = 0;
    const stop = store.watch(() => { changes++; });

    store.touchLastSeen("pk1", "2026-07-27T12:00:00.000Z");
    store.flushLastSeen();
    await sleep(200);
    expect(changes).toBe(0);

    // ...but a real external edit still notifies.
    externalEdit(dir, "Pixel");
    expect(await waitForChanges(() => changes, 1)).toBe(1);

    stop();
    store.close();
    rmSync(dir, { recursive: true });
  });

  it("a row write still fires the watcher after a silent touch flush", async () => {
    const dir = seedFile([{ phonePubkey: "pk1", phoneDeviceId: "d1", pairedAt: "old", lastSeenAt: "old" }]);
    const store = loadPairedPhones(dir);
    let changes = 0;
    const stop = store.watch(() => { changes++; });

    store.touchLastSeen("pk1", "2026-07-27T13:00:00.000Z");
    store.flushLastSeen();
    store.upsert({ phonePubkey: "pk2", phoneDeviceId: "d2", pairedAt: "x", lastSeenAt: "x" });
    expect(await waitForChanges(() => changes, 1)).toBe(1);

    stop();
    store.close();
    rmSync(dir, { recursive: true });
  });

  it("the touch flush merges onto disk instead of clobbering a concurrent CLI edit", () => {
    const dir = seedFile([{ phonePubkey: "pk1", phoneDeviceId: "d1", pairedAt: "old", lastSeenAt: "old" }]);
    const store = loadPairedPhones(dir, { lastSeenFlushMs: 60_000 });
    store.touchLastSeen("pk1", "2026-07-27T15:00:00.000Z");
    // Another process relabels the phone and writes the file. Our timer then
    // fires — with no watcher reload in between (it debounces 50ms), so the
    // flush must read disk rather than trust its own copy.
    externalEdit(dir, "Pixel");
    store.flushLastSeen();

    const fresh = loadPairedPhones(dir);
    expect(fresh.get("pk1")?.label).toBe("Pixel"); // external edit survives
    expect(fresh.get("pk1")?.lastSeenAt).toBe("2026-07-27T15:00:00.000Z"); // touch applied
    rmSync(dir, { recursive: true });
  });

  it("the touch flush recreates a deleted file rather than wiping known rows", () => {
    const dir = seedFile([{ phonePubkey: "pk1", phoneDeviceId: "d1", pairedAt: "old", lastSeenAt: "old", pushToken: "tok" }]);
    const store = loadPairedPhones(dir, { lastSeenFlushMs: 60_000 });
    store.touchLastSeen("pk1", "2026-07-27T16:00:00.000Z");
    rmSync(join(dir, "agents", "paired-phones.json"));
    store.flushLastSeen();

    const fresh = loadPairedPhones(dir);
    expect(fresh.get("pk1")?.pushToken).toBe("tok");
    expect(fresh.get("pk1")?.lastSeenAt).toBe("2026-07-27T16:00:00.000Z");
    rmSync(dir, { recursive: true });
  });

  it("an external reload does not roll back an unflushed touch", async () => {
    const dir = seedFile([{ phonePubkey: "pk1", phoneDeviceId: "d1", pairedAt: "old", lastSeenAt: "old" }]);
    const store = loadPairedPhones(dir, { lastSeenFlushMs: 60_000 });
    const stop = store.watch(() => {});

    store.touchLastSeen("pk1", "2026-07-27T14:00:00.000Z");
    // Another process writes the file it loaded BEFORE our touch landed.
    externalEdit(dir, "Pixel");
    await sleep(200);

    expect(store.get("pk1")?.label).toBe("Pixel"); // external edit applied
    expect(store.get("pk1")?.lastSeenAt).toBe("2026-07-27T14:00:00.000Z"); // touch preserved

    stop();
    store.close();
    rmSync(dir, { recursive: true });
  });
});

describe("paired-phones touch-flush watcher suppression", () => {
  const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

  /** Simulate a separate `antgrid phones` process writing the file. Goes through
   *  the same serializer (and key order) the store's flush() uses, so a
   *  label-then-unlabel round-trips the bytes EXACTLY — which is what makes the
   *  stale-snapshot bug below reachable. */
  function cliWrite(dir: string, label: string | undefined, lastSeenAt: string) {
    const row: Record<string, unknown> = { phonePubkey: "pk1", phoneDeviceId: "d1", pairedAt: "p", lastSeenAt };
    if (label !== undefined) row.label = label;
    writeFileSync(
      join(dir, "agents", "paired-phones.json"),
      JSON.stringify({ version: 1, phones: [row] }, null, 2),
    );
  }

  it("a second external edit that restores the touched bytes still lands (snapshot is one-shot)", async () => {
    const dir = seedFile([{ phonePubkey: "pk1", phoneDeviceId: "d1", pairedAt: "p", lastSeenAt: "old" }]);
    const store = loadPairedPhones(dir, { lastSeenFlushMs: 60_000 });
    const stop = store.watch(() => {});

    store.touchLastSeen("pk1", "T1");
    store.flushLastSeen(); // arms the silence snapshot with bytes R
    await sleep(200);

    cliWrite(dir, "Pixel", "T1"); // relabel → R'
    await sleep(200);
    expect(store.get("pk1")?.label).toBe("Pixel");

    cliWrite(dir, undefined, "T1"); // unlabel → byte-identical to R again
    await sleep(200);
    // A snapshot left armed would match here, skip the reload, and leave the
    // running host on rows it no longer has until it restarts.
    expect(store.get("pk1")?.label).toBeUndefined();

    stop();
    store.close();
    rmSync(dir, { recursive: true });
  });

  it("a restoring edit still lands after an external write pre-empted our own event", async () => {
    const dir = seedFile([{ phonePubkey: "pk1", phoneDeviceId: "d1", pairedAt: "p", lastSeenAt: "old" }]);
    const store = loadPairedPhones(dir, { lastSeenFlushMs: 60_000 });
    const stop = store.watch(() => {});

    store.touchLastSeen("pk1", "T1");
    store.flushLastSeen(); // arms the silence snapshot with bytes R
    // No sleep: the relabel lands INSIDE the 50ms debounce, so the one watcher
    // callback reads R' and our snapshot is never the bytes it compares
    // against — the case that leaves it armed if it clears only on a match.
    cliWrite(dir, "Pixel", "T1");
    await sleep(200);
    expect(store.get("pk1")?.label).toBe("Pixel");

    cliWrite(dir, undefined, "T1"); // → byte-identical to R
    await sleep(200);
    expect(store.get("pk1")?.label).toBeUndefined();

    stop();
    store.close();
    rmSync(dir, { recursive: true });
  });

  it("removing the last phone is not undone by an in-flight touch flush", () => {
    const dir = seedFile([{ phonePubkey: "pk1", phoneDeviceId: "d1", pairedAt: "p", lastSeenAt: "old" }]);
    const store = loadPairedPhones(dir, { lastSeenFlushMs: 60_000 });

    store.touchLastSeen("pk1", "T2");
    // `phones remove` empties the file; our timer fires inside the watcher's
    // debounce, before any reload. An empty file is a real state, not a failed
    // read — treating it as one writes the removed row straight back.
    writeFileSync(join(dir, "agents", "paired-phones.json"), JSON.stringify({ version: 1, phones: [] }, null, 2));
    store.flushLastSeen();

    expect(loadPairedPhones(dir).list()).toEqual([]);
    store.close();
    rmSync(dir, { recursive: true });
  });

  it("a torn read does not let the touch flush wipe the store", () => {
    const dir = seedFile([
      { phonePubkey: "pk1", phoneDeviceId: "d1", pairedAt: "p", lastSeenAt: "old", pushToken: "tok-1" },
      { phonePubkey: "pk2", phoneDeviceId: "d2", pairedAt: "p", lastSeenAt: "old", pushToken: "tok-2" },
    ]);
    const store = loadPairedPhones(dir, { lastSeenFlushMs: 60_000 });

    store.touchLastSeen("pk1", "T4");
    // A concurrent `antgrid phones` writeFileSync has truncated the file and our
    // timer fires mid-write. Zero rows here means "could not read", not "no
    // phones" — adopting it would flush every row and push token away for good.
    // Same landing spot as an EBUSY/EPERM open on Windows.
    writeFileSync(join(dir, "agents", "paired-phones.json"), "");
    store.flushLastSeen();

    expect(store.list().map((p) => p.phonePubkey).sort()).toEqual(["pk1", "pk2"]);
    const fresh = loadPairedPhones(dir);
    expect(fresh.get("pk1")?.pushToken).toBe("tok-1");
    expect(fresh.get("pk1")?.lastSeenAt).toBe("T4");
    expect(fresh.get("pk2")?.pushToken).toBe("tok-2");

    store.close();
    rmSync(dir, { recursive: true });
  });

  it("a flush that absorbs a concurrent external edit still notifies", async () => {
    const dir = seedFile([{ phonePubkey: "pk1", phoneDeviceId: "d1", pairedAt: "p", lastSeenAt: "old" }]);
    const store = loadPairedPhones(dir, { lastSeenFlushMs: 60_000 });
    let changes = 0;
    const stop = store.watch(() => { changes++; });

    store.touchLastSeen("pk1", "T3");
    cliWrite(dir, "Pixel", "old"); // the external edit lands first...
    store.flushLastSeen();         // ...and the timer merges it before the debounce
    await sleep(200);

    // The write we just made carries someone else's change, so the watcher event
    // it triggers is that change's ONLY notification.
    expect(changes).toBe(1);
    expect(store.get("pk1")?.label).toBe("Pixel");

    stop();
    store.close();
    rmSync(dir, { recursive: true });
  });
});

describe("paired-phones stale on-disk rows", () => {
  it("tolerates stale keys on disk instead of rejecting the row", () => {
    const dir = seedFile([
      { phonePubkey: "legacy", phoneDeviceId: "d-old", pairedAt: "x", lastSeenAt: "x", admission: "pair-code", allowedProjects: ["projA"] },
      { phonePubkey: "modern", phoneDeviceId: "d-new", pairedAt: "x", lastSeenAt: "x" },
    ]);
    let store!: ReturnType<typeof loadPairedPhones>;
    const lines = captureLogLines(() => {
      store = loadPairedPhones(dir);
    });
    // Both rows survive — `admission` (pre-account-trust) and `allowedProjects`
    // (pre-machine-switch) are ignored, not rejection reasons.
    expect(store.list().map((p) => p.phonePubkey).sort()).toEqual(["legacy", "modern"]);
    const warnLines = lines.filter((l) => (JSON.parse(l) as { level: number }).level === 40);
    expect(warnLines).toHaveLength(0);
    rmSync(dir, { recursive: true });
  });

  it("round-trips every PairedPhone field through a flush and sheds the stale keys", () => {
    const dir = seedFile([
      {
        phonePubkey: "pk1",
        phoneDeviceId: "d1",
        label: "A",
        pairedAt: "2026-01-01T00:00:00Z",
        lastSeenAt: "2026-01-01T00:00:00Z",
        pushPubkey: "push-pk",
        pushToken: "push-tok",
        pushProvider: "fcm",
        pushUpdatedAt: "2026-01-02T00:00:00Z",
        admission: "pair-code",
        allowedProjects: ["projA"],
      },
    ]);
    const store = loadPairedPhones(dir);
    // Force a flush so the reload below exercises the on-disk read path, not
    // in-memory state.
    store.upsert({ phonePubkey: "pk2", phoneDeviceId: "d2", pairedAt: "x", lastSeenAt: "x" });

    const fresh = loadPairedPhones(dir);
    expect(fresh.get("pk1")).toEqual({
      phonePubkey: "pk1",
      phoneDeviceId: "d1",
      label: "A",
      pairedAt: "2026-01-01T00:00:00Z",
      lastSeenAt: "2026-01-01T00:00:00Z",
      pushPubkey: "push-pk",
      pushToken: "push-tok",
      pushProvider: "fcm",
      pushUpdatedAt: "2026-01-02T00:00:00Z",
    });
    rmSync(dir, { recursive: true });
  });
});
