// The asking half of the remote directory: an expiring mirror of what the
// app's pump last learned by peeking peer capability cards. This machine
// cannot dial another bridge, so the mirror is only ever as fresh as the
// app's last push — nothing here refreshes itself, and a repository nobody
// has read through `view()` simply never gets asked for again.
//
// `directory.ts` imports from here, never the reverse — this module owns the
// reach vocabulary (`ReachMachine`, `ReachMachineStatus`) and its own row
// shape rather than importing `SessionDirectoryRow`, so the edge runs one way.
//
// Ingest is the one place a peer's session title, branch, id and label reach
// this process, and they are HOSTILE INPUT: an MCP tool renders a row into an
// agent's context, where a stray control character or line separator would
// forge a fresh directory line. `sanitizeRow` is what stands between the wire
// and that render, and it runs on every row this cache is ever handed — there
// is no second path in.

import { z } from "zod";
import { isSafeProjectId } from "../project-id";
import { WorkStatusSchema } from "../protocol";
import { MAX_DIRECTORY_REPO_KEYS, MAX_MACHINE_CARD_ROWS, MAX_REMOTE_DIRECTORY_MACHINES, REMOTE_ROWS_TTL_MS } from "./constants";

/** One session on a peer's capability card, as it travels the wire. Mirrors
 *  `MachineDirectoryRow` (`directory.ts`) field for field; the caps here are
 *  what keep a peer's free-text fields from becoming an unbounded prompt on
 *  this machine's agents. The wire schema does NOT apply this — see
 *  {@link RemoteDirectoryMachinePush.rows} — so this is the only place a
 *  pushed row is actually checked. */
export const RemoteDirectoryRowSchema = z.object({
  repoKey: z.string().min(1).max(512),
  projectId: z.string().min(1).max(200),
  projectLabel: z.string().max(120).optional(),
  sessionId: z.string().min(1).max(200),
  title: z.string().max(200),
  branch: z.string().max(200).nullable(),
  activity: z.enum(["running", "idle", "stopped"]),
  workStatus: WorkStatusSchema.optional(),
  lastActiveAt: z.number().int().nonnegative(),
  canReply: z.boolean(),
});
export type RemoteDirectoryRow = z.infer<typeof RemoteDirectoryRowSchema>;

// C0/C1 controls (covers DEL 0x7F and NEL U+0085), Unicode format characters
// (covers the bidi override marks a peer could use to reorder a rendered
// title), and the LINE SEPARATOR / PARAGRAPH SEPARATOR code points U+2028 and
// U+2029, which most renderers treat as a line break exactly like \n -- every
// character class a peer could use to forge a second directory line, not
// just the ASCII newlines a narrower control-character sweep would catch.
const HOSTILE_CHARS = /[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]/gu;

function stripHostile(s: string): string {
  return s.replace(HOSTILE_CHARS, "");
}

/**
 * The one gate every pushed row passes through before it can be shown to an
 * agent. Rejects outright on an unsafe `projectId` — the same allowlist that
 * guards every phone-supplied id that becomes a filesystem path, because
 * nothing downstream of this cache re-checks it — and on a `sessionId`
 * carrying a hostile character: `addressesSameSession` matches on
 * `machineId` + `sessionId` alone, so an address is not a field it is safe to
 * clean, only to accept or refuse. Every other human-readable field is
 * cleaned rather than rejected: a scrubbed title is still a usable row, and
 * failing the whole push over one hostile field would cost the peer's honest
 * sessions too.
 */
export function sanitizeRow(row: RemoteDirectoryRow): RemoteDirectoryRow | null {
  if (!isSafeProjectId(row.projectId)) return null;
  if (stripHostile(row.sessionId) !== row.sessionId) return null;
  return {
    ...row,
    title: stripHostile(row.title),
    branch: row.branch === null ? null : stripHostile(row.branch),
    ...(row.projectLabel === undefined ? {} : { projectLabel: stripHostile(row.projectLabel) }),
  };
}

/** What the pushing app classified one machine as, this cycle. `"rows"` means a
 *  card came back (however many sessions it held, including zero) — {@link
 *  RemoteDirectoryCache.view} renders it as `"answered"`; the other four travel
 *  unchanged into {@link ReachMachineStatus}.
 *
 *  `"refused"` and `"reach-refused"` are kept apart all the way to the agent's
 *  reach line because they name DIFFERENT switches on the peer, and a line that
 *  names the wrong one sends the user to a setting that is already on. */
export type RemoteMachineOutcome = "rows" | "no-card" | "refused" | "reach-refused" | "unreachable";

