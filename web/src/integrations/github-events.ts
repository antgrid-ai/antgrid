// SPDX-FileCopyrightText: 2026 Radha AI Products
// SPDX-License-Identifier: LicenseRef-Elastic-2.0

import { z } from "zod";
import { isValidRepoKey } from "../util/repo-key.js";

/**
 * The GitHub App's inbound event vocabulary: what the App subscribes to, what
 * the drain acts on, and the schemas each payload is re-validated against.
 *
 * **The event name is a header (`X-GitHub-Event`) and GitHub signs the body
 * only**, so it is a routing hint and never evidence. Every handler re-validates
 * the body it was routed to, and a mismatch is a refusal rather than a
 * mis-write; the dedup key being a hash of the signed bytes means a replay that
 * swaps the header collides with the genuine delivery instead of forking it.
 */

/** The `webhook_events.provider` value and the `Integration.provider` these
 *  deliveries resolve through — one string, so a typo cannot split the table. */
export const GITHUB_PROVIDER = "github";

/** What the drain applies. The first three resolve through the installation and
 *  touch only integration rows; the last two are the import and move tasks. */
export const GITHUB_HANDLED_EVENTS = [
  "installation",
  "installation_repositories",
  "repository",
  "issues",
  "issue_comment",
] as const;

/**
 * Recorded with `processed_at` null and deliberately never claimed by the drain.
 *
 * Marking them processed would lose the backlog; leaving them claimable would
 * jam the drain on payloads nothing can apply yet. The drain filters on the
 * handled set, so turning these on is moving a name across to
 * `GITHUB_HANDLED_EVENTS` and writing the handler — the rows recorded in the
 * meantime then drain in receipt order.
 *
 * `label` stays here for a reason that is not "no time yet". The App's
 * configured event list does not
 * include it, so nothing is being recorded to drain; and every `issues` payload
 * already carries the issue's own label array, so the import gets label
 * membership without it. What a `label` event would add is only the label's own
 * rename and delete — the two cases the plan's merge section calls out as
 * corrupting the element-wise diff. Turning it on is a change to the App
 * registration first and a handler second.
 */
export const GITHUB_DEFERRED_EVENTS = ["label"] as const;

/**
 * What the App subscribes to. Anything outside it is acknowledged and dropped at
 * the door — an unknown event type is a normal condition (GitHub adds them, and
 * `ping` arrives the moment a hook is created), not a failure.
 *
 * Derived rather than listed, so moving a type from deferred to handled cannot
 * also change what the endpoint accepts.
 */
export const GITHUB_SUBSCRIBED_EVENTS = [
  ...GITHUB_HANDLED_EVENTS,
  ...GITHUB_DEFERRED_EVENTS,
] as const;

export type GithubEventType = (typeof GITHUB_SUBSCRIBED_EVENTS)[number];

const SUBSCRIBED = new Set<string>(GITHUB_SUBSCRIBED_EVENTS);

export function isSubscribedGithubEvent(type: string): type is GithubEventType {
  return SUBSCRIBED.has(type);
}

/** GitHub ids are numbers on the wire and text in our columns; both forms are
 *  accepted so a hand-built fixture and a real delivery agree. */
const ExternalIdSchema = z
  .union([z.int(), z.string().min(1).max(64)])
  .transform((v) => String(v));

/**
 * What lands in `webhook_events.payload`.
 *
 * The delivery id is kept beside the body rather than as the dedup key: it is a
 * header, outside the signed bytes, so it identifies nothing — but it is what
 * GitHub's own delivery log is indexed by and therefore the only string an
 * operator can correlate a complaint with.
 */
export const StoredGithubDeliverySchema = z.object({
  deliveryId: z.string().max(200).nullable(),
  body: z.unknown(),
});
export type StoredGithubDelivery = z.infer<typeof StoredGithubDeliverySchema>;

/** Validated before the row is written: only the parts the route itself needs. */
export const GithubEnvelopeSchema = z
  .object({
    action: z.string().max(64).optional(),
    installation: z.object({ id: ExternalIdSchema }).loose().optional(),
  })
  .loose();

const GithubRepoRefSchema = z
  .object({
    id: ExternalIdSchema,
    full_name: z.string().min(3).max(512),
    private: z.boolean(),
  })
  .loose();
