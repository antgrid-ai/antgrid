import { createSign } from "node:crypto";
import { z } from "zod";
import type { RepoVisibility } from "../models/integration.js";
import { githubRepoKey } from "./github-events.js";

/**
 * The GitHub App's outbound half: credentials, the App JWT, and the REST calls
 * the install flow makes.
 *
 * **The security property this module exists for is `listUserInstallations`.**
 * The `installation_id` on our install callback is an ordinary query parameter,
 * so it names whatever installation the caller typed — including one belonging
 * to somebody else's org. Neither fact available at that point closes the hole:
 * an App JWT proves the installation exists (it succeeds for every installation
 * of the App), and the session proves who the *Antgrid* user is. Only GitHub can
 * answer "does this installation belong to the person at the keyboard", and only
 * when asked as the GitHub user — hence the code exchange and
 * `GET /user/installations`. Everything else here is bookkeeping around that one
 * question.
 *
 * **Nothing in this module may put a secret into a message, a log, or a thrown
 * value.** The PEM signs App JWTs for every installation across every tenant —
 * it is a cross-tenant master key, categorically unlike the per-account secrets
 * elsewhere in this service — and the client secret, the user-to-server token
 * and the installation token are all in the same category. Errors carry a method,
 * an endpoint and a status and nothing else; response bodies are never echoed,
 * not even a validation message derived from one.
 */

export const API_BASE = "https://api.github.com";
const OAUTH_TOKEN_URL = "https://github.com/login/oauth/access_token";
const API_VERSION = "2022-11-28";
/** GitHub rejects a request with no User-Agent outright. */
const USER_AGENT = "antgrid-web";

/** GitHub explicitly recommends backdating `iat` against clock skew, and rejects
 *  a token whose `iat` is in its future. */
const CLOCK_SKEW_SECONDS = 60;
/** GitHub's hard maximum for an App JWT; a longer `exp` is refused outright, so
 *  this is a limit rather than a tuning knob. */
const APP_JWT_TTL_SECONDS = 600;

export const GITHUB_PER_PAGE = 100;
/**
 * Hard ceiling on paginated reads.
 *
 * Both paginated endpoints are driven by a response the other side controls, so
 * "follow pages until a short one" is an unbounded loop over an attacker-
 * influencable answer. Hitting the ceiling throws rather than returning what was
 * collected: a truncated installation list only ever refuses a legitimate
 * install, but a truncated list returned silently is the shape that fails *open*
 * the next time somebody reuses this helper for an allowlist.
 */
export const GITHUB_MAX_PAGES = 20;

export type GithubAppConfig = {
  appId: string;
  slug: string;
  clientId: string;
  clientSecret: string;
  /** Read in `mintAppJwt` and nowhere else. */
  privateKeyPem: string;
};

/** The subset of `Env` this module needs, structurally — so a caller can pass
 *  `loadEnv()` output or a literal, and the module never imports the loader. */
export type GithubAppEnv = {
  GITHUB_APP_ID?: string | undefined;
  GITHUB_APP_SLUG?: string | undefined;
  GITHUB_APP_CLIENT_ID?: string | undefined;
  GITHUB_APP_CLIENT_SECRET?: string | undefined;
  GITHUB_APP_PRIVATE_KEY?: string | undefined;
};

/**
 * `null` unless the App is fully registered, so "is the App configured" is one
 * check at the top of a route rather than five, and a half-configured
 * environment refuses at the door instead of failing mid-install with an
 * installation already created on GitHub's side.
 */
export function githubAppConfig(env: GithubAppEnv): GithubAppConfig | null {
  const appId = env.GITHUB_APP_ID?.trim();
  const slug = env.GITHUB_APP_SLUG?.trim();
  const clientId = env.GITHUB_APP_CLIENT_ID?.trim();
  const clientSecret = env.GITHUB_APP_CLIENT_SECRET;
  const privateKeyPem = normalizePrivateKeyPem(env.GITHUB_APP_PRIVATE_KEY);
  if (!appId || !slug || !clientId || !clientSecret || !privateKeyPem) return null;
  return redactSecrets({ appId, slug, clientId, clientSecret, privateKeyPem });
}

const REDACTED = "[redacted]";
const INSPECT = Symbol.for("nodejs.util.inspect.custom");

/**
 * The config carries the two values in this service a stray `console.log` would
 * turn into a cross-tenant compromise, and a plain record hands them to the
 * first serializer that meets it — an error reporter, a structured logger, a
 * request-context dump.
 *
 * `toJSON` must be ENUMERABLE. JavaScriptCore — so Bun — consults it only when
 * it is, unlike V8, and a non-enumerable one is ignored in silence: the
 * redaction reads as installed and the PEM goes out anyway.
 *
 * Not a guarantee: an explicit `config.privateKeyPem` still reads the real
 * value, because signing needs it. It closes the accidental path only.
 */
