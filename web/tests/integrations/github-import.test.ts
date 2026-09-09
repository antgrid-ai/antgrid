import { describe, expect, test } from "bun:test";
import { GithubIssueSchema, IssuesEventSchema } from "../../src/integrations/github-events.js";
import {
  DEFAULT_LABEL_COLOR,
  foldLocalConflict,
  githubAssignees,
  githubExternalId,
  githubIssueExternalKey,
  githubIssueToRemote,
  githubLabelColors,
  isEmptyLocalConflict,
  matchesImportFilter,
  parseGithubTimestamp,
  parseLocalConflict,
  parseRemoteSnapshot,
  snapshotFromLocal,
} from "../../src/integrations/github-import.js";
import type { LocalFields } from "../../src/tasks/merge.js";

/** Built through the real schema rather than as a literal, so a fixture can
 *  never describe a payload the drain would refuse. */
function issue(overrides: Record<string, unknown> = {}) {
  return GithubIssueSchema.parse({
    id: 1001,
    number: 7,
    title: "Relay drops a frame",
    body: "steps to reproduce",
    state: "open",
    html_url: "https://github.com/acme/relay/issues/7",
    updated_at: "2026-08-18T10:00:00Z",
    ...overrides,
  });
}

/** No provider identity resolves to a member. The overwhelmingly common case,
 *  and the one every assertion about `external` depends on. */
const NO_MEMBERS: ReadonlyMap<string, string> = new Map();

describe("githubIssueToRemote", () => {
  test("maps the provider payload into provider space", () => {
    const remote = githubIssueToRemote(
      issue({
        labels: [{ name: "bug", color: "d73a4a" }, { name: "P1", color: "ffffff" }],
        assignees: [{ id: 5, login: "octocat", avatar_url: "https://avatars/1" }],
      }),
      NO_MEMBERS
    );
    const octocat = {
      kind: "external" as const,
      externalId: "5",
      login: "octocat",
      avatarUrl: "https://avatars/1",
    };
    expect(remote).toEqual({
      title: "Relay drops a frame",
      body: "steps to reproduce",
      status: { state: "open", stateReason: null },
      labels: ["bug", "P1"],
      assignee: octocat,
      assignees: [octocat],
    });
  });

  test("a null body is the empty string, not null", () => {
    expect(githubIssueToRemote(issue({ body: null }), NO_MEMBERS).body).toBe("");
  });

  test("assignees[0] wins over the legacy single assignee", () => {
    const remote = githubIssueToRemote(
      issue({
        assignee: { id: 1, login: "legacy" },
        assignees: [{ id: 2, login: "current" }],
      }),
      NO_MEMBERS
    );
    expect(remote.assignee).toMatchObject({ kind: "external", login: "current" });
  });

  // A provider user nobody in the account has linked is not a member, and
  // inventing one assigns a stranger's work to a colleague.
  test("an unresolved provider assignee is external", () => {
    expect(
      githubIssueToRemote(issue({ assignee: { id: 9, login: "x" } }), NO_MEMBERS).assignee?.kind
    ).toBe("external");
  });

  // The column pair holds one assignee and it should be the one who can act on
  // it, not whichever one GitHub happened to list first.
  test("a resolved member outranks provider order", () => {
    const remote = githubIssueToRemote(
      issue({
        assignees: [
          { id: 1, login: "outsider" },
          { id: 2, login: "teammate" },
        ],
      }),
      new Map([["2", "user-b"]])
    );
    expect(remote.assignee).toEqual({ kind: "member", userId: "user-b" });
  });

  test("with nobody resolved the first assignee is kept", () => {
    const remote = githubIssueToRemote(
      issue({
        assignees: [
          { id: 1, login: "outsider" },
          { id: 2, login: "another" },
        ],
      }),
      NO_MEMBERS
    );
    expect(remote.assignee).toMatchObject({ kind: "external", login: "outsider" });
  });

  // The "+n others on GitHub" marker reads this array, so provider order and
  // the member/external split have to survive into it intact.
  test("the full remote array is carried in provider order", () => {
    const remote = githubIssueToRemote(
      issue({
        assignees: [
          { id: 1, login: "outsider" },
          { id: 2, login: "teammate" },
          { id: 3, login: "third" },
        ],
      }),
      new Map([["2", "user-b"]])
    );
    expect(remote.assignees).toEqual([
      { kind: "external", externalId: "1", login: "outsider", avatarUrl: null },
      { kind: "member", userId: "user-b" },
      { kind: "external", externalId: "3", login: "third", avatarUrl: null },
    ]);
  });

  test("closed states carry the reason verbatim", () => {
    expect(
      githubIssueToRemote(issue({ state: "closed", state_reason: "completed" }), NO_MEMBERS).status
    ).toEqual({ state: "closed", stateReason: "completed" });
    expect(
      githubIssueToRemote(issue({ state: "closed", state_reason: "not_planned" }), NO_MEMBERS).status
    ).toEqual({ state: "closed", stateReason: "not_planned" });
  });

  // GitHub keeps adding reasons; the merge's union cannot grow to meet them, and
  // a value that never equals itself manufactures a diff on every delivery.
  test("a reason outside the merge's vocabulary folds to null", () => {
    expect(
      githubIssueToRemote(issue({ state: "closed", state_reason: "duplicate" }), NO_MEMBERS).status
    ).toEqual({ state: "closed", stateReason: null });
  });
});

