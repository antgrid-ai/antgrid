// The asking half of the remote directory: an expiring mirror of the capability
// cards this machine last asked the account's other machines for over the bus
// (`directory-refresh.ts`). Nothing here asks by itself, and a repository nobody
// has read through `view()` is never named in what the refresher asks for.
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
import { MAX_DIRECTORY_REPO_KEYS, MAX_MACHINE_CARD_ROWS, REMOTE_ROWS_TTL_MS } from "./constants";

/** One session on a peer's capability card, as it travels the wire. Mirrors
 *  `MachineDirectoryRow` (`directory.ts`) field for field; the caps here are
 *  what keep a peer's free-text fields from becoming an unbounded prompt on
 *  this machine's agents. The sealed response body is not validated against
 *  this, so {@link RemoteDirectoryReport.rows} is the only place a row is
 *  actually checked. */
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
 * The one gate every ingested row passes through before it can be shown to an
 * agent. Rejects outright on an unsafe `projectId` — the same allowlist that
 * guards every phone-supplied id that becomes a filesystem path, because
 * nothing downstream of this cache re-checks it — and on a `sessionId`
 * carrying a hostile character: `addressesSameSession` matches on
 * `machineId` + `sessionId` alone, so an address is not a field it is safe to
 * clean, only to accept or refuse. Every other human-readable field is
 * cleaned rather than rejected: a scrubbed title is still a usable row, and
 * failing the whole card over one hostile field would cost the peer's honest
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

/** What asking one machine came to, this cycle. `"rows"` means a card came back
 *  (however many sessions it held, including zero) — {@link
 *  RemoteDirectoryCache.view} renders it as `"answered"`; the other four travel
 *  unchanged into {@link ReachMachineStatus}.
 *
 *  `"refused"` and `"reach-refused"` are kept apart all the way to the agent's
 *  reach line because they name DIFFERENT switches on the peer, and a line that
 *  names the wrong one sends the user to a setting that is already on. */
export type RemoteMachineOutcome = "rows" | "no-card" | "refused" | "reach-refused" | "unreachable";

/** One machine's answer, as the refresher hands it to {@link
 *  RemoteDirectoryCache.ingest}. `rows` is `unknown[]`, not {@link
 *  RemoteDirectoryRow}`[]`, ON PURPOSE: it came out of another machine's
 *  response, so this cache is where it is checked, and a row that fails drops
 *  alone rather than costing the machine's honest rows. */
export interface RemoteDirectoryReport {
  machineId: string;
  machineLabel?: string;
  /** When this machine's card was received; the clock {@link
   *  REMOTE_ROWS_TTL_MS} reads and what each row reports as `asOf`. */
  observedAt: number;
  outcome: RemoteMachineOutcome;
  rows: readonly unknown[];
  /** The repositories the card was asked about. The far side narrows its card
   *  to them, so a card says nothing about any other repository: zero rows for
   *  a key outside this list is not "nobody is on it". Absent means the card
   *  was not narrowed. */
  repoKeys?: readonly string[];
  /** What the FAR bridge's own `MAX_MACHINE_CARD_ROWS` cap dropped, so
   *  `view()` can sum it into an honest `truncated` rather than the mirror
   *  quietly narrowing a card that was already narrowed once. */
  truncated: number;
}

export interface RemoteDirectoryIngestResult {
  /** Rows now held for this machine. */
  accepted: number;
  /** Rows the mirror refused — any row past {@link MAX_MACHINE_CARD_ROWS}, and
   *  any row that failed the schema or {@link sanitizeRow}; or the whole
   *  report's count when the machine id itself was refused. */
  dropped: number;
}

/** `"not-asked"`: the machine answered, but about other repositories, so it
 *  has not said anything about this one yet. */
export type ReachMachineStatus = "answered" | "no-card" | "refused" | "reach-refused" | "unreachable" | "not-asked";

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
  /** Rows this card named that the mirror refused (schema
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
 *  a real peer's card. `asOf` is when that card was received: a row is never
 *  more current than this. */
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
  asOf: number;
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
   *  rather than silently excluded, so "nothing refreshed lately" and "nothing
   *  on that repo" stay two different answers. */
  staleMachines: number;
  /** Account machines the refresher cannot ask (no messaging key yet). */
  notConnected: number;
  /** When the newest answer in the mirror was received; null until a machine
   *  has answered. A machine asked and never heard from does not move it. */
  asOf: number | null;
  /** Whether this read was one the mirror could answer — the same verdict
   *  {@link RemoteDirectoryCache.unservedReads} counts, surfaced so a caller
   *  can report it without re-deriving the predicate and drifting from it. */
  served: boolean;
}