function redactSecrets(config: GithubAppConfig): GithubAppConfig {
  const safe = { ...config, clientSecret: REDACTED, privateKeyPem: REDACTED };
  return Object.defineProperties(config, {
    toJSON: { value: () => safe, enumerable: true },
    [INSPECT]: { value: () => safe, enumerable: true },
  });
}

/**
 * A `.env` file cannot hold a real newline, so the PEM arrives with its line
 * breaks as the two characters `\n` — which `createSign` reads as a corrupt key.
 * Idempotent, because a PEM injected by a secret manager already has real ones —
 * and the trim runs after the replacement so both spellings fold to the exact
 * same string rather than differing by a trailing newline.
 */
export function normalizePrivateKeyPem(raw: string | undefined): string | undefined {
  const value = raw?.replace(/\\r\\n|\\n/g, "\n").trim();
  return value ? value : undefined;
}

/**
 * An App JWT: RS256 over `{iss, iat, exp}`, signed with the PEM.
 *
 * Hand-rolled rather than pulled from a JWT library because this service has no
 * JWT *signer* by design (see `web/CLAUDE.md` on `crypto/`) — the only signing
 * is Better-Auth's, and a dependency whose whole job is 40 lines of `node:crypto`
 * is not worth the supply-chain surface for a cross-tenant master key.
 *
 * `now` is a parameter so the claims are assertable without faking a clock.
 */
export function mintAppJwt(config: GithubAppConfig, now: Date): string {
  const iat = Math.floor(now.getTime() / 1000) - CLOCK_SKEW_SECONDS;
  const signingInput = `${encodeSegment({ alg: "RS256", typ: "JWT" })}.${encodeSegment({
    iat,
    exp: iat + APP_JWT_TTL_SECONDS,
    iss: config.appId,
  })}`;
  const signer = createSign("RSA-SHA256");
  signer.update(signingInput);
  return `${signingInput}.${signer.sign(config.privateKeyPem).toString("base64url")}`;
}

function encodeSegment(value: unknown): string {
  return Buffer.from(JSON.stringify(value), "utf8").toString("base64url");
}

/**
 * What a caller does about a failure, not what caused it.
 *
 * `refused` (401/403/404) is the one the install flow shows the user — "this is
 * not yours, or does not exist" — and is never retried; `retryable` is GitHub
 * being unreachable, rate limiting, or 5xx. Collapsing the two loses the only
 * distinction the callback has to work with, since both arrive as "the call
 * failed".
 */
export type GithubApiFailure = "refused" | "retryable" | "unexpected" | "malformed";

export class GithubApiError extends Error {
  readonly failure: GithubApiFailure;
  readonly endpoint: string;
  /** 0 when the request never produced a response. */
  readonly status: number;
  /**
   * The response headers, empty when there was no response.
   *
   * Carried because a status alone cannot tell a rate-limit 403 from a
   * permission 403 — `github-push-policy.ts`'s `pushOutcome` decides that from
   * which rate headers are present, and reading it wrong in either direction
   * either retries a permanent refusal for ever or drops a user's edit. They are
   * response headers only: nothing this class is ever constructed with carries a
   * request header, and so no token can reach a log line through it.
   */
  readonly headers: Headers;

  constructor(
    failure: GithubApiFailure,
    endpoint: string,
    status: number,
    detail: string,
    headers?: Headers
  ) {
    super(`github ${endpoint} ${detail} (status ${status})`);
    this.name = "GithubApiError";
    this.failure = failure;
    this.endpoint = endpoint;
    this.status = status;
    this.headers = headers ?? new Headers();
  }
}

export function statusFailure(status: number): GithubApiFailure {
  if (status === 401 || status === 403 || status === 404) return "refused";
  if (status === 429 || status >= 500) return "retryable";
  return "unexpected";
}

export type FetchLike = (url: string, init?: RequestInit) => Promise<Response>;

export type GithubUserInstallation = {
  installationId: string;
  accountLogin: string | null;
  accountId: string | null;
};

export type GithubInstallationAccount = {
  installationId: string;
  accountLogin: string;
  accountId: string;
  accountType: string;
};

export type GithubInstallationToken = {
  token: string;
  expiresAt: Date;
};

/** Named to feed `upsertIntegrationRepo` directly. `repoKey` is null for a name
 *  `githubRepoKey` refuses to fold, which the caller skips — the same refusal
 *  `github-inbound.ts` makes, since a repository we cannot key is one no
 *  checkout can ever join to. */
