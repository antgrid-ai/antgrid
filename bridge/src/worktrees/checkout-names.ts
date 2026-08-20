import { createHash } from "node:crypto";
import { basename } from "node:path";

/** Every character of a managed checkout's path is one the worktree's own
 * deepest file cannot have: Windows still resolves most APIs against a 260-char
 * MAX_PATH, and a JS project's `node_modules` spends well over half of that on
 * its own. Both caps below, and the ≤7-character words, exist to bound
 * `wt/<project>/<checkout>` at 45 characters however long the repository folder
 * and session name are. */
const REPO_SLUG_MAX = 16;

/** The readable half of a branch name. The rest of the ref is `antgrid/` plus a
 * word pair, so this is what bounds it. */
const BRANCH_SLUG_MAX = 32;

/** Derived from the projectId rather than random, so the same folder always
 * lands in the same directory across bridge restarts and reinstalls — nothing
 * has to persist the mapping. Four characters, not two: two repositories that
 * share a folder name (a second clone of the same repo is the ordinary case)
 * then collide at 1-in-65536 instead of 1-in-256, and a collision is permanent
 * for that machine rather than a one-off. It is a discount, not the fix — the
 * ownership checks in `checkout-owner.ts` are what make a shared root harmless.
 */
const PROJECT_SUFFIX_LEN = 4;

/** Guards the one collision the word pair cannot: two sessions created from the
 * same seed. Taken from the END of the checkout id because injected test
 * generators vary in their last characters, not their first. */
const CHECKOUT_SUFFIX_LEN = 4;

/** Deliberately meaningless, and deliberately not the session name. A directory
 * name is chosen once and can never follow a rename, so a name-derived one goes
 * stale the first time the user retitles a session; a word pair is stable,
 * survives a session named in any script or named nothing at all, and is short
 * enough to bound the path. Two lists of 64 give 4096 pairs before the checkout
 * suffix is what separates them. */
const ADJECTIVES = [
  "amber", "arctic", "bold", "brave", "brief", "bright", "calm", "candid",
  "civic", "clear", "clever", "coral", "cosmic", "crisp", "curious", "daring",
  "deep", "eager", "early", "easy", "fair", "fancy", "fast", "fine",
  "firm", "fluent", "fresh", "gentle", "giddy", "glad", "golden", "grand",
  "green", "happy", "hardy", "humble", "ideal", "jolly", "keen", "kind",
  "lively", "loyal", "lucid", "lucky", "mellow", "merry", "mighty", "mild",
  "modest", "neat", "noble", "polite", "proud", "quick", "quiet", "rapid",
  "royal", "sharp", "silent", "smart", "solid", "steady", "sunny", "swift",
] as const;

const NOUNS = [
  "acorn", "anchor", "arbor", "atlas", "basin", "beacon", "birch", "bishop",
  "bloom", "brook", "canopy", "canyon", "cedar", "cinder", "cobalt", "comet",
  "coral", "cove", "crater", "crest", "delta", "dune", "ember", "fable",
  "falcon", "fern", "fjord", "flint", "forge", "fossil", "garnet", "geode",
  "glade", "granite", "harbor", "haven", "heron", "hollow", "indigo", "island",
  "jasper", "jetty", "kelp", "lagoon", "lantern", "ledger", "lichen", "maple",
  "marble", "meadow", "mesa", "onyx", "orchid", "otter", "pebble", "pine",
  "quarry", "quartz", "ridge", "river", "sable", "summit", "thicket", "willow",
] as const;

function digest(seed: string): Buffer {
  return createHash("sha256").update(seed).digest();
}

/** Lowercase, ASCII, and free of every character a path segment may not carry.
 * Windows reserved device names (`con`, `aux`, `nul`, `com1`, …) need no
 * special case: callers always append a `-<suffix>`, and a reserved name is
 * only reserved when it is the WHOLE stem. */
function slug(value: string, max: number): string {
  return value
    .trim().toLowerCase()
    .replace(/[^a-z0-9._-]+/g, "-")
    .replace(/^[.\-]+|[.\-]+$/g, "")
    .slice(0, max)
    .replace(/[.\-]+$/, "");
}

/** The per-project directory under the worktree root. Readable first — this is
 * the segment a user scanning `~/.antgrid/wt` has to recognise — but never the
 * authority on where a checkout lives: it cannot be recomputed once the
 * repository folder is gone, so removal paths read `CheckoutRecord.path`. */
export function projectRootName(repoPath: string, projectId: string): string {
  const label = slug(basename(repoPath), REPO_SLUG_MAX) || "project";
  // Slugged, not sliced raw: a projectId reaching this from a client is already
  // gated by `isSafeProjectId`, but a two-character slice of an ungated one can
  // be `..`, and Win32 silently rewrites a segment ending in a dot.
  const suffix = slug(projectId.slice(0, PROJECT_SUFFIX_LEN), PROJECT_SUFFIX_LEN);
  return suffix ? `${label}-${suffix}` : label;
}

/** The word pair a session is known by, in its directory and in its branch
 * alike — the only thing that ties the two together once the directory stopped
 * being named after the session. */
export function sessionWords(seed: string): string {
  const bytes = digest(seed);
  const adjective = ADJECTIVES[bytes.readUInt16BE(0) % ADJECTIVES.length]!;
  const noun = NOUNS[bytes.readUInt16BE(2) % NOUNS.length]!;
  return `${adjective}-${noun}`;
}

/** The per-checkout directory: the session's word pair, so the same session
 * always reads the same way in a prompt, a terminal title and
 * `git worktree list`. */
export function checkoutDirName(seed: string | undefined, checkoutId: string): string {
  const words = sessionWords(seed && seed.length > 0 ? seed : checkoutId);
  const suffix = slug(checkoutId.slice(-CHECKOUT_SUFFIX_LEN), CHECKOUT_SUFFIX_LEN);
  return suffix ? `${words}-${suffix}` : words;
}

/** The session name as it may appear in a branch. Letters, digits and hyphens
 * only: a dot buys nothing a hyphen does not, and it brings `..`, a leading `.`
 * and a trailing `.lock` — three separate ways to spell a name Git refuses.
 * Capped well under Git's limits because the ref is also a FILE under
 * `.git/refs/heads/` in a repository already nested however deep the user put
 * it. Empty is a legitimate answer: a name written entirely in a script this
 * function cannot transliterate should leave the branch to the word pair rather
 * than pad it with a meaningless `session`. */
export function branchSlug(name: string | undefined): string {
  return slug((name ?? "").replace(/[^\p{L}\p{N}]+/gu, "-"), BRANCH_SLUG_MAX);
}
