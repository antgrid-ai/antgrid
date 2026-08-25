import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { CheckoutStore } from "../src/worktrees/checkout-store";

describe("CheckoutStore", () => {
  let dir: string;
  beforeEach(() => { dir = mkdtempSync(join(tmpdir(), "antgrid-checkouts-")); });
  afterEach(() => { rmSync(dir, { recursive: true, force: true }); });

  test("writes and looks up project-local checkout records", async () => {
    const store = new CheckoutStore(dir, "project-a");
    await store.put({
      id: "checkout-a", projectId: "project-a", kind: "managed-worktree",
      path: "C:/safe/worktree", branch: "antgrid/session-a", baseRef: "main",
      managed: true, sessionId: "session-a", createdAt: 1,
    });
    expect((await store.get("checkout-a"))?.branch).toBe("antgrid/session-a");
    expect(await store.remove("checkout-a")).toBe(true);
    expect(await store.list()).toEqual([]);
  });

  test("round-trips baseRef for both an explicit branch and a HEAD base", async () => {
    // baseRef has no reader anywhere — it is provenance for support triage — so
    // a schema edit that quietly dropped it would break nothing else on the way
    // out. Null is the HEAD case and is just as load-bearing as the name: it is
    // what says the user picked no branch at all.
    const store = new CheckoutStore(dir, "project-a");
    await store.put({ id: "from-branch", projectId: "project-a", kind: "managed-worktree", path: "C:/safe/a", branch: "antgrid/a", baseRef: "release/2.1", managed: true, sessionId: null, createdAt: 1 });
    await store.put({ id: "from-head", projectId: "project-a", kind: "managed-worktree", path: "C:/safe/b", branch: "antgrid/b", baseRef: null, managed: true, sessionId: null, createdAt: 2 });
    const byId = new Map((await store.list()).map((record) => [record.id, record.baseRef]));
    expect(byId.get("from-branch")).toBe("release/2.1");
    expect(byId.get("from-head")).toBeNull();
  });

  test("skips malformed rows while retaining valid siblings", async () => {
    const store = new CheckoutStore(dir, "project-a");
    await store.put({ id: "valid", projectId: "project-a", kind: "managed-worktree", path: "C:/safe", branch: null, baseRef: null, managed: true, sessionId: null, createdAt: 1 });
    writeFileSync(join(dir, "agents", "project-a", "checkouts.json"), JSON.stringify({
      version: 1,
      checkouts: [
        { id: "valid", projectId: "project-a", kind: "managed-worktree", path: "C:/safe", branch: null, baseRef: null, managed: true, sessionId: null, createdAt: 1 },
        { id: 4 },
      ],
    }));
    expect((await store.list()).map((record) => record.id)).toEqual(["valid"]);
  });

  test("round-trips the worktree.setup outcome and clears it again", async () => {
    // The whole durable surface of `worktree.setup`: how a run ENDED. A rerun
    // clears the marker before it spawns, so the write-back of `undefined` is
    // as load-bearing as the write of an outcome — a bridge that died mid-rerun
    // must come back `interrupted`, not wearing the previous run's `done`.
    const store = new CheckoutStore(dir, "project-a");
    const base = {
      id: "checkout-a", projectId: "project-a", kind: "managed-worktree" as const,
      path: "C:/safe/worktree", branch: "antgrid/session-a", baseRef: "main",
      managed: true, sessionId: "session-a", createdAt: 1,
    };
    await store.put({ ...base, setupState: "failed", setupFinishedAt: 1_700_000_000_000, setupExitCode: 3 });
    expect(await store.get("checkout-a")).toMatchObject({
      setupState: "failed", setupFinishedAt: 1_700_000_000_000, setupExitCode: 3,
    });

    await store.put(base);
    const cleared = await store.get("checkout-a");
    expect(cleared?.setupState).toBeUndefined();
    expect(cleared?.setupFinishedAt).toBeUndefined();
    expect(cleared?.setupExitCode).toBeUndefined();
  });

  test("rejects a running setup state, which must never reach disk", async () => {
    // `running` is absent from the durable enum on purpose: a bridge that dies
    // mid-setup would otherwise leave a row that is permanently preparing with
    // nothing alive to ever clear it. Absence is what `interrupted` is derived
    // from.
    const store = new CheckoutStore(dir, "project-a");
    await expect(store.put({
      id: "checkout-a", projectId: "project-a", kind: "managed-worktree",
      path: "C:/safe/worktree", branch: null, baseRef: null,
      managed: true, sessionId: null, createdAt: 1,
      setupState: "running" as never,
    })).rejects.toThrow();
  });

  test("a checkouts.json written before setup markers existed still parses", async () => {
    // The three fields are optional so an existing file stays valid across the
    // upgrade — a stricter schema would make every pre-existing worktree read
    // as a corrupt row and get swept as an orphan.
    mkdirSync(join(dir, "agents", "project-a"), { recursive: true });
    writeFileSync(join(dir, "agents", "project-a", "checkouts.json"), JSON.stringify({
      version: 1,
      checkouts: [{
        id: "legacy", projectId: "project-a", kind: "managed-worktree", path: "C:/safe",
        branch: "antgrid/legacy", baseRef: null, managed: true, sessionId: "s", createdAt: 1,
      }],
    }));
    const store = new CheckoutStore(dir, "project-a");
    expect(await store.read()).toMatchObject({ healthy: true });
    const legacy = await store.get("legacy");
    expect(legacy?.branch).toBe("antgrid/legacy");
    expect(legacy?.setupState).toBeUndefined();
  });

  test("read() separates an absent file from one it could not fully understand", async () => {
    // The distinction is what stands between reconciliation's orphan sweep and
    // force-deleting a live worktree whose row it simply could not see.
    const store = new CheckoutStore(dir, "project-a");
    expect(await store.read()).toEqual({ healthy: true, records: [] });

    await store.put({ id: "valid", projectId: "project-a", kind: "managed-worktree", path: "C:/safe", branch: null, baseRef: null, managed: true, sessionId: null, createdAt: 1 });
    expect((await store.read()).healthy).toBe(true);

    const file = join(dir, "agents", "project-a", "checkouts.json");
    writeFileSync(file, JSON.stringify({ version: 1, checkouts: [{ id: 4 }] }));
    expect(await store.read()).toEqual({ healthy: false, records: [] });

    writeFileSync(file, "{ truncated");
    expect(await store.read()).toEqual({ healthy: false, records: [] });
  });
});