export type GithubRepoRef = z.infer<typeof GithubRepoRefSchema>;

/**
 * Every key used anywhere below to tell one handled event's payload from
 * another's — `distinctEventShape` forbids whichever of these a schema does
 * not itself declare. `action` and `installation` are deliberately absent:
 * every handled event carries both, so neither discriminates anything.
 */
const DISCRIMINATING_EVENT_KEYS = [
  "repository",
  "issue",
  "comment",
  "repositories",
  "repositories_added",
  "repositories_removed",
] as const;

/**
 * Rejects a body carrying a key that belongs to a DIFFERENT handled event's
 * shape.
 *
 * `X-GitHub-Event` is a header, outside the signed bytes, so a captured
 * `(body, signature)` pair replays under any header the caller likes — the
 * dedup key hashes the raw bytes and does not care what the replay claims to
 * be. `.loose()` alone does not close this: it accepts and ignores unknown
 * keys, so an `issues` delivery whose `action` happens to be `"deleted"`
 * replayed with the header `installation` would otherwise parse cleanly
 * against `InstallationEventSchema` and reach `applyInstallation`'s
 * `"deleted"` case — revoking the whole integration from a payload that was
 * never an installation event. Each handled event's schema therefore forbids
 * every key from `DISCRIMINATING_EVENT_KEYS` that its own shape does not
 * declare, so a body shaped for one event can only ever validate as itself —
 * and a schema that grows a new discriminating field closes the gap against
 * every other handled event without anyone updating a second list by hand.
 */
function distinctEventShape<T extends z.ZodObject<z.ZodRawShape>>(schema: T): T {
  const ownKeys = new Set(Object.keys(schema.shape));
  const foreignKeys = DISCRIMINATING_EVENT_KEYS.filter((key) => !ownKeys.has(key));
  // zod v4 attaches a `.refine` check in place rather than wrapping the
  // schema in a distinct type, so the return type is still `T` — annotating
  // it as a fresh `z.ZodType<z.infer<T>>` does not typecheck, since TS cannot
  // prove a generic object schema's inferred output matches `output<T>`.
  return schema.refine(
    (body) => foreignKeys.every((key) => !(key in body)),
    { message: "payload shape belongs to a different event type" }
  );
}

/**
 * Actions are `z.string()` rather than an enum on purpose: GitHub adds them
 * (`new_permissions_accepted` arrived years after `installation` shipped), and
 * an enum turns a new one into a payload that fails validation five times and
 * gives up. An unrecognized action is a no-op the drain marks processed.
 */
export const InstallationEventSchema = distinctEventShape(
  z
    .object({
      action: z.string().max(64),
      installation: z
        .object({
          id: ExternalIdSchema,
          account: z.object({ login: z.string().max(200) }).loose().optional(),
        })
        .loose(),
      repositories: z.array(GithubRepoRefSchema).max(1000).optional(),
    })
    .loose()
);

export const InstallationRepositoriesEventSchema = distinctEventShape(
  z
    .object({
      action: z.string().max(64),
      installation: z.object({ id: ExternalIdSchema }).loose(),
      repositories_added: z.array(GithubRepoRefSchema).max(1000).optional(),
      repositories_removed: z.array(GithubRepoRefSchema).max(1000).optional(),
    })
    .loose()
);

export const RepositoryEventSchema = distinctEventShape(
  z
    .object({
      action: z.string().max(64),
      installation: z.object({ id: ExternalIdSchema }).loose(),
      repository: GithubRepoRefSchema,
    })
    .loose()
);

/** A provider identity we snapshot but never resolve to an account member —
 *  there is no provider-identity → member mapping table, so `avatar_url` and
 *  `login` are display-only. */
const GithubUserSchema = z
  .object({
    id: ExternalIdSchema,
    login: z.string().min(1).max(200),
    avatar_url: z.string().max(2000).nullish(),
  })
  .loose();

const GithubLabelRefSchema = z
  .object({
    name: z.string().min(1).max(200),
    color: z.string().max(32).nullish(),
  })
  .loose();

