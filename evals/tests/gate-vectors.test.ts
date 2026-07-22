import { test, expect } from "bun:test";
import { execSync } from "node:child_process";
import { resolve } from "node:path";

const ROOT = resolve(import.meta.dir, "../..");

/**
 * Merge-gate item 1 (design §12): the v2 handshake crypto (domain, transcript,
 * key schedule, confirm tags, transport framing) is byte-for-byte unchanged in
 * v3, and the golden vectors pin that. This is a thin CI-friendly proxy for
 * that invariant — it does NOT re-run the bridge/Dart vector suites (those are
 * run-and-reported separately per the phase X4 work order) — it just asserts
 * nobody touched the fixture those suites are pinned against. A dirty diff
 * here means either the vectors were regenerated (regression risk) or the
 * fixture was hand-edited; both require re-running the two vector suites
 * before merge.
 */
test("gate: e2e-handshake-vectors.json is git-clean (crypto regression guard)", () => {
  const diff = execSync("git diff --stat -- evals/fixtures/e2e-handshake-vectors.json", {
    cwd: ROOT,
    encoding: "utf8",
  });
  expect(diff.trim()).toBe("");
});
