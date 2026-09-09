import { randomBytes, timingSafeEqual } from "node:crypto";
import type { DB } from "../db/index.js";
import {
  markMissingReposRemoved,
  upsertIntegration,
  upsertIntegrationRepo,
  type RepoVisibility,
} from "../models/integration.js";
import { GITHUB_PROVIDER, githubRepoKey } from "./github-events.js";
import { GithubApiError, type GithubAppClient } from "./github-app.js";

/**
 * Attaching a GitHub installation to an Antgrid account.
 *
 * The inbound half of this integration is anonymous — a delivery arrives with no
 * account on it and is routed purely by `[provider, installationId]`. This is
 * the one place that mapping is *written*, which makes it the one place a
 * cross-tenant mistake is possible: bind the wrong installation here and every
 * future delivery for it is routed to the wrong account, by design.
 */

/** Long enough that a user can read GitHub's install screen without rushing,
 *  short enough that an abandoned flow does not leave a usable state behind. */
export const INSTALL_STATE_TTL_SECONDS = 15 * 60;

const NONCE_BYTES = 32;

export type InstallStart = {
  /** Where to send the browser. */
  url: string;
  /** The value for the state cookie, which must be httpOnly and `SameSite=Lax`
   *  — GitHub returns the user by a cross-site top-level navigation, and
   *  `Strict` drops the cookie on exactly that request. */
  cookie: string;
  maxAgeSeconds: number;
};

/**
 * Begin an install.
 *
 * `state` is CSRF and nothing more: it proves the callback belongs to the
 * browser that started the flow. It does NOT prove the installation named in
 * that callback belongs to this user — only `completeGithubInstall` establishes
 * that, and no amount of state handling substitutes for it.
 *
 * The user id travels in the cookie beside the nonce because a browser can
 * change hands between the two halves of the flow: sign out, sign in as someone
 * else, come back to a callback still holding the first user's state. Comparing
 * it against the live session closes that without a database row.
 */
export function startGithubInstall(args: { userId: string; appSlug: string }): InstallStart {
  const nonce = randomBytes(NONCE_BYTES).toString("base64url");
  const url = new URL(
    `https://github.com/apps/${encodeURIComponent(args.appSlug)}/installations/new`
  );
  url.searchParams.set("state", nonce);
  return {
    url: url.toString(),
    // Nonce first: it is base64url and so cannot contain the separator, whereas
    // nothing here gets to promise that about a user id. Splitting on the first
    // separator is then unambiguous whatever the id looks like.
    cookie: `${nonce}.${args.userId}`,
    maxAgeSeconds: INSTALL_STATE_TTL_SECONDS,
  };
}

/**
 * Whether a callback's `state` came from this browser, for this user.
 *
 * The nonce is kept in the cookie as itself rather than as an HMAC, which is a
 * deliberate departure from `pending_sign_in`. That row is HMAC-stored because
 * it lives in our database, where a backup or a support query can read it, and
 * because possessing it grants a sign-in. This value lives only in the user's
 * own browser and grants nothing on its own.
 */
export function verifyInstallState(args: {
  cookie: string | undefined;
  state: string | undefined;
  userId: string;
}): boolean {
  if (!args.cookie || !args.state) return false;
  const separator = args.cookie.indexOf(".");
  if (separator <= 0) return false;
  const cookieNonce = args.cookie.slice(0, separator);
  const cookieUser = args.cookie.slice(separator + 1);
  if (cookieUser !== args.userId) return false;
  return equals(cookieNonce, args.state);
}

function equals(a: string, b: string): boolean {
  const left = Buffer.from(a);
  const right = Buffer.from(b);
  // `timingSafeEqual` throws on a length mismatch rather than returning false,
  // and the lengths are not secret.
  if (left.length !== right.length || left.length === 0) return false;
  return timingSafeEqual(left, right);
}

