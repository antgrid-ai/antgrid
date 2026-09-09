import { z } from "zod";
import {
  API_BASE,
  GITHUB_MAX_PAGES,
  GITHUB_PER_PAGE,
  GithubApiError,
  apiHeaders,
  statusFailure,
  type FetchLike,
} from "./github-app.js";
import { GithubIssueSchema, type GithubIssue } from "./github-events.js";

/**
 * The outbox's writer seam: the only place in this service that mutates a
 * GitHub issue.
 *
 * It is an interface rather than four exported functions so the drain can be
 * tested against a fake without a network, and so the one-way boundary the
 * outbox depends on stays visible: everything here is signed with an
 * **installation** token, never the App JWT — the App JWT answers for every
 * installation of the App across every tenant, and a write is exactly where
 * that would be catastrophic.
 *
 * Failures use `github-app.ts`'s vocabulary unchanged (`refused` / `retryable` /
 * `unexpected` / `malformed`) so a drain can branch on one union rather than two.
 * The one deliberate divergence is 401: there it means the user's code or token
 * is wrong and the install flow must stop, here it means the installation token
 * this writer was handed aged out mid-drain, which a fresh token fixes. Callers
 * that mint per-drain tokens should treat a `refused` 401 as re-mintable rather
 * than as an op to retire — see `github-push-policy.ts`, which classifies
 * responses for that decision.
 */

/**
 * GitHub's own charset for a login and a repository name. Both are interpolated
 * into a request path, so anything outside it is refused before a URL exists
 * rather than escaped into one.
 *
 * The dot cannot simply be banned — real repositories are named `docs.example.com`
 * — so `.` and `..` are excluded by name instead. Neither is a nameable repository
 * on GitHub, and `..` is the whole traversal attack.
 */
const PATH_SEGMENT = /^[A-Za-z0-9._-]{1,100}$/;

function isPathSegment(value: string): boolean {
  return PATH_SEGMENT.test(value) && value !== "." && value !== "..";
}

/** Where a write is addressed. Not `GithubRepoRef` — `github-events.ts` owns
 *  that name for the repository object a webhook payload carries, which is a
 *  description of a repository rather than an address for one. */
export type GithubRepoTarget = { owner: string; repo: string };
export type GithubIssueTarget = GithubRepoTarget & { number: number };

/**
 * Exactly what v1 pushes, and **`assignees` is absent by construction**.
 *
 * The omission is structural rather than a convention the drain is trusted to
 * keep, because a pushed assignee array is a non-convergent write loop with no
 * detector: GitHub silently drops an assignee lacking push access, answering
 * `200` with the login missing, so the response-derived base never matches the
 * local value and every reconcile pushes again — one content-creating write per
 * task per cycle against the 500/hour budget, forever, with `attempts` never
 * firing because the push succeeded. `labels` has the same whole-array replace
 * semantics and is only safe because it is recomputed from current rows at send
 * time; a replayed stale array is a set rollback, not a repeat.
 */
export type GithubIssuePatch = {
  title?: string;
  body?: string;
  state?: "open" | "closed";
  /** GitHub documents this as ignored unless `state` changes, so sending it on
   *  an already-closed issue cannot deliver a `done → cancelled` edit. */
  state_reason?: "completed" | "not_planned" | "reopened" | null;
  labels?: string[];
};

export type GithubIssueCreate = {
  title: string;
  body?: string;
  labels?: string[];
};

export interface GithubIssueWriter {
  /**
   * The pre-push re-fetch. GitHub has no `If-Match` on issues, so a PATCH is
   * blind; comparing this against the stored base immediately before writing is
   * the only thing that turns it into something close to a compare-and-swap,
   * and the only thing standing between a queued push and a human's edit made
   * while it sat in the queue.
   */
  getIssue(ref: GithubIssueTarget): Promise<GithubIssue>;
  patchIssue(ref: GithubIssueTarget, patch: GithubIssuePatch): Promise<GithubIssue>;
  createIssue(ref: GithubRepoTarget, input: GithubIssueCreate): Promise<GithubIssue>;
  /**
   * Retry resolution for a create whose response was lost: list this App's own
   * recent issues and match the embedded op marker client-side.
   *
   * **Not `GET /search/issues`**, for four independent reasons: the search index
   * is eventually consistent and the retry window is the fast one, so it returns
   * zero hits for an issue that exists and we post a public duplicate; search
   * carries its own 30/minute budget, which a retry storm hits first, and a 403
   * on the read reads as "not found" unless handled; `q=antgrid:op:<key>` is not
   * valid free text because colons are qualifier syntax; and a human editing the
   * body deletes the marker. The primary store has none of those properties.
   */
  listAppIssuesSince(
    ref: GithubRepoTarget,
    args: { appSlug: string; since: Date }
  ): Promise<GithubIssue[]>;
}

