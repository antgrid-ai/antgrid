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
import { LOCAL_ROW_FLOOR, REMOTE_CARRIER_SILENCE_MS } from "./constants";
import type { ReachMachine } from "./remote-directory";

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
  /** OMITTED for a row this machine built itself — it needs no label for
   *  itself. Present on a merged remote row, stamped by `RemoteDirectoryCache`
   *  (`remote-directory.ts`) from the machine entry the row arrived under. */
  machineLabel?: string;
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

/** One session on a peer's capability card, before the asking machine stamps
 *  its own `machineId`/`machineLabel` onto it. `canReply` is computed HERE,
 *  by the machine that owns the session: re-deriving it against the asking
 *  machine's own registry would compile for any tool string and go wrong the
 *  moment the two bridges run different versions. */
export interface MachineDirectoryRow {
  repoKey: string;
  projectId: string;
  projectLabel?: string;
  sessionId: string;
  title: string;
  branch: string | null;
  activity: DirectoryActivity;
  workStatus?: WorkStatus;
  lastActiveAt: number;
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

/** The half of a `RemoteDirectoryCache` (`remote-directory.ts`) a directory
 *  reads. Narrow like {@link DirectoryRepoKeys}: this file never replaces or
 *  clears the mirror, it only reads a view of it at request time. */
export interface DirectoryRemote {
  view(
    repoKey: string,
    selfMachineId: string | null,
    now: number,
  ): {
    rows: SessionDirectoryRow[];
    truncated: number;
    machines: ReachMachine[];
    staleMachines: number;
    notConnected: number;
    lastPushAt: number | null;
  };
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
  /** The asking-side mirror of peer machines' capability cards. Absent for a
   *  bare bus in a unit test or a core with no host above it — {@link
   *  SessionDirectory.list} then reports `no-carrier` rather than treating a
   *  wire that was never wired as an empty network. */
  remoteDirectory?: DirectoryRemote;
  /** Whether THIS machine's remote-access switch is on — checked first in the
   *  private `remoteHalfFor`, see its own comment for the ordering. Absent
   *  behaves as on: keeping the mirror empty while the switch is off is the
   *  ingest gate's job, not this dependency's default. */
  remoteAccessEnabled?(): boolean;
  /** Injectable clock, so a remote-half test can control TTL and silence
   *  expiry without a real timer. */
  now?(): number;
}

function activityOf(entry: SessionEntry): DirectoryActivity {
  if (!entry.running) return "stopped";
  // `attention` outranks `working` nowhere in this reduction on purpose: both
  // mean a live turn, and which of the two it is belongs in `workStatus`, which
  // travels beside this. Only the three-way rank is sorted on.
  return entry.workStatus === "working" || entry.workStatus === "attention" ? "running" : "idle";
}

/** The row-shape one project contributes, before either surface stamps
 *  identity onto it. One loop, two stamps, so `canReply`, `activity` and the
 *  archived/deleting exclusion can never drift between the two surfaces. */
export interface DirectoryRowCore {
  projectId: string;
  projectLabel?: string;
  sessionId: string;
  title: string;
  activity: DirectoryActivity;
  workStatus?: WorkStatus;
  lastActiveAt: number;
  canReply: boolean;
}

/** Every addressable session in one project, unstamped. `excludeSessionId`
 *  drops the caller's own row where there is a caller; {@link
 *  machineDirectoryRows} calls with none, since a capability card has no
 *  caller to exclude. */
export function directoryRowsFor(
  sessionIndex: DirectorySessions,
  projectId: string,
  excludeSessionId?: string,
): DirectoryRowCore[] {
  const rows: DirectoryRowCore[] = [];
  for (const { entry, projectLabel } of sessionIndex.sessionsIn(projectId)) {
    if (entry.id === excludeSessionId) continue;
    if (entry.archived || entry.deleting) continue;
    rows.push({
      projectId,
      ...(projectLabel === undefined ? {} : { projectLabel }),
      sessionId: entry.id,
      title: entry.name,
      activity: activityOf(entry),
      ...(entry.workStatus === undefined ? {} : { workStatus: entry.workStatus }),
      lastActiveAt: entry.lastUsedAt,
      // An unknown tool is receive-only, not a peer: a session whose vendor
      // this bridge cannot name certainly does not declare an mcp profile.
      canReply: entry.tool !== undefined && agentSpec(entry.tool)?.mcp !== undefined,
    });
  }
  return rows;
}

/** The session half of a widened capability card: one row per addressable
 *  session across the given projects, keyed to the repo key and branch the
 *  card already paid to read. A project with no repo key contributes no
 *  row — a session is addressed by repo key, so one it cannot carry is not
 *  offerable (§5.1 fails closed here too). */
export function machineDirectoryRows(
  sessionIndex: DirectorySessions,
  projects: Array<{ projectId: string; repoKey: string | null; branch: string | null }>,
  max: number,
): { rows: MachineDirectoryRow[]; truncated: number } {
  const rows: MachineDirectoryRow[] = [];
  for (const { projectId, repoKey, branch } of projects) {
    if (repoKey === null) continue;
    for (const core of directoryRowsFor(sessionIndex, projectId)) {
      rows.push({ repoKey, branch, ...core });
    }
  }
  // Ranked before it is cut, because the cut is what the asking machine can
  // never undo: an unranked slice can spend all 40 rows on idle sessions and
  // drop the running one, and no sort on the other side can recover a row that
  // did not travel. Branch is deliberately not a key here — the answering
  // machine does not know which branch the asking agent is on.
  rows.sort(
    (a, b) =>
      ACTIVITY_RANK[a.activity] - ACTIVITY_RANK[b.activity]
      || b.lastActiveAt - a.lastActiveAt
      || a.sessionId.localeCompare(b.sessionId),
  );
  return { rows: rows.slice(0, max), truncated: Math.max(0, rows.length - max) };
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
 * Caps a sorted directory while guaranteeing this machine's own rows a floor
 * of slots, however far a peer legitimately outranks them. Identity-based (a
 * `Set` over row objects, not a rebuilt array), so the local rows that survive
 * stay in `sorted`'s order rather than being re-sorted among themselves.
 *
 * The floor is carved OUT OF the cap, never added to it: a caller tuning
 * either one independently must not be able to ask for a bound and receive a
 * longer list, since the count it reports as truncated is computed from what
 * comes back.
 */
export function withLocalFloor(
  sorted: SessionDirectoryRow[],
  selfMachineId: string | null,
  cap: number,
  floor: number,
): SessionDirectoryRow[] {
  const local = sorted.filter((r) => r.machineId === selfMachineId);
  const keep = new Set<SessionDirectoryRow>(local.slice(0, Math.min(floor, cap, local.length)));
  for (const r of sorted) {
    if (keep.size >= cap) break;
    keep.add(r);
  }
  return sorted.filter((r) => keep.has(r));
}

/** Why the remote half is what it is, reported beside the rows in every state
 *  — including a fully successful one, because a signal that appears only on
 *  failure teaches an agent to read its absence as completeness. `"machine"`
 *  reasons mean no network read was attempted at all; `"network"` means one
 *  was, and names what it found. */
export type DirectoryReach =
  | { scope: "machine"; why: "remote-access-off" | "no-machine-id" | "no-carrier" }
  | { scope: "network"; asOfMs: number; machines: ReachMachine[]; staleMachines: number; notConnected: number };

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
       *  answer a directory can give. Sums this machine's own merge overflow
       *  with whatever the far side's own card cap already dropped. */
      truncated: number;
      reach: DirectoryReach;
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
    const machineId = this.deps.machineId();
    const now = this.deps.now?.() ?? Date.now();

    // Rows first, branches second. Enumerating is a memory read; a branch is a
    // git spawn, so the set that gets probed has to be the set that can appear
    // in the answer. A project sharing the repo key but holding no addressable
    // session contributes no row and is not worth a process — and on a machine
    // where one repository is open under many project ids, that is most of them.
    const rows: SessionDirectoryRow[] = [];
    for (const projectId of projects) {
      for (const core of directoryRowsFor(this.deps.sessionIndex, projectId, caller.sessionId)) {
        rows.push({ machineId, branch: null, ...core });
      }
    }

    // The caller's own project joins the probe set even when it contributed no
    // row: its branch is the one every other row is RANKED against, so leaving
    // it out would silently retire the sort's first key.
    const readBranch = this.deps.readBranch ?? (async (path: string) => (await readRepoCard(path)).branch);
    const branches = new Map<string, string | null>();
    const probe = [...new Set([caller.projectId, ...rows.map((r) => r.projectId)])];
    await inProbePool(probe, async (projectId) => {
      const path = this.deps.projectPath(projectId);
      branches.set(projectId, path ? await readBranch(path) : null);
    });
    for (const row of rows) row.branch = branches.get(row.projectId) ?? null;

    // AFTER the branch-fill loop, not before: that loop overwrites every LOCAL
    // row's branch unconditionally, and a remote row can legitimately share a
    // projectId with a local one — the id is a hash of the checkout path, and
    // two machines can have the same one checked out. Merging earlier would
    // clobber a peer's own reported branch with this machine's, including to
    // null for a project this machine has never opened.
    const remoteHalf = this.remoteHalfFor(key, machineId, now);
    const merged = [...rows, ...remoteHalf.rows];
    const sorted = sortDirectory(merged, branches.get(caller.projectId) ?? null);
    const bounded = withLocalFloor(sorted, machineId, MAX_DIRECTORY_ROWS, LOCAL_ROW_FLOOR);
    return {
      ok: true,
      rows: bounded,
      truncated: merged.length - bounded.length + remoteHalf.truncated,
      reach: remoteHalf.reach,
    };
  }

