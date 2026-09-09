// web/src/integrations/github-poll-loop.ts
//
// The production wiring around `pollDueRepos`, which owns the walk itself.
//
// Credentials and the exit contract are the whole job here: which token a
// repository's pages are read under, and which reports need a person. Every
// decision about what an issue means belongs to `github-inbound.ts`, and every
// decision about where a walk stops belongs to `github-poll.ts`; nothing in this
// file reopens either.

import type { DB } from "../db/index.js";
import {
  createGithubAppClient,
  type FetchLike,
  type GithubAppClient,
  type GithubAppConfig,
  type GithubInstallationToken,
} from "./github-app.js";
import { GITHUB_PROVIDER } from "./github-events.js";
import { createGithubIssueWriter, type GithubIssueLister } from "./github-issues.js";
import { createPointsBudget } from "./github-push-policy.js";
import type { GithubPollDeps, GithubPollReport } from "./github-poll.js";

/** Re-mint an installation token this far before it expires. An invocation is
 *  far shorter than the hour GitHub grants, so this only matters if the poll's
 *  wall clock is ever raised. */
const INSTALLATION_TOKEN_MARGIN_MS = 60_000;

/**
 * Does this report need a person?
 *
 * The exit-code contract, kept beside the report it reads so the script and its
 * test agree on one predicate. Two terminal conditions, and nothing else:
 *
 * - a repository whose walk ended `refused` or `unroutable` — the installation
 *   lost access, or the row's `repoKey` names nothing this service can address.
 *   Neither self-heals, and neither produces any other signal: the repository
 *   simply stops importing, which looks exactly like a quiet repository.
 * - `invalid` — an issue our own validation refused to turn into a task. The
 *   walk advances its cursor past it like any other item, so this is a
 *   ONE-SHOT signal and the issue is skipped for good: a run whose exit code
 *   nobody reads is an issue that silently never becomes a task. That is
 *   precisely why it is an exit code rather than a log line.
 *
 * Everything else is excluded on purpose. A rate refusal, a 5xx, a bound cutting
 * the run short and a repository another runner held are all conditions the next
 * tick resumes from, and a job that pages for them gets muted — at which point
 * the two conditions above stop being read too.
 */
export function githubPollNeedsAttention(report: GithubPollReport): boolean {
  return (
    report.invalid > 0 ||
    report.repos.some(
      (repo) => repo.stoppedBecause === "refused" || repo.stoppedBecause === "unroutable"
    )
  );
}

/** The production dependencies: one installation token per integration, and the
 *  points budget rather than the write budget — this path creates no content and
 *  must not spend what the outbox needs. */
export function githubPollDeps(
  db: DB,
  opts: { config: GithubAppConfig; fetch?: FetchLike }
): GithubPollDeps {
  const client = createGithubAppClient({ config: opts.config, fetch: opts.fetch });
  return {
    resolveLister: (integrationId) => installationLister(db, client, integrationId, opts.fetch),
    budget: createPointsBudget(),
    now: () => new Date(),
  };
}

/**
 * One integration's reader, signed with an installation token.
 *
 * An **installation** token, never the App JWT, for the same reason the writer
 * insists on one: the App JWT answers for every installation across every
 * tenant, and a read scoped to it would happily return a repository this account
 * never connected.
 *
 * `revokedAt` is not re-checked here — the claim in `github-poll.ts` resolves the
 * installation under its lock and refuses a revoked one there, which is the only
 * place the answer is still true by the time it is used.
 */
async function installationLister(
  db: DB,
  client: GithubAppClient,
  integrationId: string,
  fetchImpl?: FetchLike
): Promise<GithubIssueLister> {
  const row = await db.integration.findUnique({
    where: { id: integrationId },
    select: { provider: true, installationId: true },
  });
  if (!row) throw new Error(`integration ${integrationId} no longer exists`);
  if (row.provider !== GITHUB_PROVIDER) {
    throw new Error(`integration ${integrationId} is not a GitHub installation`);
  }
  const installationId = row.installationId;
  if (!installationId) {
    throw new Error(`integration ${integrationId} carries no installation id`);
  }

  let minted: GithubInstallationToken | null = null;
  return createGithubIssueWriter({
    token: async () => {
      if (
        minted === null ||
        minted.expiresAt.getTime() - Date.now() <= INSTALLATION_TOKEN_MARGIN_MS
      ) {
        minted = await client.createInstallationToken(installationId);
      }
      return minted.token;
    },
    fetch: fetchImpl,
  });
}