/**
 * The reconcile poll's read seam, deliberately NOT a method on
 * `GithubIssueWriter`.
 *
 * That interface is the outbox's write boundary and every fake in the push
 * tests is typed against it; folding a lister in would make each of them grow a
 * method it never calls, and would blur the one-way boundary the outbox depends
 * on being visible. The poll takes this alone — it never writes.
 */
export interface GithubIssueLister {
  /**
   * One page of the repository's issues, newest edit last.
   *
   * **`direction=asc` is load-bearing, not a display choice.** Ascending by
   * `updated` means the walk is a prefix: a run that stops at a page ceiling, a
   * time budget or a rate refusal still leaves a cursor everything before which
   * is done, so the next run resumes rather than restarts. Descending order
   * cannot advance a cursor until the entire walk completes, so any repository
   * with more issues than the page ceiling would never record progress and would
   * re-read its first pages for ever.
   *
   * One page per call, and the caller owns both the pagination and its ceiling —
   * the opposite of `listAppIssuesSince`, which loops internally because it must
   * fail closed on truncation. Here truncation is the normal, resumable case.
   */
  listRepoIssuesSince(
    ref: GithubRepoTarget,
    args: { since: Date | null; page: number }
  ): Promise<GithubIssue[]>;
}

/**
 * The marker embedded in a created body: an HTML comment, so it is invisible in
 * rendered Markdown, stable across retries of one op and unique across ops.
 *
 * **It is a hint, never the guard.** A human can edit it out of the body, and
 * `listAppIssuesSince` only sees issues GitHub has already made visible, so a
 * miss proves nothing. The durable guard is the local one the plan requires
 * regardless: never re-enqueue a create for a `Task` that already carries an
 * `externalId`.
 */
const OP_KEY = /^[A-Za-z0-9._-]{1,128}$/;
const OP_MARKER = /<!--\s*antgrid:op:([A-Za-z0-9._-]{1,128})\s*-->/;

export function opMarker(opKey: string): string {
  // A key carrying `>` or `--` would close the comment early, making the marker
  // visible in the issue body and letting one op's key be read as another's.
  if (!OP_KEY.test(opKey)) throw new TypeError("op key outside the marker charset");
  return `<!-- antgrid:op:${opKey} -->`;
}

/** Idempotent: a retry re-deriving the body from the same row must produce a
 *  byte-identical string, or the marker stops identifying one op. */
export function withOpMarker(body: string | null | undefined, opKey: string): string {
  const marker = opMarker(opKey);
  const text = body?.trim() ?? "";
  if (findOpKey(text) === opKey) return text;
  return text ? `${text}\n\n${marker}` : marker;
}

export function findOpKey(body: string | null | undefined): string | null {
  return (body ? OP_MARKER.exec(body)?.[1] : null) ?? null;
}

const IssueListSchema = z.array(GithubIssueSchema);