/** One installation the authenticated GitHub user administers. */
export type InstallationIdentity = {
  installationId: string;
  /** The org or user the App was installed on — `Integration.externalAccountId`. */
  externalAccountId: string;
  displayName: string;
};

export type DiscoveredRepo = {
  externalRepoId: string;
  fullName: string;
  visibility: RepoVisibility;
};

/**
 * What this flow needs from GitHub, and nothing else.
 *
 * Narrow on purpose: the App private key signs JWTs for every installation
 * across every tenant, so the fewer places that can reach it the better.
 * `listInstallationRepos` takes an installation id rather than a token so that
 * minting the installation token — and therefore using the key — stays inside
 * the client.
 */
export interface GithubInstallDirectory {
  /** Null when GitHub rejects the code. It reports that inside a 200 body, so a
   *  client that only checks the status hands back a token that is not one. */
  exchangeUserCode(code: string): Promise<string | null>;
  listUserInstallations(userToken: string): Promise<InstallationIdentity[]>;
  listInstallationRepos(installationId: string): Promise<DiscoveredRepo[]>;
}

/**
 * The REST client, narrowed to the three questions this flow asks.
 *
 * Two shape changes happen here rather than in the client. A refused code
 * exchange becomes `null` instead of an exception, because "GitHub says this
 * code is no good" is an ordinary outcome of a link the user opened twice,
 * whereas GitHub being down is not — collapsing them would tell a user to try
 * again when trying again cannot work, or the reverse. And minting the
 * installation token is folded into the repository read, so the token never
 * exists outside the client.
 */
export function installDirectory(client: GithubAppClient): GithubInstallDirectory {
  return {
    async exchangeUserCode(code) {
      try {
        return await client.exchangeUserCode(code);
      } catch (err) {
        if (err instanceof GithubApiError && err.failure === "refused") return null;
        throw err;
      }
    },
    async listUserInstallations(userToken) {
      const rows = await client.listUserInstallations(userToken);
      // An installation whose account GitHub did not report cannot be recorded:
      // `externalAccountId` is half the key the integration upserts on. Dropping
      // it makes the flow refuse the id rather than store a row keyed on a
      // placeholder that a later payload would never match.
      return rows.flatMap((row) =>
        row.accountId
          ? [
              {
                installationId: row.installationId,
                externalAccountId: row.accountId,
                displayName: row.accountLogin ?? row.accountId,
              },
            ]
          : []
      );
    },
    async listInstallationRepos(installationId) {
      const { token } = await client.createInstallationToken(installationId);
      const repos = await client.listInstallationRepos(token);
      return repos.map((repo) => ({
        externalRepoId: repo.externalRepoId,
        fullName: repo.fullName,
        visibility: repo.visibility,
      }));
    },
  };
}

export type CompleteInstallArgs = {
  /** Resolved from the caller's active membership, never from the request. */
  accountId: string;
  /** The signed-in Antgrid user, from the session. */
  userId: string;
  /** Straight off the query string, and therefore not to be believed. */
  installationId: string;
  code: string;
};

export type CompleteInstallResult =
  | { kind: "ok"; integrationId: string; reposRecorded: number; reposSkipped: number }
  /** The `code` did not exchange. Expired, replayed, or never ours. */
  | { kind: "code_rejected" }
  /** The signed-in GitHub user does not administer the installation the
   *  callback named. The whole point of the flow. */
  | { kind: "not_your_installation" }
  /** Another Antgrid account already holds it, and taking it over would
   *  redirect their deliveries to us. */
  | { kind: "installation_taken" }
  | { kind: "provider_error"; detail: string };