/** One machine's report, as the loopback ingest verb
 *  (`session-bus:remote-directory`) hands it to {@link
 *  RemoteDirectoryCache.replace}. `rows` is `unknown[]`, not {@link
 *  RemoteDirectoryRow}`[]`, ON PURPOSE: the wire schema (`control-protocol.ts`)
 *  deliberately does not validate row shape, because a caller whose schema
 *  gate rejects the whole request over one hostile field turns a single long
 *  session title anywhere in the account into a push that always 400s — this
 *  is the only place a row is checked, and it drops that row alone. */
export interface RemoteDirectoryMachinePush {
  machineId: string;
  machineLabel?: string;
  /** When the APP captured this machine's card — not when this bridge ingested
   *  it. A machine under backoff can ride several pushes on one old card, and
   *  this is the clock {@link REMOTE_ROWS_TTL_MS} reads. */
  observedAt: number;
  outcome: RemoteMachineOutcome;
  rows: readonly unknown[];
  /** What the FAR bridge's own `MAX_MACHINE_CARD_ROWS` cap dropped, so
   *  `view()` can sum it into an honest `truncated` rather than the mirror
   *  quietly narrowing a card that was already narrowed once. */
  truncated: number;
}

export interface RemoteDirectoryReplaceResult {
  /** Rows now held in the mirror, across every machine this push named. */
  accepted: number;
  /** Rows this push named but the mirror refused — a self-machine's whole
   *  count, a machine sliced off past {@link MAX_REMOTE_DIRECTORY_MACHINES},
   *  any row past {@link MAX_MACHINE_CARD_ROWS}, and any row that failed the
   *  schema or {@link sanitizeRow}. */
  dropped: number;
  /** Reads this cache could not serve since the LAST push (or since
   *  construction/`clear()`), drained by this call — the ack's signal that
   *  the pump should stop waiting for the heartbeat and push sooner. A
   *  monotonic counter here would latch the pump into its fast tick forever,
   *  since the very first read on a cold cache is always unserved. */
  unservedReads: number;
}

export type ReachMachineStatus = "answered" | "no-card" | "refused" | "reach-refused" | "unreachable";

/** One line of the reach report `directory.ts` renders beside the merged rows
 *  — never the rows themselves, which is why `rows` here is a COUNT. */
export interface ReachMachine {
  machineId: string;
  machineLabel?: string;
  status: ReachMachineStatus;
  /** Sessions this machine contributed to the repo `view()` was asked about —
   *  not its whole card, which can span repos this read does not care about.
   *  `0` while the entry's rows have expired past {@link REMOTE_ROWS_TTL_MS},
   *  even though the machine itself is still named below. */
  rows: number;
  /** Rows this push named for this machine that the mirror refused (schema
   *  failure, `sanitizeRow`, or the per-machine row cap) — so a machine whose
   *  card failed to ingest reads as "12 rows refused", never as a peer with
   *  nothing running. */
  droppedRows: number;
  /** The far side's own `MAX_MACHINE_CARD_ROWS` cap, reported once per
   *  machine rather than folded into the repo-scoped `truncated` total below:
   *  that cap is spent across every repo the machine's card covered, not this
   *  one, so attributing it to THIS repo's count would tell a caller rows are
   *  hidden here when they may all belong to a repo it never asked about. */
  truncatedCard: number;
  ageMs: number;
}

/** A mirrored row, stamped with the machine it came from. Field-for-field the
 *  same shape as `directory.ts`'s `SessionDirectoryRow` (see the module
 *  comment for why that is a structural match and not an import) — `machineId`
 *  is never null here, because a row that reached the mirror at all came off
 *  a real peer's card. */
export interface RemoteDirectoryViewRow {
  machineId: string;
  machineLabel?: string;
  projectId: string;
  projectLabel?: string;
  sessionId: string;
  title: string;
  branch: string | null;
  activity: "running" | "idle" | "stopped";
  workStatus?: RemoteDirectoryRow["workStatus"];
  lastActiveAt: number;
  canReply: boolean;
}

export interface RemoteDirectoryView {
  rows: RemoteDirectoryViewRow[];
  /** The far side's own reported truncation, summed across every LIVE
   *  (non-stale) machine — never this cache's own cut, since it makes none.
   *  See {@link ReachMachine.truncatedCard} for why this is a whole-card
   *  number rather than one scoped to the repo this read asked about. */
  truncated: number;
  machines: ReachMachine[];
  /** Machines this cache still holds a row for, but too old to serve — counted
   *  rather than silently excluded, so "nothing pushed lately" and "nothing on
   *  that repo" stay two different answers. */
  staleMachines: number;
  notConnected: number;
  lastPushAt: number | null;
}

interface StoredMachine {
  machineId: string;
  machineLabel?: string;
  observedAt: number;
  outcome: RemoteMachineOutcome;
  rows: RemoteDirectoryRow[];
  truncated: number;
  droppedRows: number;
}

