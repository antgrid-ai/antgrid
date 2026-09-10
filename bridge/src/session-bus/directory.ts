// The answer to "who could I talk to" (`docs/session-messaging.md` §5.5), and
// deliberately not to "who should I talk to": the bridge sorts on facts it can
// check and hands the agent a judgeable row, because it is guessing with
// strictly less context than the agent asking.
//
// TWO CLOCKS, ON PURPOSE. The repo key comes from the edge-refreshed
// `SessionBusRepoKeys` — a remote almost never changes, and reading it from
// memory is what bounds the candidate set to one repository before anything
// expensive happens. The branch is then probed FRESH, at request time, for that
// bounded set only: it moves on every checkout, it is what the sort's first key
// reads, and §5.5 puts the whole set at 3-15 rows rather than the 149 a
// directory-name list degrades to. Probing branches for every project on the
// machine would invert that — the cheap cached fact exists to scope the
// expensive fresh one.

import { inProbePool, readRepoCard } from "../capability-card";
import { agentSpec } from "../agents/registry";
import type { SessionEntry, WorkStatus } from "../protocol";

/** Rows one directory read may return. Generous against §5.5's expected 3-15:
 *  the bound exists so a machine that has opened one repository under many
 *  project ids cannot hand an agent an unreadable list, not to ration a normal
 *  answer. A read that hits it says so — see {@link SessionDirectory.list}. */
export const MAX_DIRECTORY_ROWS = 60;

/** What a session is doing, reduced to the three ranks §5.5 sorts on. Narrower
 *  than {@link WorkStatus} because a directory row is scanned, not diagnosed:
 *  the full status rides `workStatus` for a caller that wants it. */
export type DirectoryActivity = "running" | "idle" | "stopped";

export interface SessionDirectoryRow {
  /** Null in local mode, where no frame can leave the machine to need one. */
  machineId: string | null;
  projectId: string;
  projectLabel?: string;
  sessionId: string;
  /** The generated title (`agents/title-generate.ts` writes it through the
   *  session namer), or whatever the human renamed the session to. This is the
   *  field that makes the row judgeable rather than an id. */
  title: string;
  branch: string | null;
  activity: DirectoryActivity;
  workStatus?: WorkStatus;
  lastActiveAt: number;
  /** Whether this session's agent can be messaged back — it declares an `mcp`
   *  profile (§9). A receive-only vendor is listed and says so, rather than
   *  being offered as a peer that will never answer. */
  canReply: boolean;
}

/** The half of {@link SessionBusRepoKeys} a directory reads. Narrow on purpose:
 *  nothing here may refresh a key, so a directory read can never turn into the
 *  git spawn its whole design exists to keep off the request path. */
export interface DirectoryRepoKeys {
  keyFor(projectId: string): string | null;
  probed(projectId: string): boolean;
  projectsSharing(key: string | null): string[];
}

/** The half of {@link SessionBusSessionIndex} a directory reads. */
export interface DirectorySessions {
  sessionsIn(projectId: string): Iterable<{ entry: SessionEntry; projectLabel?: string }>;
}

export interface SessionDirectoryDeps {
  repoKeys: DirectoryRepoKeys;
  sessionIndex: DirectorySessions;
  /** Where a project is checked out, for the branch probe. Undefined for a
   *  project the host has no path for, whose rows then carry a null branch
   *  rather than being dropped — a session is addressable by repo key, and the
   *  branch is only a ranking hint. */
  projectPath(projectId: string): string | undefined;
  machineId(): string | null;
  /** The branch probe, injectable so a directory test costs no git spawn. The
   *  default is the same  the capability card uses, which is what
   *  keeps the two surfaces answering one branch. */
  readBranch?(projectPath: string): Promise<string | null>;
}

function activityOf(entry: SessionEntry): DirectoryActivity {
  if (!entry.running) return "stopped";
  // `attention` outranks `working` nowhere in this reduction on purpose: both
  // mean a live turn, and which of the two it is belongs in `workStatus`, which
  // travels beside this. Only the three-way rank is sorted on.
  return entry.workStatus === "working" || entry.workStatus === "attention" ? "running" : "idle";
}

const ACTIVITY_RANK: Record<DirectoryActivity, number> = { running: 0, idle: 1, stopped: 2 };

