import { describe, test, expect } from "bun:test";
import {
  mergeTask,
  toRemote,
  fromRemote,
  sameRemoteState,
  type LocalFields,
  type SnapshotFields,
  type RemoteFields,
} from "../../src/tasks/merge.js";

const localBase: LocalFields = {
  title: "orig",
  body: "orig body",
  status: "open",
  labels: [],
  assignee: null,
};

const snapshotBase: SnapshotFields = {
  title: "orig",
  body: "orig body",
  status: { state: "open" },
  labels: [],
  assignee: null,
};

function merge(
  local: Partial<LocalFields>,
  remote: Partial<RemoteFields>,
  base: Partial<SnapshotFields> = {},
) {
  return mergeTask({
    base: { ...snapshotBase, ...base },
    local: { ...localBase, ...local },
    remote: { ...snapshotBase, ...base, ...remote },
  });
}

describe("status merges in provider space", () => {
  /**
   * The regression test this module exists for. An imported task at local
   * `open` / base `open` has `working → in_progress` written by the run
   * observer; merging in Antgrid vocabulary reads that as "local moved" and
   * pushes a PATCH that cannot have an effect, forever, once per reconcile.
   * If this test fails, the provider-space rule has been lost.
   */
  test("working -> in_progress on an imported task pushes nothing", () => {
    const result = merge({ status: "in_progress" }, {});
    expect(result.push).toEqual([]);
    expect(result.apply.status).toBeUndefined();
    expect(result.conflicts).toEqual([]);
  });

  test("blocked is equally invisible to the provider", () => {
    expect(merge({ status: "blocked" }, {}).push).toEqual([]);
  });

  test("a remote close during a local run applies cleanly instead of conflicting", () => {
    const result = merge(
      { status: "in_progress" },
      { status: { state: "closed", stateReason: "completed" } },
    );
    expect(result.apply.status).toBe("done");
    expect(result.conflicts).toEqual([]);
    expect(result.push).toEqual([]);
  });

  test("an unchanged open issue coming back does not clobber local sub-status", () => {
    const result = merge({ status: "in_progress" }, { status: { state: "open" } });
    expect(result.apply.status).toBeUndefined();
  });

  test("state_reason is ignored while the issue is open", () => {
    const result = merge(
      { status: "in_progress" },
      { status: { state: "open", stateReason: "reopened" } },
    );
    expect(result.push).toEqual([]);
    expect(result.apply.status).toBeUndefined();
  });

  test("a genuine local close pushes", () => {
    expect(merge({ status: "done" }, {}).push).toContain("status");
  });

  /** Both map to `closed`, and `state_reason` is ignored unless `state` changes,
   *  so the drain cannot deliver this with a plain PATCH. The merge still has to
   *  report it as a push rather than swallow it. */
  test("done -> cancelled is reported as a push", () => {
    const closed = { state: "closed", stateReason: "completed" } as const;
    const result = merge(
      { status: "cancelled" },
      { status: closed },
      { status: closed },
    );
    expect(result.push).toContain("status");
  });

  test("a reopen from the provider is applied", () => {
    const closed = { state: "closed", stateReason: "completed" } as const;
    const result = merge(
      { status: "done" },
      { status: { state: "open" } },
      { status: closed },
    );
    expect(result.apply.status).toBe("open");
  });
});

describe("status mapping", () => {
  test("the three open states are one provider value", () => {
    expect(toRemote("open")).toEqual(toRemote("in_progress"));
    expect(toRemote("in_progress")).toEqual(toRemote("blocked"));
  });

  test("done and cancelled differ only by reason", () => {
    expect(toRemote("done")).toEqual({ state: "closed", stateReason: "completed" });
    expect(toRemote("cancelled")).toEqual({ state: "closed", stateReason: "not_planned" });
  });

  test("fromRemote takes its sub-status hint from the local row", () => {
    expect(fromRemote({ state: "open" }, "in_progress")).toBe("in_progress");
    expect(fromRemote({ state: "open" }, "blocked")).toBe("blocked");
    expect(fromRemote({ state: "open" }, "done")).toBe("open");
    expect(fromRemote({ state: "open" }, "open")).toBe("open");
  });

  test("a closed issue with no reason reads as done", () => {
    expect(fromRemote({ state: "closed" }, "open")).toBe("done");
    expect(fromRemote({ state: "closed", stateReason: null }, "open")).toBe("done");
    expect(fromRemote({ state: "closed", stateReason: "not_planned" }, "open")).toBe("cancelled");
  });

  test("open states compare equal regardless of reason; closed ones do not", () => {
    expect(sameRemoteState({ state: "open" }, { state: "open", stateReason: "reopened" })).toBe(true);
    expect(
      sameRemoteState(
        { state: "closed", stateReason: "completed" },
        { state: "closed", stateReason: "not_planned" },
      ),
    ).toBe(false);
  });
});

