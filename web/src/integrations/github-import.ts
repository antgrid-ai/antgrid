import { z } from "zod";
import { ImportFilterKindSchema } from "../models/integration.js";
import type { ProviderUser } from "../models/integration-identity.js";
import { toRemote, type Assignee, type LocalFields, type SnapshotFields } from "../tasks/merge.js";
import type { GithubIssue, GithubIssueComment } from "./github-events.js";

/**
 * GitHub payload → the field shapes `src/tasks/merge.ts` merges over.
 *
 * Everything here is pure: no database, no clock, no provider client. The merge
 * is already pure for the same reason, and keeping the mapping beside it is what
 * lets the whole provider-space half of the import be tested from fixtures with
 * no Postgres in the loop.
 *
 * **The output is provider space, not Antgrid vocabulary.** `status` stays as
 * the raw `state`/`state_reason` pair because the Antgrid mapping onto GitHub is
 * many-to-one; normalizing it here is the push loop the shadow snapshot exists
 * to prevent.
 */

/**
 * The identity the `[accountId, externalProvider, externalId]` unique is keyed
 * on — the whole inbound idempotency mechanism, so it has to be one rule applied
 * everywhere, issues and comments alike.
 *
 * The numeric `id`, never `node_id`. Both address the same object, but only one
 * is promised never to change: GitHub ran a node-ID format migration between
 * 2021 and 2023, and a reformat is invisible here — every stored `externalId`
 * silently stops matching, the lookup finds nothing, and the next delivery
 * creates a SECOND task for an issue we already hold. That is precisely the
 * failure this unique exists to prevent, and it would be a backfill to undo
 * rather than a fix. `node_id` earns the column back only if the reconcile poll
 * moves to GraphQL, where it is the only addressable id — and even then it is a
 * second column, not a replacement for this one.
 */
export function githubExternalId(object: { id: string }): string {
  return object.id;
}

/** `owner/repo#number` — the human-readable half of the link, and the only
 *  external column a person can read back to a URL without a lookup. */
export function githubIssueExternalKey(repoFullName: string, issue: GithubIssue): string {
  return `${repoFullName}#${issue.number}`;
}

/**
 * The issue number back out of an `externalKey`.
 *
 * There is no dedicated column: `externalId` is the provider's numeric object id
 * (stable across a rename, and not addressable in a REST path) and this key is
 * the only place the issue *number* — the thing `PATCH /issues/{n}` takes — is
 * stored. So an outbound write parses it, and a key it cannot parse is a task
 * that must not be written to rather than one written to at a guessed number.
 */
export function githubIssueNumberFromKey(externalKey: string | null): number | null {
  const match = /#(\d{1,12})$/.exec(externalKey ?? "");
  if (!match) return null;
  const number = Number(match[1]);
  return Number.isSafeInteger(number) && number >= 1 ? number : null;
}

/**
 * `owner/repo` out of an `IntegrationRepo.repoKey`.
 *
 * The repo key is the normalized identity the row is keyed by and survives a
 * rename through `externalRepoId`, which is why an outbound write addresses
 * through it rather than through a task's `externalKey` — that one is a display
 * string, and a task published from Antgrid has none at all yet.
 *
 * Exactly `github.com/<owner>/<repo>`, refusing anything else. `API_BASE` is
 * github.com only, so a deeper path or another host is a repository this writer
 * cannot address; guessing the last two segments of an unfamiliar key is how a
 * write lands in a repository nobody named.
 */
export function githubRepoFromKey(
  repoKey: string | null
): { owner: string; repo: string } | null {
  const parts = (repoKey ?? "").split("/");
  if (parts.length !== 3 || parts[0] !== "github.com") return null;
  const [, owner, repo] = parts;
  if (!owner || !repo) return null;
  return { owner, repo };
}

/** The `owner/repo` an `externalKey` is built from. */
export function githubRepoFullName(repoKey: string | null): string | null {
  const ref = githubRepoFromKey(repoKey);
  return ref === null ? null : `${ref.owner}/${ref.repo}`;
}

/**
 * `state_reason` outside the closed set `RemoteStateReason` names folds to null.
 *
 * GitHub adds reasons, and the merge's union cannot grow to meet them without a
 * change in `merge.ts` — but a `closed` issue with an unrecognized reason is
 * still closed, and `fromRemote` reads anything that is not `not_planned` as
 * `done`. Folding to null keeps that reading and, more importantly, keeps the
 * snapshot comparison stable: the alternative is a value that never equals
 * itself on the next delivery and manufactures a diff for ever.
 */
export function githubStateReason(
  value: string | null | undefined
): "completed" | "not_planned" | null {
  return value === "completed" || value === "not_planned" ? value : null;
}

