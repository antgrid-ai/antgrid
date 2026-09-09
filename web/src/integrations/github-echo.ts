import { createHash } from "node:crypto";
import type { GithubIssue } from "./github-events.js";
import { githubAssignees, githubStateReason } from "./github-import.js";

/**
 * Echo suppression: the one hash both halves of the seam key on.
 *
 * The outbox hashes a push RESPONSE into `Task.pushedHash`; the webhook drain
 * hashes the issue a delivery carries and drops the delivery when the two are
 * equal. **One function, imported by both**, because two spellings of "the
 * normalized field set" would disagree on exactly the fields GitHub normalizes,
 * which is the whole population this mechanism is for.
 *
 * **Why the response and not the request.** GitHub normalizes what it stores —
 * line endings in a body, label order, a `state_reason` on an issue that stayed
 * open. Hashing what we *sent* means our own echo arrives with a different hash,
 * is classified as a third party's edit, and is merged against a base that
 * already equals it. Harmless, and also the same as not having the suppression
 * at all, since it would never fire on the fields most likely to be normalized.
 * Hashing the response also costs nothing extra: the response is already what
 * gets stored as the new `remoteSnapshot`.
 *
 * **What it does not do.** It classifies what arrives; it cannot un-clobber. By
 * the time a webhook is classified, a blind PATCH has already overwritten
 * whatever a human wrote a second earlier. The guard for that is the re-fetch
 * immediately before the push, aborting to a merge when `remote != base`. The
 * two are complements: without the re-fetch we destroy the edit, without the
 * hash we raise a conflict against our own write. Ship both or neither.
 *
 * Provider space by construction, because both inputs are GitHub payloads for
 * one issue. That is also why nothing here *normalizes* beyond canonicalizing
 * order: the two sides are already the same provider's rendering of the same
 * object, so the job is to compare them stably rather than to reconcile two
 * vocabularies.
 */

/**
 * Tags the field set the hash was taken over.
 *
 * A future field joining or leaving the set changes what "equal" means, and an
 * untagged hash would silently compare a new-shape delivery against an old-shape
 * stored value — reading as "not our echo", which is the safe direction, but for
 * a reason nobody could see. Bump it whenever `echoFields` changes.
 */
const ECHO_HASH_VERSION = "v1";

/**
 * The canonical field set. Only fields a merge would move: identity (`id`,
 * `number`) is deliberately absent, because `pushedHash` already lives on the
 * one task row that names the issue.
 */
function echoFields(issue: GithubIssue): unknown {
  const state = issue.state;
  return {
    v: ECHO_HASH_VERSION,
    title: issue.title,
    // GitHub stores CRLF from some clients and LF from others for the same
    // visible text; folding here keeps a body that only changed line endings
    // from reading as a third party's edit.
    body: (issue.body ?? "").replace(/\r\n/g, "\n"),
    state,
    // Ignored while the issue is open, for the reason `sameRemoteState` ignores
    // it: GitHub stamps `reopened` there and we never send one, so including it
    // would make a reopened issue's echo differ from the response it came from.
    stateReason: state === "closed" ? githubStateReason(issue.state_reason) : null,
    // Sorted and deduplicated: the PATCH response and the webhook payload order
    // an issue's labels independently, and a set that compares by order is a
    // suppression that never fires.
    labels: [...new Set((issue.labels ?? []).map((label) => label.name))].sort(),
    // Raw provider ids rather than resolved `Assignee` values. The resolution is
    // a database lookup whose answer can differ between the two sides for one
    // person — a member who linked their GitHub account between the push and the
    // webhook — and the hash must not depend on anything but the payload.
    // Present at all so that a delivery which moved ONLY the assignee is merged
    // rather than dropped as our echo.
    assignees: githubAssignees(issue)
      .map((user) => user.externalUserId)
      .sort(),
  };
}

export function githubIssueEchoHash(issue: GithubIssue): string {
  return createHash("sha256").update(JSON.stringify(echoFields(issue))).digest("hex");
}

/**
 * Whether a delivery is the echo of our own last push.
 *
 * A hash equal by coincidence — a human retyping exactly what we pushed — is
 * suppressed, and that is correct: the two states are identical, so there is
 * nothing left to merge.
 */
export function isOwnEcho(pushedHash: string | null, issue: GithubIssue): boolean {
  return pushedHash !== null && pushedHash === githubIssueEchoHash(issue);
}