  /**
   * The remote half of one directory read: rows this machine's mirror can
   * currently offer for `repoKey`, plus the reach report that says why there
   * are or are not any. The four checks run in exactly this order, and the
   * order is the point — see each arm.
   */
  private remoteHalfFor(
    repoKey: string,
    machineId: string | null,
    now: number,
  ): { rows: SessionDirectoryRow[]; truncated: number; reach: DirectoryReach } {
    // 1. The switch, first. If this machine's own remote access is off, the
    //    mirror is kept empty by the ingest gate (`clear()` on the refusal
    //    path) — but checking carrier presence FIRST would report "no
    //    carrier" in the one state that is actually "this machine refuses to
    //    ingest", which reads to a user with a perfectly good desktop app as
    //    their desktop app being missing.
    if (this.deps.remoteAccessEnabled?.() === false) {
      return { rows: [], truncated: 0, reach: { scope: "machine", why: "remote-access-off" } };
    }
    // 2. No relay identity: a row this machine cannot be reached at is a row
    //    that renders as sendable and then refuses at the first reply.
    if (machineId === null) {
      return { rows: [], truncated: 0, reach: { scope: "machine", why: "no-machine-id" } };
    }
    // 3. No carrier: nothing wired the mirror in this process, or nobody has
    //    pushed to it recently enough to trust. `lastPushAt` is a fact the app
    //    proves by pushing, never a capability flag Zod could strip silently.
    const view = this.deps.remoteDirectory?.view(repoKey, machineId, now);
    if (view === undefined || view.lastPushAt === null || now - view.lastPushAt > REMOTE_CARRIER_SILENCE_MS) {
      return { rows: [], truncated: 0, reach: { scope: "machine", why: "no-carrier" } };
    }
    // 4. Served: whatever the mirror currently holds for this repo.
    return {
      rows: view.rows,
      truncated: view.truncated,
      reach: {
        scope: "network",
        asOfMs: now,
        machines: view.machines,
        staleMachines: view.staleMachines,
        notConnected: view.notConnected,
      },
    };
  }
}