interface StoredMachine {
  machineId: string;
  machineLabel?: string;
  observedAt: number;
  outcome: RemoteMachineOutcome;
  /** False while every ask has gone unanswered: then `observedAt` is when it
   *  was asked, which is no evidence of anything on the far side. */
  answered: boolean;
  /** The repositories the held card speaks for; null for every repository,
   *  which a refusal does, since it is about the machine. */
  covers: ReadonlySet<string> | null;
  rows: RemoteDirectoryRow[];
  truncated: number;
  droppedRows: number;
}

/**
 * The mirror itself: one machine-level, in-memory, no-persistence cache of
 * what this machine last learned asking the account's other machines.
 *
 * Nothing here dials anything. A machine this cache has never heard of, or has
 * not heard from in {@link REMOTE_ROWS_TTL_MS}, simply contributes no rows —
 * that is `SessionDirectory`'s "honest census", not a bug in this class.
 */
export class RemoteDirectoryCache {
  private machines = new Map<string, StoredMachine>();
  private notConnectedCount = 0;
  /** Repo keys a local read has asked about, most-recently-asked last, capped
   *  to {@link MAX_DIRECTORY_REPO_KEYS} — the same bound a capability-card
   *  request's `repoKeys` param carries, because this is what feeds it on the
   *  next refresh. */
  private wanted = new Map<string, number>();
  private unservedCount = 0;
  private lastReadTime: number | null = null;
  private onUnserved: (() => void) | null = null;

  /** Called when a read finds no live machine, so the refresher can ask now
   *  instead of waiting out its interval. */
  setUnservedListener(fn: (() => void) | null): void {
    this.onUnserved = fn;
  }

  /**
   * Record one machine's answer, replacing whatever the mirror held for it.
   *
   * `selfMachineId` is this bridge's own relay identity. A report naming it is
   * dropped whole, every one of its rows counted against `dropped`: a machine
   * must not discover itself.
   */
  ingest(report: RemoteDirectoryReport, selfMachineId: string | null = null): RemoteDirectoryIngestResult {
    const machineId = report.machineId;
    // Refused, never cleaned, for the reason `sanitizeRow` refuses a session
    // id: the two together are the address `addressesSameSession` matches on,
    // so a machine id that survived a strip is either unreachable or now
    // names a DIFFERENT machine, whose entry this report would then replace.
    if (stripHostile(machineId) !== machineId || (selfMachineId !== null && machineId === selfMachineId)) {
      return { accepted: 0, dropped: report.rows.length };
    }

    // An ask that went unanswered says nothing about the card already held, so
    // the old rows stay (under their own receive time, and out of the mirror
    // when the TTL says so) and only the status changes. This is what lets rows
    // outlive one missed refresh.
    const held = this.machines.get(machineId);
    if (report.outcome === "unreachable" && held !== undefined) {
      this.machines.set(machineId, {
        ...held,
        ...(report.machineLabel === undefined ? {} : { machineLabel: stripHostile(report.machineLabel) }),
        outcome: "unreachable",
      });
      return { accepted: held.rows.length, dropped: 0 };
    }

    const rows: RemoteDirectoryRow[] = [];
    let dropped = 0;
    for (const raw of report.rows.slice(0, MAX_MACHINE_CARD_ROWS)) {
      const parsed = RemoteDirectoryRowSchema.safeParse(raw);
      const sanitized = parsed.success ? sanitizeRow(parsed.data) : null;
      if (sanitized === null) {
        dropped++;
        continue;
      }
      rows.push(sanitized);
    }
    // Rows past the per-machine cap are the far side's own oversend — count
    // them the same as a rejected row so the result does not under-report what
    // the mirror actually dropped.
    dropped += Math.max(0, report.rows.length - MAX_MACHINE_CARD_ROWS);

    this.machines.set(machineId, {
      machineId,
      ...(report.machineLabel === undefined ? {} : { machineLabel: stripHostile(report.machineLabel) }),
      observedAt: report.observedAt,
      outcome: report.outcome,
      answered: report.outcome !== "unreachable",
      covers: report.outcome === "rows" && report.repoKeys !== undefined ? new Set(report.repoKeys) : null,
      rows,
      truncated: Math.max(0, report.truncated),
      droppedRows: dropped,
    });
    return { accepted: rows.length, dropped };
  }

  /** Forget machines the account no longer lists, and note how many it lists
   *  that cannot be asked. Rows of a revoked machine must not outlive the
   *  revocation by the length of the TTL. */
  syncAccount(askable: ReadonlySet<string>, notConnected: number): void {
    for (const id of [...this.machines.keys()]) {
      if (!askable.has(id)) this.machines.delete(id);
    }
    this.notConnectedCount = Math.max(0, notConnected);
  }

