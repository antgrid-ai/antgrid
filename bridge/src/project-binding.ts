import { logger } from "./logger";
const log = logger.child({ component: "project-binding" });

export interface SendProjectBindingArgs {
  licenseApiUrl: string;
  getToken: () => string;
  deviceUuid: string;
  localProjectId: string;
  localPath: string;
  repoKey: string;
  fetchFn?: typeof fetch;
}

/** `conflict` is separated from `failed` because it is the one outcome no retry
 *  can resolve: the pair already belongs to another account. */
export type ProjectBindingOutcome = "ok" | "conflict" | "failed";

/**
 * Tell the account which repository this machine's project folder holds, so a
 * task created against the repository can find the checkouts that carry it.
 *
 * No `displayName`: web falls back to the repoKey's last segment, which is the
 * same string on every machine — sending this machine's folder name would label
 * the shared repository after one directory.
 */
export async function sendProjectBinding(args: SendProjectBindingArgs): Promise<ProjectBindingOutcome> {
  const f = args.fetchFn ?? fetch;
  try {
    const res = await f(`${args.licenseApiUrl}/account/projects/bindings`, {
      method: "POST",
      headers: {
        authorization: `Bearer ${args.getToken()}`,
        "content-type": "application/json",
      },
      body: JSON.stringify({
        deviceUuid: args.deviceUuid,
        localProjectId: args.localProjectId,
        localPath: args.localPath,
        repoKey: args.repoKey,
      }),
    });
    if (res.ok) return "ok";
    return res.status === 409 ? "conflict" : "failed";
  } catch {
    return "failed";
  }
}

/** Machine credentials for the binding route, or null while the machine has no
 *  remote config / no OAuth runtime yet. Read per report, never captured. */
export interface ProjectBindingCredentials {
  licenseApiUrl: string;
  getToken: () => string;
  deviceUuid: string;
}

export interface ProjectBindingReporterOpts {
  credentials: () => ProjectBindingCredentials | null;
  fetchFn?: typeof fetch;
}

export interface ProjectBinding {
  localProjectId: string;
  localPath: string;
  /** Absent for a machine with no device id to synthesize one — see
   *  `repoKeyFor`. Nothing to bind, so nothing is sent. */
  repoKey: string | undefined;
}

/** A conflicting pair's memo does not clear itself — the ONLY thing that can
 *  release it is the other account giving up the repository, which this
 *  machine has no way to observe. So it is retried on a growing schedule
 *  instead of never or on every open()/credentials-change (which would hammer
 *  the route with an advisory lock behind it): 1 minute, doubling, capped at
 *  1 hour. */
const CONFLICT_RETRY_BASE_MS = 60_000;
const CONFLICT_RETRY_MAX_MS = 60 * 60_000;

interface ReportedState {
  memo: string;
  /** How many CONSECUTIVE 409s this exact (repoKey, localPath) pair has drawn;
   *  resets to 0 once it lands or the pair itself changes, since a new pairing
   *  is a fresh case rather than a continuation of the old backoff. */
  conflictStreak: number;
  /** Set only while backing off a 409. `report()` is a no-op for the same memo
   *  until this passes; absent, it means "already landed" or "in flight". */
  retryNotBefore?: number;
}

/**
 * Fire-and-forget reporter for the durable project↔repository binding.
 *
 * A binding is a fact, not a heartbeat: the route takes an advisory lock per
 * (device, project) pair, so re-POSTing it on every warm-up is pure load. The
 * memo below is therefore keyed on everything web stores, and only re-sends when
 * one of those values actually moves (or a conflict's backoff has elapsed).
 *
 * Deliberately in memory only. A process restart re-reports each project once,
 * which is the whole recovery path for a POST that reported success without
 * durably landing — a persisted memo would make that state permanent.
 */
export class ProjectBindingReporter {
  private readonly reported = new Map<string, ReportedState>();

  constructor(private readonly opts: ProjectBindingReporterOpts) {}

  /** Never throws and never blocks: a project must open with web down, the
   *  machine offline, or the account unauthenticated. */
  report(binding: ProjectBinding): void {
    if (!binding.repoKey) return;
    const creds = this.opts.credentials();
    if (!creds) return;

    const memo = `${binding.repoKey}\0${binding.localPath}`;
    const existing = this.reported.get(binding.localProjectId);
    const samePair = existing?.memo === memo;
    if (samePair && (existing!.retryNotBefore === undefined || Date.now() < existing!.retryNotBefore)) return;

    // Recorded before the POST, so concurrent opens of one project cannot both
    // send it — `retryNotBefore` is cleared here (not left over from a prior
    // conflict) so the in-flight state reads the same as "already landed".
    const conflictStreak = samePair ? existing!.conflictStreak : 0;
    this.reported.set(binding.localProjectId, { memo, conflictStreak });

    void sendProjectBinding({
      licenseApiUrl: creds.licenseApiUrl,
      getToken: creds.getToken,
      deviceUuid: creds.deviceUuid,
      localProjectId: binding.localProjectId,
      localPath: binding.localPath,
      repoKey: binding.repoKey,
      ...(this.opts.fetchFn ? { fetchFn: this.opts.fetchFn } : {}),
    }).then((outcome) => {
      if (outcome === "ok") {
        this.reported.set(binding.localProjectId, { memo, conflictStreak: 0 });
        return;
      }
      if (outcome === "conflict") {
        const streak = conflictStreak + 1;
        const backoff = Math.min(CONFLICT_RETRY_BASE_MS * 2 ** (streak - 1), CONFLICT_RETRY_MAX_MS);
        this.reported.set(binding.localProjectId, { memo, conflictStreak: streak, retryNotBefore: Date.now() + backoff });
        log.error(
          "project binding rejected: %s is already bound to another account (device %s, project %s); retrying in %dms",
          binding.repoKey,
          creds.deviceUuid,
          binding.localProjectId,
          backoff,
        );
        return;
      }
      // Transient by assumption, so let the next open of this project retry —
      // but only if nothing newer has claimed the memo since. The streak is
      // kept rather than the entry deleted: a blip on a pair that was already
      // backing off a 409 must not restart that backoff at its base.
      const cur = this.reported.get(binding.localProjectId);
      if (cur && cur.memo === memo) {
        this.reported.set(binding.localProjectId, { memo, conflictStreak, retryNotBefore: 0 });
      }
      log.warn("project binding POST failed (non-2xx or network error)", {
        localProjectId: binding.localProjectId,
      });
    });
  }
}
