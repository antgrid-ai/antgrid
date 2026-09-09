import { describe, expect, test } from "bun:test";
import { isValidRepoKey, normalizeRepoKey, syntheticRepoKey } from "../src/repo-key";

// Every task table keys off this string, so a rule that changes after keys exist
// in the field is a data migration rather than a fix. The table is therefore the
// spec, not a sample of it.
const FOLDS: Array<[label: string, remote: string, key: string]> = [
  ["https with .git", "https://github.com/antgrid/antgrid.git", "github.com/antgrid/antgrid"],
  ["https without .git", "https://github.com/antgrid/antgrid", "github.com/antgrid/antgrid"],
  ["https with trailing slash", "https://github.com/antgrid/antgrid.git/", "github.com/antgrid/antgrid"],
  ["https with userinfo", "https://user:token@github.com/antgrid/antgrid.git", "github.com/antgrid/antgrid"],
  ["plain http", "http://github.com/antgrid/antgrid.git", "github.com/antgrid/antgrid"],
  ["scp form", "git@github.com:antgrid/antgrid.git", "github.com/antgrid/antgrid"],
  ["ssh url", "ssh://git@github.com/antgrid/antgrid.git", "github.com/antgrid/antgrid"],
  ["ssh url on a non-default port", "ssh://git@github.com:2222/antgrid/antgrid.git", "github.com/antgrid/antgrid"],
  ["git protocol", "git://github.com/antgrid/antgrid.git", "github.com/antgrid/antgrid"],
  ["mixed case host, owner and name", "https://GitHub.COM/AntGrid/AntGrid.GIT", "github.com/antgrid/antgrid"],
  ["GitLab subgroup", "https://gitlab.com/group/sub/repo.git", "gitlab.com/group/sub/repo"],
  ["self-hosted host with a port", "ssh://git@git.example.co.uk:2222/team/repo.git", "git.example.co.uk/team/repo"],
];

const REFUSED: Array<[label: string, remote: string | null | undefined]> = [
  ["null", null],
  ["undefined", undefined],
  ["empty", ""],
  ["whitespace only", "   \t\n "],
  ["a single path segment", "https://github.com/antgrid"],
  ["a host with no path", "https://github.com"],
  ["a file url", "file:///c/repos/x"],
  ["a bare Windows path", "C:\\repos\\x"],
  ["a bare relative path", "../sibling/repo"],
  ["a bare relative path with no colon", "repos/x"],
  ["an over-long url", `https://github.com/antgrid/${"a".repeat(600)}`],
  ["a newline inside a segment", "https://github.com/ant\ngrid/antgrid.git"],
  ["a control character inside a segment", "https://github.com/antgrid/antg\u0000rid"],
  ["a control character inside the host", "https://git\u0007hub.com/antgrid/antgrid"],
  ["a traversal segment", "https://github.com/antgrid/../antgrid.git"],
];

describe("normalizeRepoKey", () => {
  for (const [label, remote, key] of FOLDS) {
    test(`folds ${label}`, () => {
      expect(normalizeRepoKey(remote)).toBe(key);
    });
  }

  test("every github.com spelling of one repository is a single key", () => {
    const keys = new Set(
      FOLDS.filter(([, remote]) => /github\.com/i.test(remote)).map(([, remote]) => normalizeRepoKey(remote)),
    );
    expect([...keys]).toEqual(["github.com/antgrid/antgrid"]);
  });

  for (const [label, remote] of REFUSED) {
    test(`refuses ${label}`, () => {
      expect(normalizeRepoKey(remote)).toBeNull();
    });
  }
});

describe("isValidRepoKey", () => {
  // The bridge produces these and web stores them behind this same shape gate,
  // so a normalized key its own producer's gate rejects is a route that refuses
  // its own bridge's projects.
  test("accepts every key normalizeRepoKey produces", () => {
    for (const [, remote] of FOLDS) {
      const key = normalizeRepoKey(remote);
      expect(key).not.toBeNull();
      expect(isValidRepoKey(key!)).toBe(true);
    }
  });

  test("accepts a synthetic per-machine key", () => {
    const key = syntheticRepoKey("6f1c9e3a-2b4d-4c8e-9f1a-0d7b5e2c4a86", "a3f19c04b7e25d68");
    expect(key).toBe("local:6f1c9e3a-2b4d-4c8e-9f1a-0d7b5e2c4a86/a3f19c04b7e25d68");
    expect(isValidRepoKey(key)).toBe(true);
  });
});