/**
 * The mirror itself: one machine-level, in-memory, no-persistence cache of
 * what the app's pump last reported about the account's other machines.
 *
 * Nothing here dials anything. A machine this cache has never heard of, or has
 * not heard from in {@link REMOTE_ROWS_TTL_MS}, simply contributes no rows —
 * that is `SessionDirectory`'s "honest census", not a bug in this class.
 */
export class RemoteDirectoryCache {
  private machines = new Map<string, StoredMachine>();
  private notConnectedCount = 0;
  private lastPush: number | null = null;
  /** Repo keys a local read has asked about, most-recently-asked last, capped
   *  to {@link MAX_DIRECTORY_REPO_KEYS} — the same bound the ingest verb's
   *  `repoKeys` param carries, because this is what feeds it on the next push. */
  private wanted = new Map<string, number>();
  private unservedCount = 0;
  private lastReadTime: number | null = null;

  /**
   * Replace the whole mirror with one push. A REPLACE, not a merge: the app's
   * pump always sends its complete current candidate set, so a machine
   * missing from this call is a machine the pump no longer has open — it is
   * gone from the mirror on THIS call, not left to expire on its own.
   *
   * `selfMachineId` is this bridge's own relay identity. An entry naming it is
   * dropped whole, every one of its rows counted against `dropped`: a machine
   * must not discover itself through its own app.
   */
  replace(
    machines: readonly RemoteDirectoryMachinePush[],
    notConnected: number,
    selfMachineId: string | null,
    now: number,
  ): RemoteDirectoryReplaceResult {
    const next = new Map<string, StoredMachine>();
    let accepted = 0;
    let dropped = 0;

    const capped = machines.slice(0, MAX_REMOTE_DIRECTORY_MACHINES);
    // A push naming more machines than the product bound is the far side's
    // own account growing, not a malformed request — the wire cap
    // (control-protocol.ts) is a DoS ceiling far above this, so an
    // over-count reaches here to be BOUNDED rather than reject the whole push.
    for (const overflow of machines.slice(MAX_REMOTE_DIRECTORY_MACHINES)) {
      dropped += overflow.rows.length;
    }

    for (const push of capped) {
      const machineId = push.machineId;
      // Refused, never cleaned, for the reason `sanitizeRow` refuses a session
      // id: the two together are the address `addressesSameSession` matches on,
      // so a machine id that survived a strip is either unreachable or now
      // names a DIFFERENT machine, whose entry this push would then replace.
      if (stripHostile(machineId) !== machineId || (selfMachineId !== null && machineId === selfMachineId)) {
        dropped += push.rows.length;
        continue;
      }

      const rows: RemoteDirectoryRow[] = [];
      let entryDropped = 0;
      for (const raw of push.rows.slice(0, MAX_MACHINE_CARD_ROWS)) {
        const parsed = RemoteDirectoryRowSchema.safeParse(raw);
        if (!parsed.success) {
          dropped++;
          entryDropped++;
          continue;
        }
        const sanitized = sanitizeRow(parsed.data);
        if (sanitized === null) {
          dropped++;
          entryDropped++;
          continue;
        }
        rows.push(sanitized);
        accepted++;
      }
      // Rows past the per-machine cap are the far side's own oversend — count
      // them the same as a rejected row so the ack does not under-report what
      // the mirror actually dropped.
      const overRows = Math.max(0, push.rows.length - MAX_MACHINE_CARD_ROWS);
      dropped += overRows;
      entryDropped += overRows;

      next.set(machineId, {
        machineId,
        ...(push.machineLabel === undefined ? {} : { machineLabel: stripHostile(push.machineLabel) }),
        observedAt: push.observedAt,
        outcome: push.outcome,
        rows,
        truncated: Math.max(0, push.truncated),
        droppedRows: entryDropped,
      });
    }

    this.machines = next;
    this.notConnectedCount = Math.max(0, notConnected);
    this.lastPush = now;
    const unservedReads = this.unservedCount;
    this.unservedCount = 0;
    return { accepted, dropped, unservedReads };
  }

  /** Empty the mirror. Called on the loopback gate's refusal path (remote
   *  access turned off, or this machine has no relay identity) so a switch
   *  flipped off takes effect immediately rather than riding out the TTL —
   *  `lastPushAt` goes to null with it, so a read right after reports
   *  `no-carrier` rather than a stale "just pushed, nothing in it". The
   *  unserved-read counter and the wanted-repo-key list are cleared too: both
   *  exist to steer the NEXT push, and there is no next push to steer while
   *  this machine is refusing ingest. */
  clear(_reason: string): void {
    this.machines = new Map();
    this.lastPush = null;
    this.unservedCount = 0;
    this.wanted = new Map();
  }

