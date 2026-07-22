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

interface Signals {
  structured?: string;
  osc?: string;
}

/**
 * Owns the auto-naming decision for every session. Holds the latest structured
 * and OSC title per id; the applied name is `structured ?? osc` (structured
 * wins). Rapid changes are debounced into a single applyAutoName. The
 * manual-wins check lives in the sink (SessionManager.applyAutoName), so this
 * unit stays pure policy.
 */
export class SessionNamer {
  private readonly signals = new Map<string, Signals>();
  private readonly dirty = new Set<string>();
  private timer: ReturnType<typeof setTimeout> | null = null;

  constructor(
    private readonly sink: AutoNameSink,
    private readonly opts: { debounceMs?: number } = {},
  ) {}

  onStructuredTitle(id: string, title: string): void {
    this.update(id, (s) => { s.structured = title; });
  }

  onOscTitle(id: string, title: string): void {
    this.update(id, (s) => { s.osc = title; });
  }

  flush(): void {
    if (this.timer) { clearTimeout(this.timer); this.timer = null; }
    for (const id of this.dirty) {
      const s = this.signals.get(id);
      if (!s) continue;
      const name = sanitizeTitle(s.structured ?? s.osc ?? "");
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