/**
 * Every assignee the payload names, in provider order.
 *
 * `assignee` is the deprecated singular field and is consulted only when
 * `assignees` is absent entirely: where the array is present it is authoritative,
 * and an empty one means nobody rather than "fall back to whichever one GitHub
 * picked".
 */
export function githubAssignees(issue: GithubIssue): ProviderUser[] {
  const users = issue.assignees ?? (issue.assignee ? [issue.assignee] : []);
  return users.map((user) => ({
    externalUserId: githubExternalId(user),
    login: user.login,
    avatarUrl: user.avatar_url ?? null,
  }));
}

/** `members` is `models/integration-identity.ts`'s resolution — the only thing
 *  entitled to turn a provider login into a `user` row. Absent from it, the
 *  assignee is external, which is a true statement about somebody we cannot
 *  name rather than a guess about somebody we can. */
function toAssignee(user: ProviderUser, members: ReadonlyMap<string, string>): Assignee {
  const userId = members.get(user.externalUserId);
  if (userId !== undefined) return { kind: "member", userId };
  return {
    kind: "external",
    externalId: user.externalUserId,
    login: user.login,
    avatarUrl: user.avatarUrl,
  };
}

/** The one assignee the column pair keeps. A member outranks provider order:
 *  the column exists to answer "who on this team owns it", and an external
 *  co-assignee cannot answer that at all. */
function readAssignee(issue: GithubIssue, members: ReadonlyMap<string, string>): Assignee | null {
  const users = githubAssignees(issue);
  if (users.length === 0) return null;
  const chosen = users.find((user) => members.has(user.externalUserId)) ?? users[0]!;
  return toAssignee(chosen, members);
}

export function githubIssueToRemote(
  issue: GithubIssue,
  members: ReadonlyMap<string, string>
): SnapshotFields {
  return {
    title: issue.title,
    body: issue.body ?? "",
    status: { state: issue.state, stateReason: githubStateReason(issue.state_reason) },
    labels: (issue.labels ?? []).map((label) => label.name),
    assignee: readAssignee(issue, members),
    assignees: githubAssignees(issue).map((user) => toAssignee(user, members)),
  };
}

/** GitHub's own default label colour. A label the payload leaves colourless
 *  round-trips to the hex the provider would have chosen for it. */
export const DEFAULT_LABEL_COLOR = "ededed";

/** Colours by label name, for `getOrCreateLabel`. Only a label this account has
 *  never seen takes its colour from here — an existing row keeps the one it has,
 *  which is what stops an import from repainting a label a user recoloured. */
export function githubLabelColors(issue: GithubIssue): Map<string, string> {
  const colors = new Map<string, string>();
  for (const label of issue.labels ?? []) {
    colors.set(label.name, label.color && /^[0-9a-fA-F]{6}$/.test(label.color)
      ? label.color
      : DEFAULT_LABEL_COLOR);
  }
  return colors;
}

export function githubCommentBody(comment: GithubIssueComment): string {
  return comment.body ?? "";
}

export function githubCommentAuthorLogin(comment: GithubIssueComment): string | null {
  return comment.user?.login ?? null;
}

/** A timestamp the provider may omit or send unparseable. `null` rather than an
 *  Invalid Date, which Postgres rejects and which reads as a working value in
 *  every log line up to that point. */
export function parseGithubTimestamp(value: string | null | undefined): Date | null {
  if (!value) return null;
  const parsed = new Date(value);
  return Number.isNaN(parsed.getTime()) ? null : parsed;
}

export type ImportScope = {
  importFilterKind: string;
  importFilterValue: string | null;
};

/**
 * Whether an issue is inside the repository's declared import scope.
 *
 * A kind outside the vocabulary can only reach here through a hand-written
 * UPDATE — `integration_repos_import_filter_check` bars it otherwise — and is
 * read as `all`, matching how `models/task.ts` reads an unknown status. Import
 * is the recoverable direction: an over-import is deletable, a silent
 * under-import is invisible.
 */
export function matchesImportFilter(
  repo: ImportScope,
  issue: GithubIssue,
  members: ReadonlyMap<string, string>
): boolean {
  const kind = ImportFilterKindSchema.safeParse(repo.importFilterKind);
  if (!kind.success) return true;
  const value = repo.importFilterValue?.trim() ?? "";

  switch (kind.data) {
    case "all":
      return true;
    case "label": {
      if (value === "") return true;
      // Case-insensitive because `Label.name` is citext for exactly this reason:
      // `Bug` and `bug` are one label, so they must also be one filter.
      const wanted = value.toLowerCase();
      return (issue.labels ?? []).some((label) => label.name.toLowerCase() === wanted);
    }
    case "milestone": {
      if (value === "") return true;
      return (issue.milestone?.title ?? "").trim() === value;
    }
    case "assigned_to_member":
      // The strict reading: at least one assignee resolves to an account member.
      // An issue assigned only to provider users outside the account is exactly
      // what this filter is chosen to keep out, and the resolution that makes
      // "member" answerable is `members`.
      return githubAssignees(issue).some((user) => members.has(user.externalUserId));
  }
}

