import { describe, expect, test } from "bun:test";

import { readPushStatus } from "../../src/models/task.js";
import { repoPushReason } from "../../src/tasks/sync-op.js";

const repo = (over: Partial<{ pushEnabled: boolean; removedAt: Date | null; revokedAt: Date | null; owner: string }> = {}) => ({
  pushEnabled: over.pushEnabled ?? true,
  removedAt: over.removedAt ?? null,
  integration: { accountId: over.owner ?? "a1", revokedAt: over.revokedAt ?? null },
});

describe("repoPushReason", () => {
  test("a repo with push on is live", () => {
    expect(repoPushReason(repo(), "a1")).toBe("live");
  });

  test("push switched off on purpose is not read as a broken connection", () => {
    expect(repoPushReason(repo({ pushEnabled: false }), "a1")).toBe("push_off");
  });

  test("a repository removed on GitHub is not live even with push on", () => {
    expect(repoPushReason(repo({ removedAt: new Date() }), "a1")).toBe("repo_removed");
  });

  test("a revoked installation outranks a switched-off push", () => {
    expect(repoPushReason(repo({ revokedAt: new Date(), pushEnabled: false }), "a1")).toBe("revoked");
  });

  test("another account's installation is named as such", () => {
    expect(repoPushReason(repo({ owner: "a2" }), "a1")).toBe("other_account");
  });
});

describe("readPushStatus", () => {
  const at = (s: string) => new Date(s);

  test("nothing outstanding reads as null", () => {
    expect(readPushStatus([])).toBeNull();
    expect(readPushStatus([{ status: "processed", lastError: null, nextAttemptAt: at("2026-01-01"), attempts: 0 }])).toBeNull();
  });

  test("a pending op that has failed before is retrying, with its error", () => {
    const status = readPushStatus([
      { status: "pending", lastError: "502", nextAttemptAt: at("2026-01-02"), attempts: 2 },
    ]);
    expect(status).toMatchObject({ state: "retrying", pending: 1, lastError: "502" });
  });

  test("an old refusal behind a processed op is not still true", () => {
    expect(
      readPushStatus([
        { status: "processed", lastError: null, nextAttemptAt: at("2026-01-03"), attempts: 0 },
        { status: "given_up", lastError: "422", nextAttemptAt: at("2026-01-02"), attempts: 5 },
      ])
    ).toBeNull();
  });

  test("a newest op that gave up is failed, with its error", () => {
    expect(
      readPushStatus([{ status: "given_up", lastError: "422 Validation Failed", nextAttemptAt: at("2026-01-02"), attempts: 5 }])
    ).toMatchObject({ state: "failed", lastError: "422 Validation Failed" });
  });
});
