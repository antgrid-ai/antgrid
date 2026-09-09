import { describe, test, expect } from "bun:test";
import { isValidRepoKey } from "../../src/util/repo-key.js";

/**
 * The two copies of this rule (here and `bridge/src/repo-key.ts`) can only drift
 * silently, so the accepted cases are stated as bridge INPUTS beside the key
 * `normalizeRepoKey` folds them to. A rule web gains or loses then shows up as a
 * real bridge output this rejects.
 */
const BRIDGE_OUTPUTS: Record<string, string> = {
  "git@github.com:antgrid/antgrid.git": "github.com/antgrid/antgrid",
  "https://github.com/Antgrid/Antgrid.git": "github.com/antgrid/antgrid",
  "ssh://git@github.com:2222/antgrid/antgrid.git": "github.com/antgrid/antgrid",
  "https://user:pw@gitlab.com/group/subgroup/repo.git": "gitlab.com/group/subgroup/repo",
  "https://git.self-hosted.example.com/team/tool": "git.self-hosted.example.com/team/tool",
  "git@github.com:owner/repo.with.dots.git": "github.com/owner/repo.with.dots",
};

/**
 * Strings no bridge can produce: raw remotes `normalizeRepoKey` answers `null`
 * for (a client sending one unfolded must be refused, not stored), and keys that
 * break the host or segment class.
 */
const NEVER_A_KEY = [
  "file:///home/me/repo.git",
  "https://github.com/antgrid",
  "https://github.com/antgrid/../antgrid.git",
  "C:/Users/me/repo",
  "github.com/UPPER/case",
  "github.com/owner/repo space",
  "-github.com/owner/repo",
  "github.com//owner",
  "",
];

describe("isValidRepoKey", () => {
  test("accepts every key the bridge's normalization produces", () => {
    const rejected = Object.entries(BRIDGE_OUTPUTS)
      .filter(([, key]) => !isValidRepoKey(key))
      .map(([remote, key]) => `${remote} -> ${key}`);
    expect(rejected).toEqual([]);
  });

  test("accepts the synthetic per-machine key", () => {
    expect(isValidRepoKey(`local:${crypto.randomUUID()}/proj-1`)).toBe(true);
  });

  test("rejects anything the bridge would never hand over", () => {
    expect(NEVER_A_KEY.filter((v) => isValidRepoKey(v))).toEqual([]);
  });

  test("rejects traversal segments in either branch", () => {
    expect(isValidRepoKey("github.com/owner/..")).toBe(false);
    expect(isValidRepoKey("github.com/../repo")).toBe(false);
    expect(isValidRepoKey("local:../proj")).toBe(false);
    expect(isValidRepoKey("local:dev/..")).toBe(false);
    expect(isValidRepoKey("local:./proj")).toBe(false);
  });

  test("a synthetic key holds exactly two segments", () => {
    expect(isValidRepoKey("local:dev")).toBe(false);
    expect(isValidRepoKey("local:dev/proj/extra")).toBe(false);
  });

  test("a host-form key needs a host and at least two path segments", () => {
    expect(isValidRepoKey("github.com/owner")).toBe(false);
    // The FULL path is kept, so a GitLab subgroup is valid rather than folded.
    expect(isValidRepoKey("github.com/owner/repo/sub")).toBe(true);
  });

  test("enforces the same 512-byte bound", () => {
    const long = `github.com/owner/${"a".repeat(512)}`;
    expect(long.length).toBeGreaterThan(512);
    expect(isValidRepoKey(long)).toBe(false);
    const atBound = `github.com/owner/${"a".repeat(495)}`;
    expect(atBound.length).toBe(512);
    expect(isValidRepoKey(atBound)).toBe(true);
  });
});