/**
 * §5.5's sort, and all of it: same branch, then activity, then recency, then
 * can-reply. Objective ordering rather than a relevance score, and the line is
 * deliberate — every key here is a fact the bridge can check.
 *
 * `callerBranch` of null (a detached HEAD, or a project with no path) simply
 * makes the first key inert, which is the right degradation: nothing is ranked
 * above anything else on a branch nobody is on.
 */
export function sortDirectory(rows: SessionDirectoryRow[], callerBranch: string | null): SessionDirectoryRow[] {
  return [...rows].sort((a, b) => {
    const sameBranch = (r: SessionDirectoryRow) => (callerBranch !== null && r.branch === callerBranch ? 0 : 1);
    return sameBranch(a) - sameBranch(b)
      || ACTIVITY_RANK[a.activity] - ACTIVITY_RANK[b.activity]
      || b.lastActiveAt - a.lastActiveAt
      || Number(b.canReply) - Number(a.canReply)
      // Ids last, so a machine with two identical rows still answers in a
      // stable order across calls rather than shuffling under the agent.
      || a.sessionId.localeCompare(b.sessionId);
  });
}

/**
 * Either the directory, or why there is none.
 *
 * The two refusals are separated because they are the same empty list and very
 * different bug reports: `no-remote` is permanent and is the project's own
 * answer (5.1 fails closed on it), while `not-probed` is a project whose git
 * probe has not run yet and which becomes addressable on its own.
 */
export type SessionDirectoryResult =
  | {
      ok: true;
      rows: SessionDirectoryRow[];
      /** Rows the bound dropped. Never silent: a truncated list that claims to
       *  be complete reads as "there is nobody else", which is the one wrong
       *  answer a directory can give. */
      truncated: number;
    }
  | { ok: false; reason: "no-remote" | "not-probed" };

export class SessionDirectory {
  constructor(private readonly deps: SessionDirectoryDeps) {}

  /**
   * Every session addressable from `caller`, sorted.
   *
   * The caller's own row is excluded, and so is every archived or mid-delete
   * session: a row you cannot message is worse than no row, because it costs a
   * turn to find out.
   *
   * A caller whose project has no repo key gets a refusal, never an empty list — §5.1 fails
   * closed, and the surface above states which of the two reasons it was.
   */
  async list(caller: { projectId: string; sessionId: string }): Promise<SessionDirectoryResult> {
    const key = this.deps.repoKeys.keyFor(caller.projectId);
    if (!key) return { ok: false, reason: this.deps.repoKeys.probed(caller.projectId) ? "no-remote" : "not-probed" };

    const projects = this.deps.repoKeys.projectsSharing(key);
    const readBranch = this.deps.readBranch ?? (async (path: string) => (await readRepoCard(path)).branch);
    const branches = new Map<string, string | null>();
    await inProbePool(projects, async (projectId) => {
      const path = this.deps.projectPath(projectId);
      branches.set(projectId, path ? await readBranch(path) : null);
    });

    const machineId = this.deps.machineId();
    const rows: SessionDirectoryRow[] = [];
    for (const projectId of projects) {
      for (const { entry, projectLabel } of this.deps.sessionIndex.sessionsIn(projectId)) {
        if (entry.id === caller.sessionId) continue;
        if (entry.archived || entry.deleting) continue;
        rows.push({
          machineId,
          projectId,
          ...(projectLabel === undefined ? {} : { projectLabel }),
          sessionId: entry.id,
          title: entry.name,
          branch: branches.get(projectId) ?? null,
          activity: activityOf(entry),
          ...(entry.workStatus === undefined ? {} : { workStatus: entry.workStatus }),
          lastActiveAt: entry.lastUsedAt,
          // An unknown tool is receive-only, not a peer: a session whose vendor
          // this bridge cannot name certainly does not declare an mcp profile.
          canReply: entry.tool !== undefined && agentSpec(entry.tool)?.mcp !== undefined,
        });
      }
    }

    const sorted = sortDirectory(rows, branches.get(caller.projectId) ?? null);
    return {
      ok: true,
      rows: sorted.slice(0, MAX_DIRECTORY_ROWS),
      truncated: Math.max(0, sorted.length - MAX_DIRECTORY_ROWS),
    };
  }
}
