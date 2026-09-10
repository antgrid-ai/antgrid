import { test, expect } from "bun:test";
import type { SessionEntry } from "../src/protocol";
import {
  MAX_DIRECTORY_ROWS,
  SessionDirectory,
  directoryRowsFor,
  machineDirectoryRows,
  sortDirectory,
  withLocalFloor,
  type DirectorySessions,
  type SessionDirectoryResult,
  type SessionDirectoryRow,
} from "../src/session-bus/directory";
import { LOCAL_ROW_FLOOR } from "../src/session-bus/constants";

const KEY = "github.com/owner/repo";

function session(over: Partial<SessionEntry> & { id: string }): SessionEntry {
  return {
    name: `title ${over.id}`,
    createdAt: 0,
    lastUsedAt: 1_000,
    archived: false,
    running: true,
    deleting: false,
    forkSupported: false,
    mode: "terminal",
    approvalPolicy: "default",
    agentSessionResumable: true,
    tool: "claude-code",
    ...over,
  } as SessionEntry;
}

/** A machine described as projectId -> { repo key, branch, sessions }. A key of
 *  `undefined` is a project the probe has not answered for yet; `null` is one
 *  that answered and has no remote. */
function directory(
  projects: Record<string, { key?: string | null; branch: string | null; sessions: SessionEntry[]; label?: string }>,
) {
  return new SessionDirectory({
    repoKeys: {
      keyFor: (id) => projects[id]?.key ?? null,
      probed: (id) => projects[id]?.key !== undefined,
      projectsSharing: (key) => (key === null ? [] : Object.keys(projects).filter((id) => projects[id]!.key === key)),
    },
    sessionIndex: {
      *sessionsIn(projectId) {
        const p = projects[projectId];
        if (!p) return;
        for (const entry of p.sessions) yield p.label === undefined ? { entry } : { entry, projectLabel: p.label };
      },
    },
    projectPath: (id) => (projects[id] ? `/repos/${id}` : undefined),
    machineId: () => "machine-1",
    readBranch: async (path) => projects[path.slice("/repos/".length)]?.branch ?? null,
  });
}

/** Unwrap a directory that must have been served. Tests that assert a REFUSAL
 *  read `list` directly. */
function served(answer: SessionDirectoryResult) {
  if (!answer.ok) throw new Error(`expected a directory, got ${answer.reason}`);
  return answer;
}

test("a worktree session and its parent see each other across two project ids", async () => {
  // The whole reason the bus went machine-level: these hash to different
  // project ids and are one repository.
  const d = directory({
    parent: { key: KEY, branch: "main", sessions: [session({ id: "s-parent" })] },
    worktree: { key: KEY, branch: "fix/auth", sessions: [session({ id: "s-worktree" })] },
  });

  const fromParent = served(await d.list({ projectId: "parent", sessionId: "s-parent" }));
  expect(fromParent.rows.map((r) => r.sessionId)).toEqual(["s-worktree"]);
  expect(fromParent.rows[0]!.projectId).toBe("worktree");
  expect(fromParent.rows[0]!.branch).toBe("fix/auth");

  const fromWorktree = served(await d.list({ projectId: "worktree", sessionId: "s-worktree" }));
  expect(fromWorktree.rows.map((r) => r.sessionId)).toEqual(["s-parent"]);
});

test("a project on another remote is not a peer", async () => {
  const d = directory({
    mine: { key: KEY, branch: "main", sessions: [session({ id: "s-mine" })] },
    theirs: { key: "github.com/other/thing", branch: "main", sessions: [session({ id: "s-theirs" })] },
  });
  const answer = served(await d.list({ projectId: "mine", sessionId: "s-mine" }));
  expect(answer.rows).toEqual([]);
});

test("a project with no remote is refused, not shown an empty list", async () => {
  // 5.1 fails closed, and two keyless projects are not peers of each other. A
  // refusal and [] are different answers: one says "you cannot be addressed",
  // the other says "nobody is there".
  const d = directory({
    keyless: { key: null, branch: "main", sessions: [session({ id: "s-a" })] },
    alsoKeyless: { key: null, branch: "main", sessions: [session({ id: "s-b" })] },
  });
  expect(await d.list({ projectId: "keyless", sessionId: "s-a" })).toEqual({ ok: false, reason: "no-remote" });
});

test("a project the probe has not answered for yet is refused differently", async () => {
  // Same empty list, very different bug report: this one becomes addressable on
  // its own, so a caller must not be told it never can be.
  const d = directory({ warming: { branch: "main", sessions: [session({ id: "s-a" })] } });
  expect(await d.list({ projectId: "warming", sessionId: "s-a" })).toEqual({ ok: false, reason: "not-probed" });
});

