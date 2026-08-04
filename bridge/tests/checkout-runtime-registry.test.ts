import { describe, expect, test } from "bun:test";
import { CheckoutRuntimeRegistry } from "../src/worktrees/checkout-runtime-registry";
import type { CheckoutStore } from "../src/worktrees/checkout-store";
import type { CheckoutRecord } from "../src/worktrees/checkout-types";

const main: CheckoutRecord = {
  id: "main", projectId: "project", kind: "main", path: "C:/repo",
  branch: null, baseRef: null, managed: false, sessionId: null, createdAt: 0,
};

describe("CheckoutRuntimeRegistry", () => {
  test("keeps main in memory and restores managed metadata by checkout id", async () => {
    const managed: CheckoutRecord = {
      id: "checkout-1", projectId: "project", kind: "managed-worktree",
      path: "C:/worktrees/checkout-1", branch: "antgrid/session-1",
      baseRef: "main", managed: true, sessionId: "session-1", createdAt: 1,
    };
    const store = { get: async (id: string) => id === managed.id ? managed : undefined } as CheckoutStore;
    const registry = new CheckoutRuntimeRegistry<string, string, { path: string }>(store, main);

    expect(await registry.resolve("main")).toEqual(main);
    expect(await registry.resolve(managed.id)).toEqual(managed);
    await registry.prepare(managed, "config", "spec", { path: managed.path });
    expect(registry.config(managed.id)).toBe("config");
    expect(registry.agentSpec(managed.id)).toBe("spec");
    expect(registry.runtime(managed.id)?.path).toBe(managed.path);

    await registry.remove(managed.id);
    expect(registry.config(managed.id)).toBeUndefined();
    expect(await registry.resolve(managed.id)).toEqual(managed);
  });
});
