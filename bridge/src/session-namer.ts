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

/**
 * Precedence within the structured signal, strongest first. The two values a
 * resolver can report are aliased off `ResolvedTitle["kind"]` rather than
 * restated, so those cannot drift; "self" is the one rank no resolver can
 * produce, because it is the title WE generated (agents/title-generate.ts).
 *
 * `agents/types.ts` declares only types, so the import is erased and drags no
 * agent code in here.
 */
export type TitleRank = ResolvedTitle["kind"] | "self";

/** Higher wins. A title never loses to a weaker one, which is what stops the
 *  per-turn first-message re-read — the same opening prompt, restated on every
 *  turn of the session — from undoing a real name. */
const RANK_ORDER: Record<TitleRank, number> = {
  "first-message": 0,
  self: 1,
  manual: 2,
};

interface Signals {
  /** Sanitized at ingest, so `title` is exactly the name that will be applied.
   *  Title and rank travel together: a rank stored without the title it
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
 * Within the structured signal, latest wins EXCEPT that a title may not
 * displace a STRONGER-ranked one — see onStructuredTitle and RANK_ORDER.
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
   * `rank` is required, not defaulted: any default is the dominant value for
   * some caller, and getting it wrong silently latches this slot against every
   * later real title — the exact bug the ordering exists to prevent,
   * reintroduced with no compile error. Stating it at each call site makes that
   * a build decision.
   *
   * Only the per-turn native transcript read yields `first-message`, and it
   * re-yields the SAME opening prompt on every turn of the session — so without
   * the ordering, the turn after a generated title landed would revert the
   * session to that prompt, and naming is attempted once per agent session, so
   * nothing would restore it.
   */
  onStructuredTitle(id: string, title: string, rank: TitleRank): void {
    const held = this.signals.get(id)?.structured;
    if (held && RANK_ORDER[rank] < RANK_ORDER[held.rank]) return;
    // Normalize at ingest, so the stored title IS the name that will be applied
    // and `flush` never has to re-derive it. One that sanitizes away applies
    // nothing, and latching the slot on it would block every later title on
    // behalf of a name the user never saw.
    const name = sanitizeTitle(title);
    if (!name) return;
    this.update(id, (s) => { s.structured = { title: name, rank }; });
  }

  /**
   * True when this slot already holds a name no model call should try to improve
   * on: one we generated, or one the user chose.
   *
   * Read by the naming gate, which is keyed by CONVERSATION while this is keyed
   * by slot — and a mode flip carries the name across the runtime swap while
   * changing the key underneath it (a terminal keys on the agent's session id, a
   * chat slot on itself). Without this the flipped session spends a second spawn
   * and renames itself mid-conversation, defeating the very exemption that kept
   * the name.
   */
  hasFinalTitle(id: string): boolean {
    const held = this.signals.get(id)?.structured;
    return !!held && RANK_ORDER[held.rank] >= RANK_ORDER.self;
  }

  onOscTitle(id: string, title: string): void {
    this.update(id, (s) => { s.osc = title; });
  }

  flush(): void {
    if (this.timer) { clearTimeout(this.timer); this.timer = null; }
    for (const id of this.dirty) {
      const s = this.signals.get(id);
      if (!s) continue;
      const name = s.structured?.title ?? sanitizeTitle(s.osc ?? "");
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
   * and the previous topic's rank would veto the new conversation's own title
   * for the life of the process.
   *
   * OSC filler is deliberately left: it tracks the terminal, not the
   * conversation. The slot is dropped from `dirty` rather than merely not added
   * to it — dropping a title is not a reason to rename the session, and a flush
   * already armed by the title being removed would otherwise fall through to
   * that OSC filler and rename the session to terminal chrome.
   */
  forgetStructuredTitle(id: string): void {
    const s = this.signals.get(id);
    if (!s?.structured) return;
    delete s.structured;
    this.dirty.delete(id);
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

  private update(id: string, mut: (s: Signals) => void): void {
    const s = this.signals.get(id) ?? {};
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