export type GithubInstallationRepo = {
  externalRepoId: string;
  repoKey: string | null;
  fullName: string;
  visibility: RepoVisibility;
  defaultBranch: string | null;
};

export interface GithubAppClient {
  /** Callback `code` → user-to-server token. The token is the caller's to hold
   *  and must not be logged or persisted. */
  exchangeUserCode(code: string): Promise<string>;
  /**
   * The installations the authenticated GitHub user can administer — the whole
   * basis for accepting a callback's `installation_id`.
   */
  listUserInstallations(userToken: string): Promise<GithubUserInstallation[]>;
  /**
   * The installation's account, for the integration's display name.
   *
   * **This call authorizes nothing.** It is signed with the App JWT, so it
   * succeeds for every installation of the App including installations of orgs
   * the caller has never heard of. Call it only after `listUserInstallations`
   * has already proven the id belongs to the person at the keyboard.
   */
  getInstallation(installationId: string): Promise<GithubInstallationAccount>;
  createInstallationToken(installationId: string): Promise<GithubInstallationToken>;
  listInstallationRepos(installationToken: string): Promise<GithubInstallationRepo[]>;
}

const ExternalIdSchema = z
  .union([z.int(), z.string().min(1).max(64)])
  .transform((v) => String(v));

/**
 * GitHub reports a failed code exchange **inside a 200** — `{"error":
 * "bad_verification_code"}` with no `access_token` — which is the classic way
 * this endpoint is implemented wrong, because `res.ok` is true and the token is
 * simply `undefined` from there on.
 *
 * `error` is pinned to the RFC 6749 code charset so the one provider-controlled
 * string this module ever repeats back cannot smuggle anything into a message;
 * a value outside it fails the parse, which is still a failure.
 */
const OAuthTokenSchema = z
  .object({
    access_token: z.string().min(1).optional(),
    error: z
      .string()
      .regex(/^[a-z_]{1,64}$/)
      .optional(),
  })
  .loose();

const UserInstallationsPageSchema = z
  .object({
    installations: z.array(
      z
        .object({
          id: ExternalIdSchema,
          account: z
            .object({ id: ExternalIdSchema, login: z.string().min(1).max(200) })
            .loose()
            .nullish(),
        })
        .loose()
    ),
  })
  .loose();

const InstallationSchema = z
  .object({
    id: ExternalIdSchema,
    account: z
      .object({
        id: ExternalIdSchema,
        login: z.string().min(1).max(200),
        type: z.string().min(1).max(64),
      })
      .loose(),
  })
  .loose();

const InstallationTokenSchema = z
  .object({
    token: z.string().min(1),
    expires_at: z.string().min(1),
  })
  .loose();

const InstallationReposPageSchema = z
  .object({
    repositories: z.array(
      z
        .object({
          id: ExternalIdSchema,
          full_name: z.string().min(3).max(512),
          private: z.boolean(),
          default_branch: z.string().min(1).max(255).nullish(),
        })
        .loose()
    ),
  })
  .loose();

