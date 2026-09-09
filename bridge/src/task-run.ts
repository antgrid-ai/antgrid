import { logger } from "./logger";
import type { SessionEntry, WorkStatus } from "./protocol";
const log = logger.child({ component: "task-run" });

/** Everything web stores about one session's run, minus the identity the route
 *  takes from the caller's own token.
 *
 *  `resultSummary` is deliberately absent from this type rather than left unset
 *  at the call site: the route accepts it, but the bridge holds nothing it is
 *  allowed to put there — agent output, diffs and transcripts never leave the
 *  machine as task text (see the Trust posture in
 *  docs/tasks-and-integrations-plan.md). Absent from the shape, it cannot be
 *  filled in by a later edit that only reads the route contract. */
export interface TaskRunBody {
  localProjectId: string;
  sessionId: string;
  status: WorkStatus;
  checkoutId?: string;
  tool?: string;
  branch?: string;
  ended?: boolean;
}

export interface SendTaskRunArgs {
  licenseApiUrl: string;
  getToken: () => string;
  deviceUuid: string;
  /** The task's per-account display number — the only address the route takes.
   *  `TaskRef.taskId` is opaque to both ends and addresses nothing. */
  number: number;
  body: TaskRunBody;
  fetchFn?: typeof fetch;
}

/** `conflict` and `denied` are separated from `failed` because neither is worth
 *  retrying: the session already belongs to another task (no retry can move it),
 *  or the machine's credentials were refused (a retry loop only burns the
 *  route). Only `failed` is transient by assumption. */
export type TaskRunOutcome = "ok" | "conflict" | "denied" | "failed";

/**
 * Tell the account where one task-bound session has got to, so a `TaskRun` row
 * exists whether or not a phone is watching.
 *
 * `deviceUuid` is sent even though the route resolves the device from the token:
 * it is compared against that device, not trusted, so it is an assertion about
 * who we think we are rather than a claim the route acts on.
 */
export async function sendTaskRun(args: SendTaskRunArgs): Promise<TaskRunOutcome> {
  const f = args.fetchFn ?? fetch;
  try {
    const res = await f(`${args.licenseApiUrl}/tasks/${args.number}/runs`, {
      method: "POST",
      headers: {
        authorization: `Bearer ${args.getToken()}`,
        "content-type": "application/json",
      },
      body: JSON.stringify({ deviceUuid: args.deviceUuid, ...args.body }),
    });
    if (res.ok) return "ok";
    if (res.status === 409) return "conflict";
    if (res.status === 401 || res.status === 403) return "denied";
    return "failed";
  } catch {
    return "failed";
  }
}

/** Machine credentials for the run-report route, or null while the machine has
 *  no remote config / no OAuth runtime yet. Read per report, never captured. */
export interface TaskRunCredentials {
  licenseApiUrl: string;
  getToken: () => string;
  deviceUuid: string;
}

export interface TaskRunReporterOpts {
  credentials: () => TaskRunCredentials | null;
  fetchFn?: typeof fetch;
}

/** One LIVE, task-bound session as its project's work reduction sees it. */
export interface TaskRunObservation {
  sessionId: string;
  taskNumber: number;
  status: WorkStatus;
  checkoutId?: string;
  tool?: string;
  branch?: string;
}

/** The narrow half of {@link TaskRunReporter} a project core depends on. */
export interface TaskRunObserver {
  observe(localProjectId: string, live: readonly TaskRunObservation[]): void;
}

/**
 * The task-bound, LIVE subset of a session list, in the shape the reporter
 * takes.
 *
 * Liveness comes from the reduction's per-session map, not from the entry's own
 * `running` flag: that map is what the reporter treats as "still going", so the
 * two must agree by construction rather than by two readings of the same
 * question. A session with no `taskRef` has nothing to report against and is
 * dropped here — the account addresses tasks by `number`, and a run with no task
 * has nowhere to land.
 *
 * [defaultTool] is the project's `agent.tool`: a `SessionEntry` carries `tool`
 * only when it OVERRODE that default, so reading the entry alone would report
 * every default-spec session as toolless.
 */
export function taskRunObservations(
  sessions: readonly SessionEntry[],
  statuses: ReadonlyMap<string, WorkStatus>,
  defaultTool: string | undefined,
): TaskRunObservation[] {
  const live: TaskRunObservation[] = [];
  for (const s of sessions) {
    const taskNumber = s.taskRef?.number;
    if (taskNumber === undefined) continue;
    const status = statuses.get(s.id);
    if (status === undefined) continue;
    const tool = s.tool ?? defaultTool;
    live.push({
      sessionId: s.id,
      taskNumber,
      status,
      ...(s.checkoutId ? { checkoutId: s.checkoutId } : {}),
      ...(tool ? { tool } : {}),
      // Only an isolated session has a branch of its own. A main-checkout
      // session works on whatever the user has checked out, which is not this
      // session's branch and flaps with every unrelated `git checkout`.
      ...(s.checkoutBranch ? { branch: s.checkoutBranch } : {}),
    });
  }
  return live;
}

