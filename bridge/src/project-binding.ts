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

/**
 * Fire-and-forget reporter for the durable project↔repository binding.
 *
 * A binding is a fact, not a heartbeat: the route takes an advisory lock per
 * (device, project) pair, so re-POSTing it on every warm-up is pure load. The
 * memo below is therefore keyed on everything web stores, and only re-sends when
 * one of those values actually moves.
 *
 * Deliberately in memory only. A process restart re-reports each project once,
 * which is the whole recovery path for a POST that reported success without
 * durably landing — a persisted memo would make that state permanent.
 */
export class ProjectBindingReporter {
  private readonly reported = new Map<string, string>();

  constructor(private readonly opts: ProjectBindingReporterOpts) {}

  /** Never throws and never blocks: a project must open with web down, the
   *  machine offline, or the account unauthenticated. */
  report(binding: ProjectBinding): void {
    if (!binding.repoKey) return;
    const creds = this.opts.credentials();
    if (!creds) return;

    const memo = `${binding.repoKey}\0${binding.localPath}`;
    if (this.reported.get(binding.localProjectId) === memo) return;
    // Recorded before the POST, so concurrent opens of one project cannot both
    // send it.
    this.reported.set(binding.localProjectId, memo);

    void sendProjectBinding({
      licenseApiUrl: creds.licenseApiUrl,
      getToken: creds.getToken,
      deviceUuid: creds.deviceUuid,
      localProjectId: binding.localProjectId,
      localPath: binding.localPath,
      repoKey: binding.repoKey,
      ...(this.opts.fetchFn ? { fetchFn: this.opts.fetchFn } : {}),
    }).then((outcome) => {
      if (outcome === "ok") return;
      if (outcome === "conflict") {
        // Keeps the memo: another account owns this pair, and every retry would
        // land on the same 409. Only that account releasing it can clear this.
        log.error(
          "project binding rejected: %s is already bound to another account (device %s, project %s)",
          binding.repoKey,
          creds.deviceUuid,
          binding.localProjectId,
        );
        return;
      }
      // Transient by assumption, so let the next open of this project retry —
      // but only if nothing newer has claimed the memo since.
      if (this.reported.get(binding.localProjectId) === memo) {
        this.reported.delete(binding.localProjectId);
      }
      log.warn("project binding POST failed (non-2xx or network error)", {
        localProjectId: binding.localProjectId,
      });
    });
  }
}