export function createGithubAppClient(opts: {
  config: GithubAppConfig;
  fetch?: FetchLike;
}): GithubAppClient {
  const { config } = opts;
  const doFetch: FetchLike = opts.fetch ?? ((url, init) => globalThis.fetch(url, init));

  async function send(endpoint: string, url: string, init: RequestInit): Promise<Response> {
    try {
      return await doFetch(url, init);
    } catch {
      // The cause is deliberately dropped rather than chained: nothing downstream
      // decides anything from it, and a rethrown transport error is one more
      // object that could carry a header we built.
      throw new GithubApiError("retryable", endpoint, 0, "request failed");
    }
  }

  async function decode<T extends z.ZodType>(
    schema: T,
    res: Response,
    endpoint: string
  ): Promise<z.infer<T>> {
    let body: unknown;
    try {
      body = await res.json();
    } catch {
      throw new GithubApiError("malformed", endpoint, res.status, "response was not JSON");
    }
    const parsed = schema.safeParse(body);
    if (!parsed.success) {
      // The validation issues stay unread: they are derived from a body that,
      // for the token endpoints, is the secret itself.
      throw new GithubApiError("malformed", endpoint, res.status, "unexpected response shape");
    }
    return parsed.data;
  }

  async function apiGet<T extends z.ZodType>(
    schema: T,
    endpoint: string,
    authorization: string
  ): Promise<z.infer<T>> {
    const res = await send(endpoint, `${API_BASE}${endpoint}`, {
      method: "GET",
      headers: apiHeaders(authorization),
    });
    if (!res.ok) throw new GithubApiError(statusFailure(res.status), endpoint, res.status, "failed");
    return decode(schema, res, endpoint);
  }

  function appJwt(): string {
    return mintAppJwt(config, new Date());
  }

  async function collect<T>(endpoint: string, read: (page: number) => Promise<T[]>): Promise<T[]> {
    const out: T[] = [];
    for (let page = 1; page <= GITHUB_MAX_PAGES; page++) {
      const items = await read(page);
      out.push(...items);
      if (items.length < GITHUB_PER_PAGE) return out;
    }
    throw new GithubApiError("unexpected", endpoint, 0, "exceeded the page ceiling");
  }

  return {
    async exchangeUserCode(code: string): Promise<string> {
      const res = await send(OAUTH_TOKEN_URL, OAUTH_TOKEN_URL, {
        method: "POST",
        headers: {
          accept: "application/json",
          "content-type": "application/x-www-form-urlencoded",
          "user-agent": USER_AGENT,
        },
        body: new URLSearchParams({
          client_id: config.clientId,
          client_secret: config.clientSecret,
          code,
        }).toString(),
      });
      if (!res.ok) {
        throw new GithubApiError(
          statusFailure(res.status),
          OAUTH_TOKEN_URL,
          res.status,
          "code exchange failed"
        );
      }
      const body = await decode(OAuthTokenSchema, res, OAUTH_TOKEN_URL);
      if (body.error || !body.access_token) {
        throw new GithubApiError(
          "refused",
          OAUTH_TOKEN_URL,
          res.status,
          `code exchange rejected: ${body.error ?? "no access_token"}`
        );
      }
      return body.access_token;
    },

    async listUserInstallations(userToken: string): Promise<GithubUserInstallation[]> {
      const endpoint = "/user/installations";
      return collect(endpoint, async (page) => {
        const body = await apiGet(
          UserInstallationsPageSchema,
          `${endpoint}?per_page=${GITHUB_PER_PAGE}&page=${page}`,
          `Bearer ${userToken}`
        );
        return body.installations.map((row) => ({
          installationId: row.id,
          accountLogin: row.account?.login ?? null,
          accountId: row.account?.id ?? null,
        }));
      });
    },

    async getInstallation(installationId: string): Promise<GithubInstallationAccount> {
      const endpoint = `/app/installations/${installationPathSegment(installationId)}`;
      const body = await apiGet(InstallationSchema, endpoint, `Bearer ${appJwt()}`);
      return {
        installationId: body.id,
        accountLogin: body.account.login,
        accountId: body.account.id,
        accountType: body.account.type,
      };
    },

    async createInstallationToken(installationId: string): Promise<GithubInstallationToken> {
      const endpoint = `/app/installations/${installationPathSegment(installationId)}/access_tokens`;
      const res = await send(endpoint, `${API_BASE}${endpoint}`, {
        method: "POST",
        headers: apiHeaders(`Bearer ${appJwt()}`),
      });
      if (!res.ok) {
        throw new GithubApiError(statusFailure(res.status), endpoint, res.status, "failed");
      }
      const body = await decode(InstallationTokenSchema, res, endpoint);
      const expiresAt = new Date(body.expires_at);
      if (Number.isNaN(expiresAt.getTime())) {
        throw new GithubApiError("malformed", endpoint, res.status, "unreadable token expiry");
      }
      return { token: body.token, expiresAt };
    },

    async listInstallationRepos(installationToken: string): Promise<GithubInstallationRepo[]> {
      const endpoint = "/installation/repositories";
      return collect(endpoint, async (page) => {
        const body = await apiGet(
          InstallationReposPageSchema,
          `${endpoint}?per_page=${GITHUB_PER_PAGE}&page=${page}`,
          `Bearer ${installationToken}`
        );
        return body.repositories.map((repo) => ({
          externalRepoId: repo.id,
          repoKey: githubRepoKey(repo.full_name),
          fullName: repo.full_name,
          visibility: (repo.private ? "private" : "public") satisfies RepoVisibility,
          defaultBranch: repo.default_branch ?? null,
        }));
      });
    },
  };
}

export function apiHeaders(authorization: string): Record<string, string> {
  return {
    accept: "application/vnd.github+json",
    "x-github-api-version": API_VERSION,
    "user-agent": USER_AGENT,
    authorization,
  };
}

/**
 * The installation id reaching this module came off a callback query string, and
 * it is interpolated into a request path — so `../../user` would aim an
 * App-JWT-signed request at an endpoint of the caller's choosing. GitHub ids are
 * decimal, so anything else is refused before a URL is built rather than escaped
 * into one.
 */
function installationPathSegment(installationId: string): string {
  if (!/^[0-9]{1,20}$/.test(installationId)) {
    throw new GithubApiError("refused", "/app/installations", 0, "malformed installation id");
  }
  return installationId;
}