const AssigneeSchema = z.union([
  z.object({ kind: z.literal("member"), userId: z.string() }),
  z.object({
    kind: z.literal("external"),
    externalId: z.string(),
    login: z.string(),
    avatarUrl: z.string().nullish(),
  }),
]);

const SnapshotFieldsSchema = z.object({
  title: z.string(),
  body: z.string(),
  status: z.object({
    state: z.enum(["open", "closed"]),
    stateReason: z.enum(["completed", "not_planned", "reopened"]).nullish(),
  }),
  labels: z.array(z.string()),
  assignee: AssigneeSchema.nullable(),
  // Optional so every snapshot written before the field existed still parses;
  // an absent array is read as "unknown", never as "nobody else".
  assignees: z.array(AssigneeSchema).optional(),
});

/**
 * Read a stored `remoteSnapshot`.
 *
 * The annotated return type is what keeps this in step with `SnapshotFields` —
 * it stops compiling the moment the merge's shape moves. A blob that does not
 * parse is `null`, and callers treat that identically to a snapshot that was
 * never written: there is no safe way to merge against a base we cannot read,
 * and pretending otherwise silently picks a winner.
 */
export function parseRemoteSnapshot(value: unknown): SnapshotFields | null {
  const parsed = SnapshotFieldsSchema.safeParse(value);
  return parsed.success ? parsed.data : null;
}

/**
 * The base to merge against when there is no readable snapshot — the local row,
 * projected into provider space.
 *
 * This is what "take the remote wholesale" is, expressed as a base rather than
 * as a special case in the merge. With `base == local`, no field can read as
 * locally moved, so every field the remote differs on applies and none push; the
 * label set works out to exactly the remote's by the same algebra. Passing the
 * *remote* as the base instead would be the opposite — nothing would move and
 * the local row would win a first sync it has no claim to.
 */
export function snapshotFromLocal(local: LocalFields): SnapshotFields {
  return {
    title: local.title,
    body: local.body,
    status: toRemote(local.status),
    labels: [...local.labels],
    assignee: local.assignee,
  };
}

const ConflictEntrySchema = z.object({
  localValue: z.unknown(),
  remoteValue: z.unknown(),
  at: z.string(),
});

const LocalConflictSchema = z.object({
  conflicts: z.record(z.string(), ConflictEntrySchema),
  labelRemoveWins: z.array(z.string()),
});

/**
 * `Task.localConflict`: everything a merge dropped that a human still has to be
 * shown.
 *
 * Two different losses share the column because only one column exists. Scalar
 * `conflicts` are the "remote wins, we keep your edit" promise, and they are
 * what raises `syncState='conflict'`. `labelRemoveWins` is data-loss-shaped
 * without being a conflict — remove-always-wins is the correct algorithm and
 * still drops an element the other side was holding — so it is recorded for the
 * UI marker and deliberately does *not* move `syncState`.
 */
export type LocalConflictBlob = z.infer<typeof LocalConflictSchema>;

export function parseLocalConflict(value: unknown): LocalConflictBlob {
  const parsed = LocalConflictSchema.safeParse(value);
  return parsed.success ? parsed.data : { conflicts: {}, labelRemoveWins: [] };
}

export function isEmptyLocalConflict(blob: LocalConflictBlob): boolean {
  return Object.keys(blob.conflicts).length === 0 && blob.labelRemoveWins.length === 0;
}

/**
 * Fold a merge's losses into what the task already carried.
 *
 * Accumulating rather than overwriting is the plan's rule: a second conflict on
 * an already-conflicted task must not erase the first, or the second import in a
 * row silently completes the data loss the column exists to prevent. Nothing
 * here ever clears the blob: the only exit is a human adjudicating one field
 * through `resolveTaskConflict`, which is what keeps a clean delivery from
 * downgrading an unresolved row to `synced`.
 */
export function foldLocalConflict(
  existing: LocalConflictBlob,
  incoming: { conflicts: { field: string; localValue: unknown; remoteValue: unknown }[]; labelRemoveWins: string[] },
  at: Date
): LocalConflictBlob {
  const conflicts = { ...existing.conflicts };
  for (const conflict of incoming.conflicts) {
    conflicts[conflict.field] = {
      localValue: conflict.localValue,
      remoteValue: conflict.remoteValue,
      at: at.toISOString(),
    };
  }
  const labelRemoveWins = [...new Set([...existing.labelRemoveWins, ...incoming.labelRemoveWins])];
  return { conflicts, labelRemoveWins: labelRemoveWins.sort() };
}
