import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { rename } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { CheckoutStore, RENAME_ATTEMPTS, renameReplacing } from "../src/worktrees/checkout-store";

/** A rename that reports `codes` in order before deferring to the real one. */
function flakyRename(codes: string[]) {
  const attempts: string[] = [];
  const fn = (async (from: string, to: string) => {
    const code = codes[attempts.length];
    attempts.push(code ?? "ok");
    if (!code) return await rename(from, to);
    throw Object.assign(new Error(`${code}: injected`), { code });
  }) as typeof rename;
  return { fn, attempts };
}

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

  test("update annotates in place and never resurrects a removed row", async () => {
    // The setup marker lands on a row the delete flow may already have
    // reclaimed. A get()-then-put() spans two lock acquisitions, so the put
    // would write the row back with the worktree it names already gone.
    const store = new CheckoutStore(dir, "project-a");
    const base = {
      id: "checkout-a", projectId: "project-a", kind: "managed-worktree" as const,
      path: "C:/safe/worktree", branch: "antgrid/session-a", baseRef: "main",
      managed: true, sessionId: "session-a", createdAt: 1,
    };
    await store.put(base);
    expect(await store.update("checkout-a", (record) => ({ ...record, setupState: "done" }))).toBe(true);
    expect((await store.get("checkout-a"))?.setupState).toBe("done");

    expect(await store.remove("checkout-a")).toBe(true);
    expect(await store.update("checkout-a", (record) => ({ ...record, setupState: "failed" }))).toBe(false);
    expect(await store.list()).toEqual([]);
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

  // The write half of the race read() documents from the read side: on Windows
  // a rename onto a file somebody else has open fails, and this file has far
  // more readers than writers. Every case here is about the rename alone, which
  // is why the seam is injected rather than reproduced by racing real handles —
  // a test that had to win a timing race to mean anything would be the flake it
  // was written to remove.
  describe("replacing the file while a reader holds it", () => {
    test("waits out a busy destination instead of failing the write", async () => {
      const from = join(dir, "source");
      const to = join(dir, "target");
      writeFileSync(from, "replacement");
      writeFileSync(to, "original");
      const { fn, attempts } = flakyRename(["EPERM", "EBUSY"]);
      await renameReplacing(from, to, fn);
      expect(attempts).toEqual(["EPERM", "EBUSY", "ok"]);
      expect(readdirSync(dir)).not.toContain("source");
    });

    test("gives up bounded, and reports the error it actually hit", async () => {
      const { fn, attempts } = flakyRename(Array(RENAME_ATTEMPTS + 5).fill("EPERM"));
      await expect(renameReplacing("a", "b", fn)).rejects.toMatchObject({ code: "EPERM" });
      expect(attempts.length).toBe(RENAME_ATTEMPTS);
    });

    test("a failure that waiting cannot fix is reported at once", async () => {
      // Retrying an absent source only delays the same answer, and this store is
      // in the path of a session action the user is waiting on.
      const { fn, attempts } = flakyRename(["ENOENT", "ENOENT"]);
      await expect(renameReplacing("a", "b", fn)).rejects.toMatchObject({ code: "ENOENT" });
      expect(attempts.length).toBe(1);
    });

    test("a write that cannot land leaves no temp file behind", async () => {
      // A directory where the file belongs is a rename this can never win, which
      // is the point: the store is left as it was, and so is its directory.
      const home = join(dir, "agents", "project-a");
      mkdirSync(join(home, "checkouts.json"), { recursive: true });
      const store = new CheckoutStore(dir, "project-a");
      await expect(store.put({
        id: "checkout-a", projectId: "project-a", kind: "managed-worktree",
        path: "C:/safe/worktree", branch: null, baseRef: null,
        managed: true, sessionId: null, createdAt: 1,
      })).rejects.toBeDefined();
      expect(readdirSync(home).filter((n) => n.endsWith(".tmp"))).toEqual([]);
    });
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