test("the caller, archived sessions and mid-delete sessions are all absent", async () => {
  const d = directory({
    p: {
      key: KEY,
      branch: "main",
      sessions: [
        session({ id: "self" }),
        session({ id: "archived", archived: true }),
        session({ id: "deleting", deleting: true }),
        session({ id: "real" }),
      ],
    },
  });
  const answer = served(await d.list({ projectId: "p", sessionId: "self" }));
  expect(answer.rows.map((r) => r.sessionId)).toEqual(["real"]);
});

test("canReply follows the vendor's mcp profile, and an unknown tool is receive-only", async () => {
  const d = directory({
    p: {
      key: KEY,
      branch: "main",
      sessions: [
        session({ id: "claude", tool: "claude-code" }),
        session({ id: "codex", tool: "codex" }),
        session({ id: "gemini", tool: "gemini" }),
        session({ id: "nameless", tool: undefined }),
        session({ id: "caller" }),
      ],
    },
  });
  const answer = served(await d.list({ projectId: "p", sessionId: "caller" }));
  const byId = new Map(answer.rows.map((r) => [r.sessionId, r.canReply]));
  expect(byId.get("claude")).toBe(true);
  expect(byId.get("codex")).toBe(true);
  expect(byId.get("gemini")).toBe(false);
  expect(byId.get("nameless")).toBe(false);
});

test("activity reduces a live turn, a live-but-quiet slot and a stopped one to three ranks", async () => {
  const d = directory({
    p: {
      key: KEY,
      branch: "main",
      sessions: [
        session({ id: "working", running: true, workStatus: "working" }),
        session({ id: "attention", running: true, workStatus: "attention" }),
        session({ id: "done", running: true, workStatus: "done" }),
        session({ id: "quiet", running: true }),
        session({ id: "stopped", running: false, workStatus: "working" }),
        session({ id: "caller" }),
      ],
    },
  });
  const answer = served(await d.list({ projectId: "p", sessionId: "caller" }));
  const byId = new Map(answer.rows.map((r) => [r.sessionId, r.activity]));
  expect(byId.get("working")).toBe("running");
  expect(byId.get("attention")).toBe("running");
  expect(byId.get("done")).toBe("idle");
  expect(byId.get("quiet")).toBe("idle");
  // Stopped outranks whatever status it died holding.
  expect(byId.get("stopped")).toBe("stopped");
});

test("a truncated directory says how many rows it dropped", async () => {
  const many = Array.from({ length: MAX_DIRECTORY_ROWS + 5 }, (_, i) =>
    session({ id: `s-${String(i).padStart(3, "0")}` }));
  const d = directory({ p: { key: KEY, branch: "main", sessions: [...many, session({ id: "caller" })] } });
  const answer = served(await d.list({ projectId: "p", sessionId: "caller" }));
  expect(answer.rows.length).toBe(MAX_DIRECTORY_ROWS);
  expect(answer.truncated).toBe(5);
});

// -- the sort, on its own --------------------------------------------------

function row(over: Partial<SessionDirectoryRow> & { sessionId: string }): SessionDirectoryRow {
  return {
    machineId: "m",
    projectId: "p",
    title: over.sessionId,
    branch: "main",
    activity: "idle",
    lastActiveAt: 0,
    canReply: true,
    ...over,
  };
}

test("sortDirectory orders by branch, then activity, then recency, then can-reply", () => {
  const ordered = sortDirectory(
    [
      row({ sessionId: "other-branch-running", branch: "other", activity: "running", lastActiveAt: 9_000 }),
      row({ sessionId: "same-stopped", activity: "stopped", lastActiveAt: 9_000 }),
      row({ sessionId: "same-idle-old", activity: "idle", lastActiveAt: 1 }),
      row({ sessionId: "same-idle-new", activity: "idle", lastActiveAt: 5_000 }),
      row({ sessionId: "same-running", activity: "running", lastActiveAt: 1 }),
    ],
    "main",
  ).map((r) => r.sessionId);

  // Same branch beats a more active session on another branch — the first key
  // is deliberately the strongest.
  expect(ordered).toEqual([
    "same-running",
    "same-idle-new",
    "same-idle-old",
    "same-stopped",
    "other-branch-running",
  ]);
});

