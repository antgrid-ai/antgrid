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
});
