import { test, expect } from "bun:test";
import { execSync } from "node:child_process";
import { resolve } from "node:path";

const ROOT = resolve(import.meta.dir, "../..");

/**
 * Merge-gate: the golden-vector fixtures are the pins between independent
 * implementations, and a dirty fixture means the pinned suites were not
 * re-run against it:
 * - relay-envelope-vectors.json: the antgrid-wire Zod schemas vs the
 *   hand-mirrored Dart parser; pinned by
 *   packages/antgrid-wire/tests/relay-envelope-vectors.test.ts and
 *   packages/antgrid_relay_client/test/relay_envelope_vectors_test.dart.
 * - peer-transport-vectors.json: session-record bytes plus native, flow-control,
 *   and authorization constants shared by the TS and Dart implementations.
 *
 * `git status --porcelain` on purpose, not plain `git diff`: plain diff is
 * blind to a regenerated fixture that was already `git add`ed AND to an
 * untracked or deleted fixture — all states in which the pin is not what the
 * committed suites verified. A not-yet-committed fixture therefore fails this
 * gate until it lands; that is the gate working, not a false positive.
 */
const PINNED_FIXTURES = [
  "evals/fixtures/relay-envelope-vectors.json",
  "evals/fixtures/peer-transport-vectors.json",
];

for (const fixture of PINNED_FIXTURES) {
  test(`gate: ${fixture} is committed and git-clean (regression guard)`, () => {
    const status = execSync(`git status --porcelain -- ${fixture}`, {
      cwd: ROOT,
      encoding: "utf8",
    });
    expect(status.trim()).toBe("");
  });
}
