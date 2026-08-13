import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
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