describe("githubAssignees", () => {
  // The array is authoritative wherever it is present: GitHub keeps the
  // deprecated singular field pointing at whichever one it picked, so honouring
  // it against an empty array resurrects an assignee the issue no longer has.
  test("an empty array means nobody, never a fallback to the legacy field", () => {
    expect(githubAssignees(issue({ assignee: { id: 1, login: "legacy" }, assignees: [] }))).toEqual(
      []
    );
  });

  test("the legacy field is read only when the array is absent entirely", () => {
    expect(githubAssignees(issue({ assignee: { id: 1, login: "legacy" } }))).toEqual([
      { externalUserId: "1", login: "legacy", avatarUrl: null },
    ]);
    expect(githubAssignees(issue())).toEqual([]);
  });
});

describe("external identity", () => {
  test("the identity is the numeric id, and node_id can never displace it", () => {
    expect(githubExternalId(issue())).toBe("1001");
    // A payload carrying a node id must still key on the same value: a reformat
    // of that id would otherwise orphan every task imported before it.
    expect(githubExternalId(issue({ node_id: "I_kwDOreformatted" }))).toBe("1001");
  });

  test("the key is owner/repo#number", () => {
    expect(githubIssueExternalKey("acme/relay", issue())).toBe("acme/relay#7");
  });
});

describe("githubLabelColors", () => {
  test("a colourless or malformed hex falls back to GitHub's own default", () => {
    const colors = githubLabelColors(
      issue({ labels: [{ name: "bug", color: "d73a4a" }, { name: "chore" }, { name: "x", color: "#fff" }] })
    );
    expect(colors.get("bug")).toBe("d73a4a");
    expect(colors.get("chore")).toBe(DEFAULT_LABEL_COLOR);
    expect(colors.get("x")).toBe(DEFAULT_LABEL_COLOR);
  });
});

describe("matchesImportFilter", () => {
  const labelled = issue({ labels: [{ name: "Bug", color: "d73a4a" }] });

  test("all takes everything", () => {
    expect(
      matchesImportFilter({ importFilterKind: "all", importFilterValue: null }, issue(), NO_MEMBERS)
    ).toBe(true);
  });

  // `Label.name` is citext for exactly this reason: `Bug` and `bug` are one
  // label, so they have to be one filter too.
  test("label matches case-insensitively", () => {
    const filter = { importFilterKind: "label", importFilterValue: "bug" };
    expect(matchesImportFilter(filter, labelled, NO_MEMBERS)).toBe(true);
    expect(matchesImportFilter(filter, issue({ labels: [{ name: "chore" }] }), NO_MEMBERS)).toBe(
      false
    );
    expect(matchesImportFilter(filter, issue(), NO_MEMBERS)).toBe(false);
  });

  test("milestone matches the title", () => {
    const filter = { importFilterKind: "milestone", importFilterValue: "v1" };
    expect(matchesImportFilter(filter, issue({ milestone: { title: "v1" } }), NO_MEMBERS)).toBe(
      true
    );
    expect(matchesImportFilter(filter, issue({ milestone: { title: "v2" } }), NO_MEMBERS)).toBe(
      false
    );
    expect(matchesImportFilter(filter, issue({ milestone: null }), NO_MEMBERS)).toBe(false);
  });

  // The strict reading. An issue assigned to somebody outside the account is
  // precisely what a user picking this filter is asking to keep out, so "has an
  // assignee" is not an acceptable stand-in for "has one of ours".
  test("assigned_to_member wants a resolved member, not just an assignee", () => {
    const filter = { importFilterKind: "assigned_to_member", importFilterValue: null };
    const assigned = issue({ assignees: [{ id: 3, login: "a" }] });
    expect(matchesImportFilter(filter, assigned, new Map([["3", "user-a"]]))).toBe(true);
    expect(matchesImportFilter(filter, assigned, NO_MEMBERS)).toBe(false);
    expect(matchesImportFilter(filter, issue(), new Map([["3", "user-a"]]))).toBe(false);
  });

  test("a kind outside the vocabulary is read as all", () => {
    expect(
      matchesImportFilter(
        { importFilterKind: "nonsense", importFilterValue: null },
        issue(),
        NO_MEMBERS
      )
    ).toBe(true);
  });
});