/**
 * The issue as every issue-bearing payload carries it — `issues` and
 * `issue_comment` both embed the whole object, which is what lets a comment
 * delivery import an issue no earlier delivery managed to.
 *
 * `state` is an enum and `state_reason` is not, and the asymmetry is deliberate.
 * `state` is a closed two-value domain that `RemoteState` mirrors exactly, so a
 * third value is a semantic change to refuse rather than guess at; GitHub keeps
 * adding reasons (`duplicate` arrived years after the original three) and an
 * enum there would reject a payload we can otherwise apply in full.
 *
 * `title` is bounded at what `TaskTitleSchema` accepts rather than at GitHub's
 * own 256, so an over-long title is a refused delivery instead of a task create
 * that fails after all the routing work.
 */
export const GithubIssueSchema = z
  .object({
    id: ExternalIdSchema,
    number: z.int(),
    title: z.string().max(500),
    body: z.string().nullish(),
    state: z.enum(["open", "closed"]),
    state_reason: z.string().max(64).nullish(),
    html_url: z.string().max(2000).nullish(),
    labels: z.array(GithubLabelRefSchema).max(200).optional(),
    assignee: GithubUserSchema.nullish(),
    assignees: z.array(GithubUserSchema).max(100).optional(),
    milestone: z.object({ title: z.string().max(500) }).loose().nullish(),
    updated_at: z.string().max(64).nullish(),
  })
  .loose();
export type GithubIssue = z.infer<typeof GithubIssueSchema>;

export const GithubIssueCommentSchema = z
  .object({
    id: ExternalIdSchema,
    body: z.string().nullish(),
    user: GithubUserSchema.nullish(),
  })
  .loose();
export type GithubIssueComment = z.infer<typeof GithubIssueCommentSchema>;

/** `repository` is required on both: it is the only thing in the payload that
 *  names which repo of the installation the issue lives in, and that lookup is
 *  what the per-repo consents hang off. Forbids `comment`, the one key an
 *  `issue_comment` body adds on top of this exact shape — without it a captured
 *  `issue_comment` delivery replayed as `issues` would import the embedded issue
 *  a second time under the wrong event's action semantics. */
export const IssuesEventSchema = distinctEventShape(
  z
    .object({
      action: z.string().max(64),
      installation: z.object({ id: ExternalIdSchema }).loose(),
      repository: GithubRepoRefSchema,
      issue: GithubIssueSchema,
    })
    .loose()
);

export const IssueCommentEventSchema = distinctEventShape(
  z
    .object({
      action: z.string().max(64),
      installation: z.object({ id: ExternalIdSchema }).loose(),
      repository: GithubRepoRefSchema,
      issue: GithubIssueSchema,
      comment: GithubIssueCommentSchema,
    })
    .loose()
);

/**
 * True when an issue object is really a pull request.
 *
 * GitHub models PRs as issues, so both the REST list and the webhook carry them
 * and the only discriminator is the presence of the `pull_request` key — not its
 * value, which is an object we never read. Unfiltered, every PR in the repo
 * becomes an Antgrid task on first sync.
 */
export function isPullRequestIssue(issue: unknown): boolean {
  return typeof issue === "object" && issue !== null && "pull_request" in issue;
}

/**
 * The same question asked of a webhook body rather than of an issue.
 *
 * Two spellings because the two callers hold different objects: a delivery
 * carries `{ issue }`, `GET /issues` carries the issue itself. One predicate
 * taking a body silently answers `false` for every listing item, which is the
 * shape that imports the whole PR queue.
 */
export function carriesPullRequest(body: unknown): boolean {
  if (typeof body !== "object" || body === null) return false;
  return isPullRequestIssue((body as { issue?: unknown }).issue);
}

/**
 * The repoKey a GitHub repository folds to — the same string
 * `bridge/src/repo-key.ts` produces from an origin remote, because that identity
 * is the only thing joining a provider repository to a checkout on a machine.
 * `null` for a name this cannot fold, so a caller refuses rather than guesses.
 *
 * The host is fixed: the App is a github.com App. GitHub Enterprise Server would
 * take it from `repository.html_url` instead.
 */
export function githubRepoKey(fullName: string): string | null {
  const key = `github.com/${fullName.trim().toLowerCase()}`;
  return isValidRepoKey(key) ? key : null;
}