  /** Empty the mirror. Called when this machine has no relay identity, so
   *  nothing mirrored could be messaged anyway. The remote-access switch does
   *  NOT gate this mirror: a peer's row discloses nothing about this machine
   *  and keeping it warm is what lets reach return the instant the switch
   *  does. The SEND is gated instead, at `api.ts` — so do not read this as the
   *  switch being inbound-only, which would ship a one-way channel. The
   *  unserved-read counter and the wanted-repo-key list are cleared too: both
   *  exist to steer the NEXT refresh. */
  clear(_reason: string): void {
    this.machines = new Map();
    this.notConnectedCount = 0;
    this.unservedCount = 0;
    this.wanted = new Map();
  }

  /**
   * Every row this mirror currently holds for `repoKey`, plus the reach report
   * that explains what is and is not in it.
   *
   * `selfMachineId` is re-checked here even though {@link ingest} already
   * refuses a self-entry — the same two-independent-points discipline the
   * machine-level switch gets: a caller must not be able to see itself as a
   * peer just because its own id changed between an ingest and a read.
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
    let asOf: number | null = null;

    for (const entry of this.machines.values()) {
      if (selfMachineId !== null && entry.machineId === selfMachineId) continue;

      const ageMs = now - entry.observedAt;
      // Named, so the agent learns it was asked, but it is neither fresh nor
      // live: an ask nobody answered says nothing about who is working there.
      if (!entry.answered) {
        machines.push({
          machineId: entry.machineId,
          ...(entry.machineLabel === undefined ? {} : { machineLabel: entry.machineLabel }),
          status: "unreachable",
          rows: 0,
          droppedRows: entry.droppedRows,
          truncatedCard: 0,
          ageMs,
        });
        continue;
      }

      if (asOf === null || entry.observedAt > asOf) asOf = entry.observedAt;
      // A negative age is a card from the future — a clock stepped backwards
      // since it was received — and trusting it as maximally fresh would make
      // a peer's rows immortal, since ageMs then never crosses the TTL. Treat
      // it the same as too old: a stamp that cannot be trusted is not
      // evidence of anything, least of all liveness.
      const stale = ageMs > REMOTE_ROWS_TTL_MS || ageMs < 0;
      // A card narrowed to other repositories has no rows for this one because
      // nobody asked, not because nobody is on it.
      const asked = entry.covers === null || entry.covers.has(repoKey);
      if (stale) staleMachines++;
      else if (asked) liveMachines++;

      // The machine stays NAMED even when stale — only its rows expire. A
      // refusal is a standing fact about the peer, not a card that ages out, so
      // dropping the whole entry here would render a human-actionable refusal
      // as transient staleness.
      const matching = stale || !asked ? [] : entry.rows.filter((r) => r.repoKey === repoKey);
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
          asOf: entry.observedAt,
        });
      }

      machines.push({
        machineId: entry.machineId,
        ...(entry.machineLabel === undefined ? {} : { machineLabel: entry.machineLabel }),
        status: !asked ? "not-asked" : entry.outcome === "rows" ? "answered" : entry.outcome,
        rows: matching.length,
        droppedRows: entry.droppedRows,
        truncatedCard: entry.truncated,
        ageMs,
      });
      if (!stale && asked) truncated += entry.truncated;
    }

    // A repo with no matching rows but at least one LIVE machine that was asked
    // about it is an honest empty answer ("nobody else is on it") and counts
    // as served; a read where every known machine is stale, unanswered, or
    // answered about other repositories (or none is known at all) is one the
    // refresher has not caught up on yet — such an entry stays NAMED above for
    // the agent's sake, but it must not stop this signal from asking the
    // refresher to ask sooner.
    const served = rows.length > 0 || liveMachines > 0;
    this.noteRead(served, repoKey, now);

    return {
      rows,
      truncated,
      machines,
      staleMachines,
      notConnected: this.notConnectedCount,
      asOf,
      served,
    };
  }

  /** Repo keys worth asking a peer about on the next refresh — every key a
   *  local read has named recently, oldest first. The refresher never guesses,
   *  it asks for what `view()` was actually asked for. */
  wantedRepoKeys(): string[] {
    return [...this.wanted.keys()];
  }

  /** Reads that came back with no live machine at all, since construction or
   *  the last `clear()`. */
  unservedReads(): number {
    return this.unservedCount;
  }

  lastReadAt(): number | null {
    return this.lastReadTime;
  }

  private noteRead(served: boolean, repoKey: string, now: number): void {
    this.lastReadTime = now;
    // Wanted first: the listener's refresh reads `wantedRepoKeys()` before its
    // first await, and an ask that leaves out the repo just missed answers
    // nothing for it.
    this.wanted.delete(repoKey);
    this.wanted.set(repoKey, now);
    if (this.wanted.size > MAX_DIRECTORY_REPO_KEYS) {
      const oldest = this.wanted.keys().next().value;
      if (oldest !== undefined) this.wanted.delete(oldest);
    }

    if (!served) {
      this.unservedCount++;
      this.onUnserved?.();
    }
  }
}