export function createGithubIssueWriter(opts: {
  /** A function so a drain outliving the installation token's hour can re-mint
   *  without rebuilding the writer. */
  token: string | (() => string | Promise<string>);
  fetch?: FetchLike;
}): GithubIssueWriter & GithubIssueLister {
  const doFetch: FetchLike = opts.fetch ?? ((url, init) => globalThis.fetch(url, init));
  const token = opts.token;

  async function authorization(): Promise<string> {
    return `Bearer ${typeof token === "string" ? token : await token()}`;
  }

  async function send(endpoint: string, url: string, init: RequestInit): Promise<Response> {
    try {
      return await doFetch(url, init);
    } catch {
      // Dropped rather than chained, as in `github-app.ts`: a rethrown transport
      // error is one more object that could carry the token we just built.
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
      throw new GithubApiError("malformed", endpoint, res.status, "unexpected response shape");
    }
    return parsed.data;
  }

  async function call<T extends z.ZodType>(
    schema: T,
    endpoint: string,
    init: { method: string; body?: unknown }
  ): Promise<z.infer<T>> {
    const headers = apiHeaders(await authorization());
    const res = await send(endpoint, `${API_BASE}${endpoint}`, {
      method: init.method,
      headers: init.body === undefined ? headers : { ...headers, "content-type": "application/json" },
      ...(init.body === undefined ? {} : { body: JSON.stringify(init.body) }),
    });
    // The headers travel with the failure because the drain classifies it
    // through `pushOutcome`, which tells a secondary-limit 403 from a permission
    // 403 by which rate headers are present and by nothing else.
    if (!res.ok) {
      throw new GithubApiError(
        statusFailure(res.status),
        endpoint,
        res.status,
        "failed",
        res.headers
      );
    }
    return decode(schema, res, endpoint);
  }

  return {
    async getIssue(ref: GithubIssueTarget): Promise<GithubIssue> {
      return call(GithubIssueSchema, issuePath(ref), { method: "GET" });
    },

    async patchIssue(ref: GithubIssueTarget, patch: GithubIssuePatch): Promise<GithubIssue> {
      return call(GithubIssueSchema, issuePath(ref), { method: "PATCH", body: patch });
    },

    async createIssue(ref: GithubRepoTarget, input: GithubIssueCreate): Promise<GithubIssue> {
      return call(GithubIssueSchema, `${repoPath(ref)}/issues`, { method: "POST", body: input });
    },

    async listAppIssuesSince(
      ref: GithubRepoTarget,
      args: { appSlug: string; since: Date }
    ): Promise<GithubIssue[]> {
      if (!isPathSegment(args.appSlug)) {
        throw new GithubApiError("refused", repoPath(ref), 0, "malformed app slug");
      }
      const base = `${repoPath(ref)}/issues`;
      const out: GithubIssue[] = [];
      for (let page = 1; page <= GITHUB_MAX_PAGES; page++) {
        const query = new URLSearchParams({
          // `state=all` is load-bearing: the endpoint defaults to open issues, and
          // an issue closed by a human between our lost response and the retry
          // would then be invisible — the exact case that posts a duplicate.
          state: "all",
          creator: `app/${args.appSlug}`,
          sort: "created",
          direction: "desc",
          since: args.since.toISOString(),
          per_page: String(GITHUB_PER_PAGE),
          page: String(page),
        });
        const items = await call(IssueListSchema, `${base}?${query.toString()}`, { method: "GET" });
        out.push(...items);
        if (items.length < GITHUB_PER_PAGE) return out;
      }
      // Fails closed. The caller's next move on an unresolved create is to post,
      // so returning a truncated list is the shape that publishes a duplicate.
      throw new GithubApiError("unexpected", base, 0, "exceeded the page ceiling");
    },

    async listRepoIssuesSince(
      ref: GithubRepoTarget,
      args: { since: Date | null; page: number }
    ): Promise<GithubIssue[]> {
      if (!Number.isSafeInteger(args.page) || args.page < 1) {
        throw new GithubApiError("refused", repoPath(ref), 0, "malformed page number");
      }
      const query = new URLSearchParams({
        // Same reason as above: the endpoint defaults to open issues, so a
        // reconcile that omitted this would never see a close it missed.
        state: "all",
        sort: "updated",
        // See `GithubIssueLister` — ascending is what makes a partial walk
        // resumable, and the whole cursor scheme rests on it.
        direction: "asc",
        per_page: String(GITHUB_PER_PAGE),
        page: String(args.page),
      });
      // Omitted rather than sent as an epoch on a first import: `since` is a
      // filter, and any floor we invented would silently exclude the issues
      // predating it — which is exactly the backlog a first import exists for.
      if (args.since !== null) query.set("since", args.since.toISOString());
      return call(IssueListSchema, `${repoPath(ref)}/issues?${query.toString()}`, {
        method: "GET",
      });
    },
  };
}

function repoPath(ref: GithubRepoTarget): string {
  if (!isPathSegment(ref.owner) || !isPathSegment(ref.repo)) {
    throw new GithubApiError("refused", "/repos", 0, "malformed repository reference");
  }
  return `/repos/${ref.owner}/${ref.repo}`;
}

function issuePath(ref: GithubIssueTarget): string {
  if (!Number.isSafeInteger(ref.number) || ref.number < 1) {
    throw new GithubApiError("refused", "/repos", 0, "malformed issue number");
  }
  return `${repoPath(ref)}/issues/${ref.number}`;
}
