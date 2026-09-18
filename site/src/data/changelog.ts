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

/**
 * What kind of change a line is. Four, deliberately: almost everyone scanning
 * this page is looking for the thing that bit them, and a longer vocabulary
 * spreads that over three words which all mean `fixed`.
 *
 * `security` is the one that has to stay scarce. It names the account and
 * access boundary — who may reach this machine, what a signed-out session can
 * still see, an address built to be misread. Not anything that merely touches
 * the crypto path: spend it on a cipher's throughput and it stops meaning
 * anything, and the reader who most needs it learns to skip it.
 */
export const KIND_LABEL = {
  new: "New",
  changed: "Changed",
  fixed: "Fixed",
  security: "Security",
} as const;

export type Kind = keyof typeof KIND_LABEL;

/**
 * One change and the kind it is. A tuple rather than an object because these
 * are written and read as prose: `["fixed", "…"]` keeps a change on one line of
 * the file, where `{ kind: "fixed", text: "…" }` wraps every one of them and the
 * file stops reading like writing.
 */
export type Change = [Kind, string];

export type Note = {
  /** Optional. Only worth setting when a release has a through-line a reader
   *  would recognise; most do not, and a manufactured headline on a routine
   *  build is worse than none. */
  title?: string;
  /** One entry per change worth a stranger's attention. Not one per PR — most
   *  releases carry several nobody outside the repo can act on.
   *
   *  The order is editorial and the page renders it as written: the line a
   *  release leads with is the one someone judged worth leading with. Sorting
   *  these into kind order would put "And this page." above Modelwatch. */
  lines: Change[];
};

/**
 * Hand-written notes, keyed by tag. Add a key, write the lines, done.
 *
 * A key that matches no release is surfaced by {@link ORPHAN_NOTES} and pinned
 * by changelog.spec.ts rather than being silently dropped at build time — a
 * typo'd tag would otherwise cost someone their writing with no error anywhere.
 */