describe("parseRemoteSnapshot", () => {
  test("a snapshot round-trips through the column", () => {
    const remote = githubIssueToRemote(
      issue({ labels: [{ name: "bug", color: "d73a4a" }] }),
      NO_MEMBERS
    );
    expect(parseRemoteSnapshot(JSON.parse(JSON.stringify(remote)))).toEqual(remote);
  });

  // Every snapshot already in the column predates `assignees`. Reading one has
  // to keep working, or the first delivery after deploy merges against an
  // absent base and takes the remote wholesale over live local edits.
  test("a snapshot written before assignees existed still parses", () => {
    const legacy = {
      title: "t",
      body: "b",
      status: { state: "open", stateReason: null },
      labels: ["bug"],
      assignee: { kind: "external", externalId: "5", login: "octocat", avatarUrl: null },
    };
    const parsed = parseRemoteSnapshot(legacy);
    expect(parsed).not.toBeNull();
    expect(parsed?.assignees).toBeUndefined();
  });

  test("a blob that does not parse is absent, not partially trusted", () => {
    expect(parseRemoteSnapshot(null)).toBeNull();
    expect(parseRemoteSnapshot({ title: "t" })).toBeNull();
    expect(
      parseRemoteSnapshot({
        ...githubIssueToRemote(issue(), NO_MEMBERS),
        status: { state: "merged" },
      })
    ).toBeNull();
  });
});

// The substitute base when no snapshot is readable. `base == local` means no
// field can read as locally moved, so every remote difference applies — which is
// what "take the remote wholesale" means expressed as a base.
describe("snapshotFromLocal", () => {
  test("projects the local row into provider space", () => {
    const local: LocalFields = {
      title: "t",
      body: "b",
      status: "in_progress",
      labels: ["bug"],
      assignee: null,
    };
    expect(snapshotFromLocal(local)).toEqual({
      title: "t",
      body: "b",
      status: { state: "open" },
      labels: ["bug"],
      assignee: null,
    });
  });
});

describe("localConflict", () => {
  const at = new Date("2026-08-18T12:00:00Z");

  test("an unreadable blob reads as empty", () => {
    expect(parseLocalConflict(null)).toEqual({ conflicts: {}, labelRemoveWins: [] });
    expect(isEmptyLocalConflict(parseLocalConflict({ nonsense: true }))).toBe(true);
  });

  // A second conflict must not erase the first, or two deliveries in a row
  // silently complete the data loss the column exists to prevent.
  test("a second conflict accumulates rather than overwriting", () => {
    const first = foldLocalConflict(parseLocalConflict(null), {
      conflicts: [{ field: "title", localValue: "mine", remoteValue: "theirs" }],
      labelRemoveWins: ["bug"],
    }, at);
    const second = foldLocalConflict(first, {
      conflicts: [{ field: "body", localValue: "b1", remoteValue: "b2" }],
      labelRemoveWins: ["chore"],
    }, at);

    expect(Object.keys(second.conflicts).sort()).toEqual(["body", "title"]);
    expect(second.conflicts.title).toMatchObject({ localValue: "mine", remoteValue: "theirs" });
    expect(second.labelRemoveWins).toEqual(["bug", "chore"]);
  });

  test("the same field twice keeps the latest pair", () => {
    const first = foldLocalConflict(parseLocalConflict(null), {
      conflicts: [{ field: "title", localValue: "a", remoteValue: "b" }],
      labelRemoveWins: [],
    }, at);
    const second = foldLocalConflict(first, {
      conflicts: [{ field: "title", localValue: "c", remoteValue: "d" }],
      labelRemoveWins: [],
    }, at);
    expect(second.conflicts.title).toMatchObject({ localValue: "c", remoteValue: "d" });
  });
});

describe("parseGithubTimestamp", () => {
  test("an absent or unparseable timestamp is null, never an Invalid Date", () => {
    expect(parseGithubTimestamp(null)).toBeNull();
    expect(parseGithubTimestamp(undefined)).toBeNull();
    expect(parseGithubTimestamp("not a date")).toBeNull();
    expect(parseGithubTimestamp("2026-08-18T10:00:00Z")?.toISOString()).toBe(
      "2026-08-18T10:00:00.000Z"
    );
  });
});

describe("IssuesEventSchema", () => {
  // The 4b convention: GitHub adds actions, and an enum turns a new one into a
  // payload that fails validation five times and gives up.
  test("an unknown action parses", () => {
    const parsed = IssuesEventSchema.safeParse({
      action: "some_future_action",
      installation: { id: 42 },
      repository: { id: 100, full_name: "acme/relay", private: true },
      issue: { id: 1, number: 1, title: "t", state: "open" },
    });
    expect(parsed.success).toBe(true);
  });

  test("a state outside open/closed is refused rather than guessed at", () => {
    const parsed = IssuesEventSchema.safeParse({
      action: "opened",
      installation: { id: 42 },
      repository: { id: 100, full_name: "acme/relay", private: true },
      issue: { id: 1, number: 1, title: "t", state: "merged" },
    });
    expect(parsed.success).toBe(false);
  });
});
