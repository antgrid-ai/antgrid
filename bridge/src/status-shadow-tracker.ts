import { logger } from "./logger";
import type { WorkStatus } from "./protocol";
import {
  compare,
  exited,
  initialShadow,
  nextDeadline,
  observe,
  shadowKey,
  track,
  type ShadowAgent,
  type ShadowEvent,
  type ShadowLine,
  type ShadowState,
} from "./status-shadow";

const log = logger.child({ component: "status-shadow" });

// A compare that throws leaves its past-due deadline in place, so without a
// floor every re-arm would fire at once and spin the event loop until the PTY
// exits. Nothing the fold times is finer than its 1.5 s debounce.
export const MIN_TIMER_MS = 250;

export interface StatusShadowDeps {
  oldStatusFor(id: string): WorkStatus | undefined;
  now?: () => number;
  setTimer?: (fn: () => void, ms: number) => unknown;
  clearTimer?: (h: unknown) => void;
  write?: (line: ShadowLine) => void;
  warn?: (fields: Record<string, unknown>, msg: string) => void;
}

/** Imperative shell around the pure shadow fold: owns the clock, the single
 *  deadline timer and the log sink. Nothing here may throw into the caller or
 *  write anything but log lines, because it observes live sessions. */
export class StatusShadowTracker {
  private state: ShadowState = initialShadow;
  private readonly sources = new Map<string, object>();
  private readonly lastTitleAt = new Map<string, number>();
  private readonly errors = new Map<string, number>();
  private handle: unknown;
  private armedFor: number | undefined;

  private readonly oldStatusFor: (id: string) => WorkStatus | undefined;
  private readonly now: () => number;
  private readonly setTimer: (fn: () => void, ms: number) => unknown;
  private readonly clearTimer: (h: unknown) => void;
  private readonly write: (line: ShadowLine) => void;
  private readonly warn: (fields: Record<string, unknown>, msg: string) => void;

  constructor(deps: StatusShadowDeps) {
    this.oldStatusFor = deps.oldStatusFor;
    this.now = deps.now ?? Date.now;
    this.setTimer =
      deps.setTimer ??
      ((fn, ms) => {
        const t = setTimeout(fn, ms);
        (t as { unref?: () => void }).unref?.();
        return t;
      });
    this.clearTimer = deps.clearTimer ?? ((h) => clearTimeout(h as ReturnType<typeof setTimeout>));
    this.write = deps.write ?? ((line) => log.info(line.fields, line.msg));
    this.warn = deps.warn ?? ((fields, msg) => log.warn(fields, msg));
  }

  track(id: string, agent: ShadowAgent, source: object): void {
    this.guard(id, () => {
      this.sources.set(id, source);
      this.lastTitleAt.delete(id);
      this.state = track(this.state, id, agent, this.now());
    });
  }

  title(id: string, source: object, title: string): void {
    this.guard(id, () => {
      if (this.sources.get(id) !== source) return;
      const now = this.now();
      this.lastTitleAt.set(id, now);
      this.apply(id, observe(this.state, id, { kind: "title", title }, now), now);
    });
  }

  input(id: string, data: string, via: "user" | "bus"): void {
    if (!this.sources.has(id)) return;
    this.guard(id, () => {
      const key = shadowKey(data);
      if (!key) return;
      const now = this.now();
      this.apply(id, observe(this.state, id, { kind: "key", key, via }, now), now);
    });
  }

  observe(id: string, ev: Exclude<ShadowEvent, { kind: "title" }>): void {
    this.guard(id, () => {
      const now = this.now();
      this.apply(id, observe(this.state, id, ev, now), now);
    });
  }

  reconcile(): void {
    const now = this.now();
    for (const id of [...this.state.sessions.keys()]) {
      this.guard(id, () => this.compareOne(id, now));
    }
    this.guard("*", () => this.reschedule());
  }

  exited(id: string): void {
    this.guard(id, () => {
      const res = exited(this.state, id, this.now());
      this.state = res.state;
      this.emit(id, res.lines);
      const errs = this.errors.get(id) ?? 0;
      if (errs > 1) this.write({ msg: "status shadow: errors suppressed", fields: { terminalId: id, errors: errs } });
    });
    this.sources.delete(id);
    this.lastTitleAt.delete(id);
    this.errors.delete(id);
    this.guard("*", () => this.reschedule());
  }

  reset(): void {
    this.state = initialShadow;
    this.sources.clear();
    this.lastTitleAt.clear();
    this.errors.clear();
    this.dropTimer();
  }

  private apply(id: string, next: ShadowState, now: number): void {
    if (next === this.state) return;
    this.state = next;
    this.compareOne(id, now);
    this.reschedule();
  }

  private compareOne(id: string, now: number): void {
    const res = compare(this.state, id, this.oldStatusFor(id), now);
    this.state = res.state;
    this.emit(id, res.lines);
  }

  private emit(id: string, lines: ShadowLine[]): void {
    const at = this.lastTitleAt.get(id);
    for (const line of lines) {
      // A stalled title stream makes the shadow side stale; the quiet time lets
      // an analyst discount those lines.
      if (at !== undefined && line.fields.evidence !== undefined) line.fields.titleQuietMs = this.now() - at;
      this.write(line);
    }
  }

  private reschedule(): void {
    const d = nextDeadline(this.state);
    if (d === undefined) {
      this.dropTimer();
      return;
    }
    if (this.handle !== undefined && this.armedFor === d) return;
    if (this.handle !== undefined) this.clearTimer(this.handle);
    this.armedFor = d;
    this.handle = this.setTimer(() => {
      this.handle = undefined;
      this.armedFor = undefined;
      this.reconcile();
    }, Math.max(MIN_TIMER_MS, d - this.now()));
  }

  private dropTimer(): void {
    if (this.handle !== undefined) this.clearTimer(this.handle);
    this.handle = undefined;
    this.armedFor = undefined;
  }

  private guard(id: string, fn: () => void): void {
    try {
      fn();
    } catch (err) {
      const n = (this.errors.get(id) ?? 0) + 1;
      this.errors.set(id, n);
      if (n === 1) {
        try {
          this.warn({ terminalId: id, err: err instanceof Error ? err.message : String(err) }, "status shadow: dropped");
        } catch {
          // the sink failing must not reach the caller either
        }
      }
    }
  }
}