  /**
   * Every row this mirror currently holds for `repoKey`, plus the reach report
   * that explains what is and is not in it.
   *
   * `selfMachineId` is re-checked here even though {@link replace} already
   * refuses a self-entry at ingest — the same two-independent-points
   * discipline the machine-level switch gets: a caller must not be able to
   * see itself as a peer just because its own id changed between a push and
   * a read.
   *
   * Every row is stamped with the MACHINE ENTRY's own `machineId`/`machineLabel`
   * — never `selfMachineId`, which exists only to exclude, not to label.
   */
  view(repoKey: string, selfMachineId: string | null, now: number): RemoteDirectoryView {
    const rows: RemoteDirectoryViewRow[] = [];
    const machines: ReachMachine[] = [];
    let staleMachines = 0;
    let truncated = 0;
    let liveMachines = 0;

    for (const entry of this.machines.values()) {
      if (selfMachineId !== null && entry.machineId === selfMachineId) continue;

      const ageMs = now - entry.observedAt;
      // A negative age is a card from the future — a clock skew, or a unit
      // slip on the app side (micros where millis were meant) — and trusting
      // it as maximally fresh would make a peer's rows immortal, since ageMs
      // then never crosses the TTL. Treat it the same as too old: a stamp
      // that cannot be trusted is not evidence of anything, least of all
      // liveness.
      const stale = ageMs > REMOTE_ROWS_TTL_MS || ageMs < 0;
      if (stale) staleMachines++;
      else liveMachines++;

      // The machine stays NAMED even when stale — only its rows expire. A
      // refused or unreachable peer's backoff (minutes) outlasts this row TTL
      // (seconds) by design, so dropping the whole entry here would render a
      // permanent, human-actionable refusal as transient staleness on every
      // read between backed-off pushes.
      const matching = stale ? [] : entry.rows.filter((r) => r.repoKey === repoKey);
      for (const r of matching) {
        rows.push({
          machineId: entry.machineId,
          ...(entry.machineLabel === undefined ? {} : { machineLabel: entry.machineLabel }),
          projectId: r.projectId,
          ...(r.projectLabel === undefined ? {} : { projectLabel: r.projectLabel }),
          sessionId: r.sessionId,
          title: r.title,
          branch: r.branch,
          activity: r.activity,
          ...(r.workStatus === undefined ? {} : { workStatus: r.workStatus }),
          lastActiveAt: r.lastActiveAt,
          canReply: r.canReply,
        });
      }

      machines.push({
        machineId: entry.machineId,
        ...(entry.machineLabel === undefined ? {} : { machineLabel: entry.machineLabel }),
        status: entry.outcome === "rows" ? "answered" : entry.outcome,
        rows: matching.length,
        droppedRows: entry.droppedRows,
        truncatedCard: entry.truncated,
        ageMs,
      });
      if (!stale) truncated += entry.truncated;
    }

    // A repo with no matching rows but at least one LIVE machine is an honest
    // empty answer ("nobody else is on it") and counts as served; a read where
    // every known machine is stale (or none is known at all) is one the pump
    // has not caught up on yet — a stale entry stays NAMED above for the
    // agent's sake, but it must not stop this signal from asking the pump to
    // push sooner.
    this.noteRead(rows.length > 0 || liveMachines > 0, repoKey, now);

    return {
      rows,
      truncated,
      machines,
      staleMachines,
      notConnected: this.notConnectedCount,
      lastPushAt: this.lastPush,
    };
  }

  /** Repo keys worth asking a peer about on the next push — every key a local
   *  read has named recently, oldest first. This is the whole mechanism
   *  behind the ack telling the app what to fetch: the pump never guesses,
   *  it echoes back what `view()` was actually asked for. */
  wantedRepoKeys(): string[] {
    return [...this.wanted.keys()];
  }

  /** Reads since the last `replace()` or `clear()` that came back with no live
   *  machine at all. This is a LIVE, non-destructive read of the same counter
   *  {@link replace} drains and reports on its own return value — use the
   *  replace() result for the ack; this accessor is for introspection between
   *  pushes (tests, mainly). */
  unservedReads(): number {
    return this.unservedCount;
  }

  lastReadAt(): number | null {
    return this.lastReadTime;
  }

  lastPushAt(): number | null {
    return this.lastPush;
  }

  private noteRead(served: boolean, repoKey: string, now: number): void {
    this.lastReadTime = now;
    if (!served) this.unservedCount++;

    this.wanted.delete(repoKey);
    this.wanted.set(repoKey, now);
    if (this.wanted.size > MAX_DIRECTORY_REPO_KEYS) {
      const oldest = this.wanted.keys().next().value;
      if (oldest !== undefined) this.wanted.delete(oldest);
    }
  }
}