test("can-reply breaks a tie that recency does not", () => {
  const ordered = sortDirectory(
    [
      row({ sessionId: "receive-only", canReply: false, lastActiveAt: 100 }),
      row({ sessionId: "answers", canReply: true, lastActiveAt: 100 }),
    ],
    "main",
  ).map((r) => r.sessionId);
  expect(ordered).toEqual(["answers", "receive-only"]);
});

test("a caller on a detached HEAD ranks nobody on branch, and still sorts", () => {
  const ordered = sortDirectory(
    [
      row({ sessionId: "b", branch: "main", activity: "idle" }),
      row({ sessionId: "a", branch: null, activity: "running" }),
    ],
    null,
  ).map((r) => r.sessionId);
  expect(ordered).toEqual(["a", "b"]);
});

test("a project that can contribute no row costs no branch probe", async () => {
  // The probe is a git spawn per project. A machine with one repository open
  // under many project ids would otherwise pay for every one of them on every
  // list_sessions call, for projects that cannot appear in the answer.
  const probed: string[] = [];
  const d = new SessionDirectory({
    repoKeys: {
      keyFor: () => KEY,
      probed: () => true,
      projectsSharing: () => ["caller", "has-a-session", "empty", "only-archived"],
    },
    sessionIndex: {
      *sessionsIn(projectId) {
        if (projectId === "caller") yield { entry: session({ id: "me" }) };
        if (projectId === "has-a-session") yield { entry: session({ id: "them" }) };
        if (projectId === "only-archived") yield { entry: session({ id: "gone", archived: true }) };
      },
    },
    projectPath: (id) => `/repos/${id}`,
    machineId: () => "m",
    readBranch: async (path) => {
      probed.push(path.slice("/repos/".length));
      return "main";
    },
  });

  const answer = served(await d.list({ projectId: "caller", sessionId: "me" }));
  expect(answer.rows.map((r) => r.sessionId)).toEqual(["them"]);
  // The caller's own project is probed even though it contributed no row: its
  // branch is what every other row is ranked against.
  expect(probed.sort()).toEqual(["caller", "has-a-session"]);
});

test("the caller's branch still ranks the rows after the probe set was narrowed", async () => {
  const d = directory({
    caller: { key: KEY, branch: "fix/auth", sessions: [session({ id: "me" })] },
    onBranch: { key: KEY, branch: "fix/auth", sessions: [session({ id: "same", lastUsedAt: 1 })] },
    offBranch: { key: KEY, branch: "main", sessions: [session({ id: "other", lastUsedAt: 9_000 })] },
  });
  const answer = served(await d.list({ projectId: "caller", sessionId: "me" }));
  // Same branch outranks a much more recent session elsewhere — proof the
  // caller's own branch reached the sort.
  expect(answer.rows.map((r) => r.sessionId)).toEqual(["same", "other"]);
});

// -- the shared row builder -------------------------------------------------

test("directoryRowsFor and list agree on canReply, activity and the omitted fields", async () => {
  const sessionIndex: DirectorySessions = {
    *sessionsIn(projectId) {
      if (projectId !== "p") return;
      yield { entry: session({ id: "labeled", tool: "codex", workStatus: "working" }), projectLabel: "Label" };
      yield { entry: session({ id: "bare", tool: undefined }) };
    },
  };

  const direct = directoryRowsFor(sessionIndex, "p");
  const labeled = direct.find((r) => r.sessionId === "labeled")!;
  expect(labeled.canReply).toBe(true);
  expect(labeled.activity).toBe("running");
  expect(labeled.projectLabel).toBe("Label");
  expect(labeled.workStatus).toBe("working");
  const bare = direct.find((r) => r.sessionId === "bare")!;
  expect(bare.canReply).toBe(false);
  expect("projectLabel" in bare).toBe(false);
  expect("workStatus" in bare).toBe(false);

  const d = new SessionDirectory({
    repoKeys: { keyFor: () => KEY, probed: () => true, projectsSharing: () => ["p"] },
    sessionIndex,
    projectPath: () => "/repos/p",
    machineId: () => "machine-1",
    readBranch: async () => "main",
  });
  const answer = served(await d.list({ projectId: "p", sessionId: "caller" }));
  const byId = new Map(answer.rows.map((r) => [r.sessionId, r]));
  expect(byId.get("labeled")!.canReply).toBe(true);
  expect(byId.get("labeled")!.activity).toBe("running");
  expect("projectLabel" in byId.get("bare")!).toBe(false);
  expect("workStatus" in byId.get("bare")!).toBe(false);
});