export const NOTES: Record<string, Note> = {
  "v1.20714.1022": {
    lines: [
      ["changed", "Handler's backlog is much easier to read. Items are numbered rather than labelled with a status word most of them share, so a dependency can point at the one it's waiting on, and the sheet no longer says your sentence twice in two voices."],
      ["changed", "The bar above the prompt says what Handler is actually doing, and the lens row is legible."],
      ["fixed", "Switching sessions no longer resizes the agent terminal in front of you. It used to open at the previous session's width and correct itself a frame later. Pane dividers belong to their session too, so dragging one doesn't move it everywhere else."],
      ["new", "The site has a blog, for the things that need more room than a release note."],
    ],
  },
  "v1.20713.1021": {
    lines: [
      ["changed", "Antgrid's source is MPL-2.0. The relay and the web service stay Elastic 2.0; everything else, including the wire format and the Dart relay client, is MPL now."],
      ["fixed", "Remote sessions were timing out with nothing on the wire to explain it. A frame the checkout gate refused was dropped in silence, so the app waited for an answer that was never coming. Every refusal is answered now."],
      ["fixed", "A burst of output that outran the terminal used to cost you the display for the rest of the run. It costs you the burst instead, and the app tells you what it dropped."],
      ["fixed", "Handler was judging on far less than it thought. It asks for twenty messages of context and was usually getting one. It reads a wide enough window now, and the activity pane shows the history from before you opened it."],
      ["new", "You can write your own lens when you arm Handler instead of picking one of ours."],
      ["security", "The remote-access switch is inbound only, which is what its name and its own wording have always promised. It governs what can be done to this machine, so with it off your agents here can still open an exchange with another machine and get a reply. Nothing unsolicited gets in."],
      ["fixed", "Switching sessions while a side pane is moving no longer hard-wraps the agent's output."],
    ],
  },
  "v1.20711.1020": {
    lines: [
      ["changed", "Support for each coding agent moved into a package of its own. Nothing changes about the agents we ship; it's the groundwork for adding one without touching the bridge."],
    ],
  },
  "v1.20710.1017": {
    title: "The terminal, over a remote link",
    lines: [
      ["changed", "The terminal works differently at a distance. Rather than streaming every byte to your phone, the bridge keeps the real screen and sends pictures of it, up to twenty a second. Scrollback stays on the machine and pages in as you scroll."],
      ["changed", "It's a coordinated change with no fallback, so an app or a bridge too old to speak it asks to be updated rather than half working."],
    ],
  },
  "v1.20710.1016": {
    lines: [
      ["new", "There's live chat on the site, in your account and in the app. Nothing is requested from the chat provider until you click the launcher, so it costs nothing on a page you never chat from."],
      ["fixed", "We were pushing terminal output at apps with nothing listening for it, indefinitely. One link measured 17,000 dropped frames in 24 minutes. It stops when the listener goes."],
      ["changed", "Analytics moved to an Umami instance we host ourselves. It's cookieless and first-party, and the privacy notice says so."],
    ],
  },
  "v1.20706.1015": {
    lines: [
      ["new", "Modelwatch. The bridge spawns model calls on your own provider account to name sessions and to run Handler's judge, and until now they were invisible: they spent your money and left no record of what ran or on which model. Now there's a record of every one."],
      ["security", "Signing out signs you out. Account state was surviving in a cache for the life of the process, and a machine that had left the account was still listed."],
      ["changed", "Windows opens relay frames with the operating system's own AES-GCM. The pure Dart cipher it fell back to ran at around 12 MB/s on the UI thread, which a busy terminal or a tunnelled preview paid for directly."],
      ["fixed", "An isolated Codex session could refuse to open, printing “Resuming session…” and exiting a couple of seconds later. It was trying to resume a helper thread that was never a session."],
      ["fixed", "On Windows a session action could fail outright because a virus scanner or the search indexer had one of our files open for a moment. We wait it out."],
      ["new", "And this page."],
    ],
  },
  "v1.20705.1014": {
    lines: [
      ["fixed", "Opening a remote session could land you on a frozen agent terminal with nothing saying why. The pane couldn't tell “there are no terminals” from “the terminals haven't attached yet”, and some of the waits had nothing behind them that could ever end."],
      ["fixed", "We were pushing megabytes of file tree at connected apps. A 224 second capture against one remote session measured 4.6 MB, more than half of it tree snapshots. That's bounded now, and the app can report a stall of its own rather than leaving it visible only from the other end."],
      ["fixed", "Fixed a Windows bug that could leave Ctrl stuck down after a paste."],
      ["fixed", "Image previews open where they were opened from, and a narrow pane stops overflowing."],
    ],
  },
  "v1.20705.1013": {
    lines: [
      ["fixed", "An opened folder resolves to the project that owns it, so one repository can't appear twice under two identities."],
      ["changed", "File tree state is pulled by the app when it wants it instead of being pushed at it on every reconnect."],
    ],
  },
  "v1.20704.1012": {
    lines: [
      ["fixed", "Remote sessions were timing out on large repositories. We sent the whole file tree the moment you connected, which swamped the link before anything else could get through. The tree is paced now and the preview tunnel streams."],
      ["fixed", "Resuming a session keeps what it had, and Codex approval alerts don't fire before the agent has actually asked for anything."],
      ["fixed", "Fixed a file tree bug where the selection could point at the wrong row after a refresh."],
      ["changed", "Tidied up the annotation panel in the browser preview."],
    ],
  },
  "v1.20702.1011": {
    lines: [
      ["new", "Downloads have a page of their own now. It also stopped handing a Windows installer to anyone reading on a phone."],
      ["changed", "We stopped polling git for sessions nobody is watching."],
    ],
  },
  "v1.20700.1010": {
    lines: [
      ["new", "Tapping a push notification opens the session it's about."],
      ["fixed", "Live reload works in the browser preview again. We weren't forwarding the HMR subprotocol, so the socket never came up."],
    ],
  },
  "v1.20699.1009": {
    title: "Handler grows up",
    lines: [
      ["changed", "Handler belongs to the session now rather than the machine, and when it refuses to arm it tells you why."],
      ["changed", "It asks the agent before answering on your behalf, and it confirms any undo that would leave your machine."],
      ["changed", "Notify-only is retired. Handler acts, and the wrap-up it writes survives a restart."],
      ["new", "Markdown files open in a real viewer, with a heading outline and links that go where they say."],
      ["new", "The git panel gained commit history, pull and push."],
    ],
  },
  "v1.20697.1006": {
    lines: [
      ["fixed", "The relay's heartbeat and recovery are harder to knock over."],
      ["changed", "Handler's backlog dialog is easier to work with."],
    ],
  },
  "v1.20696.1005": {
    lines: [
      ["new", "Approval policy is set per session, so you can let one session skip prompts without touching the others."],
      ["changed", "Workspace context is scoped to the session it belongs to."],
    ],
  },
  "v1.20695.1004": {
    lines: [
      ["new", "Point at anything in the browser preview and draw on it to leave the agent feedback."],
      ["fixed", "Isolated sessions were becoming permanently undeletable. A coding agent's helpers outlive the terminal that started them and keep hold of the checkout, so git couldn't remove it. A terminal takes its orphans with it now."],
      ["fixed", "Coding agents get to shut down properly. Every teardown path killed an agent's terminal outright, which is why Claude Code kept announcing that its renderer hadn't finished starting last time."],
      ["fixed", "Coming back to a session shows you the screen as it stands rather than the tail of a stream you missed the start of. Files and preview recover the same way."],
      ["fixed", "A session keeps the title we generated for it across a restart."],
    ],
  },
  "v1.20693.1003": {
    lines: [
      ["fixed", "Push notifications work on Android. They never had: the Firebase config the build needs was ignored by git and had never shipped."],
      ["new", "Fork a session, into a workspace cut from where it got to or into the one it's already using, and carry the conversation over."],
      ["new", "Two-finger scroll works in the terminal on a laptop trackpad."],
      ["fixed", "Handler reports what it couldn't send instead of calling the work done. Traced from a real session where it sat armed all morning, sent the agent nothing, and wrote a wrap-up anyway."],
      ["fixed", "Pressing left twice at a Claude prompt hands the conversation to Claude's own background supervisor and takes the terminal with it. We don't follow it there."],
      ["fixed", "Updating on Windows brings the app back afterwards, shuts the bridge down rather than having it killed mid-install, and reports what the Store actually did instead of calling every outcome a success."],
    ],
  },
  "v1.20692.1002": {
    lines: [
      ["changed", "Sessions are named for what they're about rather than for the first thing you typed."],
      ["fixed", "Tapping a remote session opens that session, not whichever one the cache happened to list first."],
      ["fixed", "Links in the terminal open on a plain click. A full-screen agent takes the mouse before it prints anything, which is why they didn't."],
      ["security", "You can see where a link goes before you follow it, and we ask first when the address is built to be misread."],
      ["fixed", "The projects drawer indents. Every level used to start at the same place, so a three-level tree rendered flat."],
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

/**
 * One day of the cadence strip on /changelog.
 *
 * The window runs from the oldest release the page shows to the NEWEST, not to
 * today. Anchored to the clock the axis would be redrawn on every deploy, and
 * two builds of an unchanged file would disagree — the same hazard formatDate's
 * UTC lock exists for. Nothing is hidden by that choice: a long silence since
 * the last build is still legible, it is just read off the newest date rather
 * than drawn as a run of empty ticks.
 */
export type StripDay = {
  /** `YYYY-MM-DD`, UTC. */
  date: string;
  /** What shipped that day, newest first. Empty on a day nothing did. */
  releases: Release[];
};

const DAY_MS = 86_400_000;

/**
 * Longest axis worth drawing. The strip fills the measure whatever it holds, so
 * past roughly this a tick is thinner than the gap beside it and the run of
 * marks stops resolving as anything.
 */
export const STRIP_DAYS = 90;

/**
 * The shipping record as one tick per day. Days are derived rather than taken
 * from the releases themselves because the gaps are the whole point — a list of
 * release dates says the same thing a list of releases already says.
 */
export const releaseStrip = (entries: Entry[] = ENTRIES): StripDay[] => {
  if (entries.length === 0) return [];
  // Min/max rather than first/last: the generated spine is sorted newest-first,
  // but nothing here should break quietly if that ever stops being true.
  const at = (entry: Entry) => Date.parse(`${entry.date}T00:00:00Z`);
  const newest = Math.max(...entries.map(at));
  const start = Math.max(Math.min(...entries.map(at)), newest - (STRIP_DAYS - 1) * DAY_MS);

  const days: StripDay[] = [];
  for (let ms = start; ms <= newest; ms += DAY_MS) {
    const date = new Date(ms).toISOString().slice(0, 10);
    days.push({ date, releases: entries.filter((entry) => entry.date === date) });
  }
  return days;
};
