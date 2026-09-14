// The changelog's human half. `changelog-releases.ts` beside this file is the
// machine half — tag, date, URL, one maintenance flag — rewritten wholesale by
// scripts/sync-changelog.mjs on every run. Nothing in THIS file is ever written
// by a script, and nothing in that one is ever written by hand.
//
// Register is Human (brand: support replies, outreach, changelog, blog). "We",
// contractions, British spelling, no em dashes. A release note is one person
// telling another what changed and, where it helps, what was wrong before. It
// is not a PR title with the prefix filed off: the generated notes on GitHub
// already carry those, this page exists because they are unreadable to anyone
// who did not write them.
//
// Not every release needs notes. Three states render, and all three are honest:
//
//   1. A release with a NOTES entry renders the prose.
//   2. A release the tooling marked `maintenance` says so in one line. These
//      are builds where the release itself declared no user-facing change, so
//      writing prose for one would be inventing a change that did not happen.
//   3. Anything else renders as version, date and a link to the full generated
//      notes. Deliberately NOT a "no notes yet" placeholder: a page that ships
//      its own TODOs reads as abandoned, and the link is a real answer rather
//      than an apology. Backfilling one later is adding a key here, nothing else.
//
// So the page is complete the moment a release exists, and gets better when
// someone has ten minutes. That is the whole point of the split.
import { RELEASES } from "./changelog-releases";

/** One published release, exactly as sync-changelog.mjs recorded it. */
export type Release = {
  /** The git tag, verbatim. */
  version: string;
  /** `YYYY-MM-DD`, UTC. */
  date: string;
  /** The GitHub release page, which carries the full generated PR list. */
  url: string;
  /** The release declared no user-facing change. */
  maintenance: boolean;
};

export type Note = {
  /** Optional. Only worth setting when a release has a through-line a reader
   *  would recognise; most do not, and a manufactured headline on a routine
   *  build is worse than none. */
  title?: string;
  /** One entry per change worth a stranger's attention. Not one per PR — most
   *  releases carry several nobody outside the repo can act on. */
  lines: string[];
};

/**
 * Hand-written notes, keyed by tag. Add a key, write the lines, done.
 *
 * A key that matches no release is surfaced by {@link ORPHAN_NOTES} and pinned
 * by changelog.spec.ts rather than being silently dropped at build time — a
 * typo'd tag would otherwise cost someone their writing with no error anywhere.
 */
export const NOTES: Record<string, Note> = {
  "v1.20704.1012": {
    lines: [
      "Remote sessions were timing out on large repositories. We sent the whole file tree the moment you connected, which swamped the link before anything else could get through. The tree is paced now and the preview tunnel streams.",
      "Resuming a session keeps what it had, and Codex approval alerts don't fire before the agent has actually asked for anything.",
      "Fixed a file tree bug where the selection could point at the wrong row after a refresh.",
      "Tidied up the annotation panel in the browser preview.",
    ],
  },
  "v1.20702.1011": {
    lines: [
      "Downloads have a page of their own now. It also stopped handing a Windows installer to anyone reading on a phone.",
      "We stopped polling git for sessions nobody is watching.",
    ],
  },
  "v1.20700.1010": {
    lines: [
      "Tapping a push notification opens the session it's about.",
      "Live reload works in the browser preview again. We weren't forwarding the HMR subprotocol, so the socket never came up.",
    ],
  },
  "v1.20699.1009": {
    title: "Handler grows up",
    lines: [
      "Handler belongs to the session now rather than the machine, and when it refuses to arm it tells you why.",
      "It asks the agent before answering on your behalf, and it confirms any undo that would leave your machine.",
      "Notify-only is retired. Handler acts, and the wrap-up it writes survives a restart.",
      "Markdown files open in a real viewer, with a heading outline and links that go where they say.",
      "The git panel gained commit history, pull and push.",
    ],
  },
  "v1.20697.1006": {
    lines: [
      "The relay's heartbeat and recovery are harder to knock over.",
      "Handler's backlog dialog is easier to work with.",
    ],
  },
  "v1.20696.1005": {
    lines: [
      "Approval policy is set per session, so you can let one session skip prompts without touching the others.",
      "Workspace context is scoped to the session it belongs to.",
    ],
  },
};

/** A release plus its notes, if anyone has written any. */
export type Entry = Release & { note?: Note };

/** Newest first, as sync-changelog.mjs sorted them. */
export const ENTRIES: Entry[] = RELEASES.map((release) => ({
  ...release,
  note: NOTES[release.version],
}));

/**
 * Note keys matching no published release. Always empty in a healthy tree: a
 * non-empty list means either a tag was typo'd here or a release was deleted
 * upstream, and both lose prose that someone sat down and wrote.
 */
export const ORPHAN_NOTES = Object.keys(NOTES).filter(
  (version) => !ENTRIES.some((entry) => entry.version === version),
);

/**
 * "8 September 2026". Forced to UTC because the stored date is UTC: left to the
 * runner's zone a build in the Americas renders every release a day early, and
 * two CI runs of an unchanged file would disagree.
 */
export const formatDate = (date: string): string =>
  new Date(`${date}T00:00:00Z`).toLocaleDateString("en-GB", {
    day: "numeric",
    month: "long",
    year: "numeric",
    timeZone: "UTC",
  });