/** What the reporter last sent for one session, and whether it may send again. */
interface TrackedRun {
  number: number;
  body: TaskRunBody;
  /** The last sent body, serialized — the memo {@link TaskRunReporter.observe}
   *  compares against. */
  memo: string;
  /** The route answered 409 for this session: it is bound to a different task
   *  and no report can change that. */
  blocked: boolean;
}

/**
 * Fire-and-forget reporter for per-session task-run status.
 *
 * The row is keyed `(device, session)` and every report is an upsert, so status
 * that flaps — and it does, several times a turn — would otherwise be pure load.
 * The memo below is therefore keyed on the whole payload web stores, and only
 * re-sends when one of those values actually moves.
 *
 * Deliberately in memory only. A process restart re-reports each live session
 * once, which is the recovery path for a POST that reported success without
 * durably landing; a persisted memo would make that state permanent.
 *
 * A session that dies with the process — or with its project core, which takes
 * its sessions down without a last session list — never gets its `ended: true`,
 * and that is accepted. The only way to recover it would be to treat a stopped
 * task-bound session found at startup as ended, but a session created for a task
 * and not yet started looks exactly the same, so the recovery would close runs
 * that never opened. A stale `working` row is a worse-looking but honest state;
 * a fabricated end is not.
 */
export class TaskRunReporter implements TaskRunObserver {
  /** localProjectId → sessionId → what we last sent for it. */
  private readonly tracked = new Map<string, Map<string, TrackedRun>>();

  constructor(private readonly opts: TaskRunReporterOpts) {}

  /**
   * Reconcile one project's live task-bound sessions against what has been
   * reported for it. Never throws and never blocks: an agent session must run
   * with web down, the machine offline, or the account unauthenticated.
   *
   * [live] is the WHOLE live set for that project, because a session's end is
   * its absence from it — a stopped, archived or deleted session all leave the
   * same way, and none of them sends a last frame of its own.
   */
  observe(localProjectId: string, live: readonly TaskRunObservation[]): void {
    const tracked = this.tracked.get(localProjectId);
    // A project that has never had a task-bound session is the common case, and
    // it must not cost a credentials read on every session list.
    if (live.length === 0 && (tracked?.size ?? 0) === 0) return;
    const creds = this.opts.credentials();
    if (!creds) return;

    const seen = new Set<string>();
    for (const s of live) {
      seen.add(s.sessionId);
      const prev = tracked?.get(s.sessionId);
      if (prev?.blocked) continue;
      const body: TaskRunBody = {
        localProjectId,
        sessionId: s.sessionId,
        status: s.status,
        ...(s.checkoutId ? { checkoutId: s.checkoutId } : {}),
        ...(s.tool ? { tool: s.tool } : {}),
        ...(s.branch ? { branch: s.branch } : {}),
      };
      const memo = JSON.stringify(body);
      if (prev?.memo === memo) continue;
      // Recorded before the POST, so a second list arriving mid-flight cannot
      // send the same values again.
      this.forProject(localProjectId).set(s.sessionId, {
        number: s.taskNumber,
        body,
        memo,
        blocked: false,
      });
      this.post(creds, localProjectId, s.sessionId, s.taskNumber, body);
    }

    if (!tracked) return;
    for (const [sessionId, run] of tracked) {
      if (seen.has(sessionId)) continue;
      // Dropped before the POST rather than after: the end is sent once, and a
      // session that comes back later is a fresh report, not a repeat of this
      // one. `endedAt` is write-once server-side, so the second life shows the
      // first end — which is the first one that happened.
      tracked.delete(sessionId);
      if (run.blocked) continue;
      this.post(creds, localProjectId, sessionId, run.number, { ...run.body, ended: true });
    }
  }

  private forProject(localProjectId: string): Map<string, TrackedRun> {
    const existing = this.tracked.get(localProjectId);
    if (existing) return existing;
    const created = new Map<string, TrackedRun>();
    this.tracked.set(localProjectId, created);
    return created;
  }

  private post(
    creds: TaskRunCredentials,
    localProjectId: string,
    sessionId: string,
    number: number,
    body: TaskRunBody,
  ): void {
    void sendTaskRun({
      licenseApiUrl: creds.licenseApiUrl,
      getToken: creds.getToken,
      deviceUuid: creds.deviceUuid,
      number,
      body,
      ...(this.opts.fetchFn ? { fetchFn: this.opts.fetchFn } : {}),
    }).then((outcome) => {
      if (outcome === "ok") return;
      if (outcome === "conflict") {
        const run = this.tracked.get(localProjectId)?.get(sessionId);
        if (run) run.blocked = true;
        log.error(
          "task run rejected: session %s is already bound to another task (project %s, task %d)",
          sessionId,
          localProjectId,
          number,
        );
        return;
      }
      // The memo is KEPT on a failure, unlike the project-binding reporter's:
      // its retry trigger is a project open, ours is a session list that a busy
      // agent re-emits every 750ms. Re-arming here would turn "web is down" into
      // a POST per session per second; the next real status move re-sends
      // anyway, and until then the row is one transition stale.
      log.warn("task run POST %s (project %s, session %s)", outcome, localProjectId, sessionId);
    });
  }
}