describe("scalar fields", () => {
  test("local-only edit pushes", () => {
    const result = merge({ title: "mine" }, {});
    expect(result.push).toEqual(["title"]);
    expect(result.apply.title).toBeUndefined();
  });

  test("remote-only edit applies", () => {
    const result = merge({}, { title: "theirs" });
    expect(result.apply.title).toBe("theirs");
    expect(result.push).toEqual([]);
  });

  test("both edited is a conflict that keeps the losing local value", () => {
    const result = merge({ title: "mine" }, { title: "theirs" });
    expect(result.apply.title).toBe("theirs");
    expect(result.conflicts).toEqual([
      { field: "title", localValue: "mine", remoteValue: "theirs" },
    ]);
  });

  test("an untouched task produces no work at all", () => {
    const result = merge({}, {});
    expect(result).toEqual({
      apply: {},
      push: [],
      conflicts: [],
      labelsChanged: false,
      labelsPush: false,
      labelRemoveWins: [],
    });
  });

  test("assignee compares by identity, not by snapshot fields", () => {
    const member = { kind: "member", userId: "u1" } as const;
    const unchanged = merge({ assignee: member }, { assignee: member }, { assignee: member });
    expect(unchanged.push).toEqual([]);
    expect(unchanged.apply.assignee).toBeUndefined();

    const external = { kind: "external", externalId: "42", login: "octocat" } as const;
    const renamed = { kind: "external", externalId: "42", login: "octocat-renamed" } as const;
    expect(merge({ assignee: external }, { assignee: renamed }, { assignee: external }).apply
      .assignee).toBeUndefined();
  });

  test("a member and an external assignee are never the same identity", () => {
    const result = merge(
      { assignee: { kind: "member", userId: "u1" } },
      { assignee: { kind: "external", externalId: "42", login: "octocat" } },
    );
    expect(result.conflicts.map((c) => c.field)).toEqual(["assignee"]);
  });
});

describe("labels merge element-wise", () => {
  test("each side adding a different label is not a conflict", () => {
    const result = merge({ labels: ["bug"] }, { labels: ["docs"] }, { labels: [] });
    expect(result.apply.labels).toEqual(["bug", "docs"]);
    expect(result.conflicts).toEqual([]);
    expect(result.labelsChanged).toBe(true);
    expect(result.labelsPush).toBe(true);
  });

  test("a label added only locally needs a push but no local write", () => {
    const result = merge({ labels: ["bug"] }, { labels: [] }, { labels: [] });
    expect(result.labelsChanged).toBe(false);
    expect(result.labelsPush).toBe(true);
    expect(result.apply.labels).toBeUndefined();
  });

  test("a label added only remotely needs a local write but no push", () => {
    const result = merge({ labels: [] }, { labels: ["docs"] }, { labels: [] });
    expect(result.labelsChanged).toBe(true);
    expect(result.labelsPush).toBe(false);
  });

  test("remove always wins over the other side keeping it", () => {
    const result = merge({ labels: [] }, { labels: ["bug"] }, { labels: ["bug"] });
    // Nothing to write locally -- the local row already reflects the removal --
    // but the remote still carries it, so the drop has to be pushed.
    expect(result.apply.labels).toBeUndefined();
    expect(result.labelsChanged).toBe(false);
    expect(result.labelsPush).toBe(true);
    expect(result.labelRemoveWins).toEqual(["bug"]);
    expect(result.conflicts).toEqual([]);
  });

  test("a removal both sides agree on is not marked", () => {
    const result = merge({ labels: [] }, { labels: [] }, { labels: ["bug"] });
    expect(result.apply.labels).toBeUndefined();
    expect(result.labelsChanged).toBe(false);
    expect(result.labelsPush).toBe(false);
    expect(result.labelRemoveWins).toEqual([]);
  });

  test("a rename arrives as remove-plus-add and keeps only the new name", () => {
    const result = merge({ labels: ["L1"] }, { labels: ["L2"] }, { labels: ["L1"] });
    expect(result.apply.labels).toEqual(["L2"]);
    expect(result.labelRemoveWins).toEqual(["L1"]);
  });

  test("an unchanged label set is no work", () => {
    const result = merge({ labels: ["bug"] }, { labels: ["bug"] }, { labels: ["bug"] });
    expect(result.labelsChanged).toBe(false);
    expect(result.labelsPush).toBe(false);
    expect(result.apply.labels).toBeUndefined();
  });

  test("the merged set is order-independent and deduplicated", () => {
    const result = merge(
      { labels: ["b", "a", "a"] },
      { labels: ["a", "b"] },
      { labels: ["a", "b"] },
    );
    expect(result.labelsChanged).toBe(false);
    expect(result.labelsPush).toBe(false);
  });
});
