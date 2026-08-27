import type { ResolvedTitle } from "./agents/types";

export interface AutoNameSink {
  applyAutoName(id: string, name: string): void;
}

const MAX_TITLE_LEN = 60;
const DEFAULT_DEBOUNCE_MS = 300;

/** Strip control bytes (incl. leftover ANSI) + braille spinner glyphs, collapse
 *  whitespace, trim, and cap length. Returns "" if nothing usable remains. */
function sanitizeTitle(raw: string): string {
  return raw
    .replace(/\x1b\[[0-9;]*[A-Za-z]/g, "") // CSI escape sequences
    .replace(/[\x00-\x1f\x7f-\x9f]/g, "") // C0/C1 control chars
    .replace(/[⠀-⣿]/gu, "") // braille-pattern spinners (U+2800–U+28FF)
    .replace(/\s+/g, " ") // collapse whitespace runs
    .trim()
    .slice(0, MAX_TITLE_LEN);
}

/** Precedence within the structured signal: the resolvers' own `kind`, aliased
 *  rather than restated so the two cannot drift. `agents/types.ts` declares only
 *  types, so this import is erased and drags no agent code in here. */
export type TitleRank = ResolvedTitle["kind"];

interface Signals {
  /** Title and rank travel together: a rank stored without the title it
   *  describes would latch the precedence guard against a name nobody applied. */
  structured?: { title: string; rank: TitleRank };
  osc?: string;
}

/**
 * Owns the auto-naming decision for every session. Holds the latest structured
 * and OSC title per id; the applied name is `structured ?? osc` (structured
 * wins). Rapid changes are debounced into a single applyAutoName. The
 * manual-wins check lives in the sink (SessionManager.applyAutoName), so this
 * unit stays pure policy.
 *
 * Within the structured signal, latest wins EXCEPT that a `first-message` title
 * may not displace a `generated` one — see onStructuredTitle.
 */
export class SessionNamer {
  private readonly signals = new Map<string, Signals>();
  private readonly dirty = new Set<string>();
  private timer: ReturnType<typeof setTimeout> | null = null;

  constructor(
    private readonly sink: AutoNameSink,
    private readonly opts: { debounceMs?: number } = {},
  ) {}

  /**
   * `rank` is required, not defaulted: `generated` is the dominant value, so a
   * caller that omitted it would silently latch this slot against every later
   * real title — the exact bug the guard exists to prevent, reintroduced with
   * no compile error. Stating it at each call site makes that a build decision.
   *
   * Only the per-turn native transcript read yields `first-message`, and it
   * re-yields the SAME opening prompt every turn — so without the guard the
   * turn after a real title landed would revert the session to that prompt, and
   * title generation is attempted once per agent session, so nothing restores it.
   */
  onStructuredTitle(id: string, title: string, rank: TitleRank): void {
    // Rank only a title that can actually become a name. One that sanitizes
    // away applies nothing, and arming the guard on it would block every later
    // first-message title on behalf of a name the user never saw.
    if (!sanitizeTitle(title)) return;
    const current = this.signals.get(id);
    if (rank === "first-message" && current?.structured?.rank === "generated") return;
    this.update(id, (s) => { s.structured = { title, rank }; }, current);
  }

  onOscTitle(id: string, title: string): void {
    this.update(id, (s) => { s.osc = title; });
  }

  flush(): void {
    if (this.timer) { clearTimeout(this.timer); this.timer = null; }
    for (const id of this.dirty) {
      const s = this.signals.get(id);
      if (!s) continue;
      const name = sanitizeTitle(s.structured?.title ?? s.osc ?? "");
      if (name) this.sink.applyAutoName(id, name);
    }
    this.dirty.clear();
  }

  /**
   * Drop buffered state for ONE session (its PTY exited) without touching
   * others. Prevents a stale title — especially a `structured` one, which wins
   * precedence — from a previous run leaking into a restarted same-id session
   * (SessionManager.start reuses the entry id). A pending name for this id is
   * discarded, not flushed: the run that produced it is gone.
   */
  forget(id: string): void {
    this.signals.delete(id);
    this.dirty.delete(id);
  }

  /**
   * Drop the structured title + rank for a slot whose AGENT CONVERSATION changed
   * under a still-live PTY (Claude `/clear`, codex `/new`). The rank describes a
   * conversation, not a slot, and that PTY never exits — so `forget` never runs
   * and the previous topic's `generated` rank would veto the new conversation's
   * first-message title for the life of the process.
   *
   * OSC filler is deliberately left: it tracks the terminal, not the
   * conversation. Nothing is marked dirty either — dropping a title is not a
   * reason to rename the session; the new conversation's own first turn is.
   */
  forgetStructuredTitle(id: string): void {
    const s = this.signals.get(id);
    if (!s?.structured) return;
    delete s.structured;
    this.signals.set(id, s);
  }

  /**
   * Cancels the pending debounce timer and drops all buffered state WITHOUT
   * flushing. A session is disposed when it's gone, and naming a torn-down
   * session would be wrong — so pending names are intentionally discarded.
   * Callers who need the last name applied must call `flush()` before `dispose()`.
   */
  dispose(): void {
    if (this.timer) { clearTimeout(this.timer); this.timer = null; }
    this.dirty.clear();
    this.signals.clear();
  }

  private update(id: string, mut: (s: Signals) => void, known?: Signals): void {
    const s = known ?? this.signals.get(id) ?? {};
    mut(s);
    this.signals.set(id, s);
    this.dirty.add(id);
    this.arm();
  }

  private arm(): void {
    if (this.timer) return;
    this.timer = setTimeout(() => { this.timer = null; this.flush(); },
      this.opts.debounceMs ?? DEFAULT_DEBOUNCE_MS);
  }
}