test("machineDirectoryRows drops a project with no repo key and reports what the cap dropped", () => {
  const sessionIndex: DirectorySessions = {
    *sessionsIn(projectId) {
      if (projectId === "no-key") {
        yield { entry: session({ id: "orphan" }) };
        return;
      }
      if (projectId === "many") {
        for (let i = 0; i < 5; i++) yield { entry: session({ id: `s-${i}` }) };
      }
    },
  };

  const { rows, truncated } = machineDirectoryRows(
    sessionIndex,
    [
      { projectId: "no-key", repoKey: null, branch: "main" },
      { projectId: "many", repoKey: KEY, branch: "main" },
    ],
    3,
  );
  // The keyless project contributes nothing — a session is addressed by repo
  // key, so one it cannot carry is not offerable.
  expect(rows.every((r) => r.projectId === "many")).toBe(true);
  expect(rows.length).toBe(3);
  expect(truncated).toBe(2);
});

test("withLocalFloor keeps the agent's own machine when a peer outranks every local row", () => {
  // More peer rows than the cap, all ranked ahead of every local row on
  // activity alone — a naive cap would evict this machine's rows entirely.
  const peerRows = Array.from({ length: MAX_DIRECTORY_ROWS + 5 }, (_, i) =>
    row({ sessionId: `peer-${i}`, machineId: "peer", activity: "running", lastActiveAt: 1_000 - i }));
  const localRows = Array.from({ length: LOCAL_ROW_FLOOR + 5 }, (_, i) =>
    row({ sessionId: `local-${i}`, machineId: "local", activity: "idle", lastActiveAt: 1 }));
  const sorted = sortDirectory([...peerRows, ...localRows], "main");

  // Sanity: this is the failure the floor exists to prevent.
  expect(sorted.slice(0, MAX_DIRECTORY_ROWS).some((r) => r.machineId === "local")).toBe(false);

  const bounded = withLocalFloor(sorted, "local", MAX_DIRECTORY_ROWS, LOCAL_ROW_FLOOR);
  expect(bounded.length).toBe(MAX_DIRECTORY_ROWS);
  expect(bounded.filter((r) => r.machineId === "local").length).toBe(LOCAL_ROW_FLOOR);
});

test("withLocalFloor leaves an all-local list under the cap untouched, and caps one over it plainly", () => {
  // Under the cap there is nothing to trim, floor or no floor.
  const few = sortDirectory(
    Array.from({ length: 4 }, (_, i) => row({ sessionId: `local-${i}`, machineId: "local", lastActiveAt: i })),
    "main",
  );
  expect(withLocalFloor(few, "local", 10, 2)).toEqual(few);

  // Over the cap with no peer to protect against, the floor has nothing to do —
  // the cap alone decides, so the survivors are exactly the top of `sorted`.
  const many = sortDirectory(
    Array.from({ length: 8 }, (_, i) => row({ sessionId: `local-${i}`, machineId: "local", lastActiveAt: i })),
    "main",
  );
  expect(withLocalFloor(many, "local", 3, 2)).toEqual(many.slice(0, 3));
});

test("machineDirectoryRows spends its cap on the rows worth carrying, not on iteration order", () => {
  const sessionIndex: DirectorySessions = {
    *sessionsIn(projectId) {
      if (projectId === "idle-first") {
        for (let i = 0; i < 5; i++) yield { entry: session({ id: `idle-${i}`, workStatus: "done" }) };
        return;
      }
      if (projectId === "running-last") {
        yield { entry: session({ id: "live", workStatus: "working", lastUsedAt: 2_000 }) };
      }
    },
  };

  const { rows, truncated } = machineDirectoryRows(
    sessionIndex,
    [
      { projectId: "idle-first", repoKey: KEY, branch: "main" },
      { projectId: "running-last", repoKey: KEY, branch: "main" },
    ],
    2,
  );
  // The cut is the one thing the asking machine cannot undo: a row that did not
  // travel is unrecoverable by any sort on the other side.
  expect(rows[0]!.sessionId).toBe("live");
  expect(truncated).toBe(4);
});

test("withLocalFloor never returns more rows than the cap it was given", () => {
  const rows = sortDirectory(
    Array.from({ length: 6 }, (_, i) => row({ sessionId: `local-${i}`, machineId: "local", lastActiveAt: i })),
    "main",
  );
  // A floor tuned above the cap is a caller mistake, and the honest answer to it
  // is the cap — a longer list would be counted as truncated by nobody.
  expect(withLocalFloor(rows, "local", 2, 4).length).toBe(2);
  expect(withLocalFloor(rows, "local", 0, 4)).toEqual([]);
});