/**
 * Bind an installation to an account, then record what it can see.
 *
 * The `installation_id` in the callback is an attacker-supplied query parameter
 * on an otherwise trustworthy-looking authenticated request. Two facts that do
 * NOT establish ownership, both tempting:
 *
 * - `GET /app/installations/{id}` signed with the App key succeeds for every
 *   installation of the App, the victim's included. It answers whether the
 *   installation exists.
 * - The session proves who the Antgrid user is. It says nothing about who the
 *   GitHub user is; the two identities are unrelated until something ties them.
 *
 * So the question is put to GitHub as the GitHub user: exchange the callback's
 * `code` for a user-to-server token and accept the id only if it appears in
 * `GET /user/installations`, which returns exactly the installations that user
 * administers. This requires the App to be registered with "Request user
 * authorization (OAuth) during installation" — without it no `code` arrives and
 * this flow has nothing to check.
 *
 * Deliberately not one transaction. `upsertIntegrationRepo` reports a repo-key
 * conflict from a unique violation, and Postgres aborts the surrounding
 * transaction on that error whatever the caller catches — so a batch inside a
 * transaction cannot record the repositories that were fine. Partial progress is
 * safe here because the flow is re-runnable from the settings page and every
 * step is an upsert.
 */
export async function completeGithubInstall(
  db: DB,
  directory: GithubInstallDirectory,
  args: CompleteInstallArgs
): Promise<CompleteInstallResult> {
  let userToken: string | null;
  try {
    userToken = await directory.exchangeUserCode(args.code);
  } catch (err) {
    return { kind: "provider_error", detail: describe(err) };
  }
  if (!userToken) return { kind: "code_rejected" };

  let installations: InstallationIdentity[];
  try {
    installations = await directory.listUserInstallations(userToken);
  } catch (err) {
    return { kind: "provider_error", detail: describe(err) };
  }

  const owned = installations.find((i) => i.installationId === args.installationId);
  if (!owned) return { kind: "not_your_installation" };

  const integration = await upsertIntegration(db, {
    accountId: args.accountId,
    provider: GITHUB_PROVIDER,
    externalAccountId: owned.externalAccountId,
    installationId: owned.installationId,
    displayName: owned.displayName,
    installedBy: args.userId,
  });
  if (integration.kind === "installation_taken") return { kind: "installation_taken" };
  if (integration.kind !== "ok") return { kind: "provider_error", detail: integration.kind };

  let repos: DiscoveredRepo[];
  try {
    repos = await directory.listInstallationRepos(owned.installationId);
  } catch (err) {
    // The integration is bound and inbound routing already works; only the
    // catalog is missing, and re-running the flow fills it.
    return { kind: "provider_error", detail: describe(err) };
  }

  let recorded = 0;
  let skipped = 0;
  const present: string[] = [];
  for (const repo of repos) {
    present.push(repo.externalRepoId);
    const repoKey = githubRepoKey(repo.fullName);
    // A name our repo-key form cannot fold is skipped rather than stored under a
    // made-up key: `repoKey` is the join to a checkout on a developer's machine,
    // and a second normalization would give two strings for one repository and
    // match nothing.
    if (!repoKey) {
      skipped += 1;
      continue;
    }
    const result = await upsertIntegrationRepo(db, {
      accountId: args.accountId,
      integrationId: integration.integration.id,
      repoKey,
      externalRepoId: repo.externalRepoId,
      visibility: repo.visibility,
      // Discovery is not consent. The row exists so the settings page can offer
      // the repository; importing starts when the user says so, and every
      // consent column is applied on create only so a later re-discovery cannot
      // overwrite the answer.
      syncEnabled: false,
    });
    if (result.kind === "ok") recorded += 1;
    else skipped += 1;
  }

  await markMissingReposRemoved(db, {
    accountId: args.accountId,
    integrationId: integration.integration.id,
    present,
  });

  return {
    kind: "ok",
    integrationId: integration.integration.id,
    reposRecorded: recorded,
    reposSkipped: skipped,
  };
}

/** Provider errors carry response text; nothing here may carry a token. The
 *  client is responsible for keeping secrets out of what it throws, and this
 *  bounds the damage if one ever slips. */
function describe(err: unknown): string {
  const message = err instanceof Error ? err.message : String(err);
  return message.length > 200 ? `${message.slice(0, 200)}…` : message;
}
