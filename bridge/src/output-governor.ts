import type { AbMessage } from "./protocol";
import { logger } from "./logger";

const log = logger.child({ component: "output-governor" });

/** Bytes a terminal may send before the governor starts shaping it. Sized to
 *  let an ordinary command's whole output through untouched — a page of build
 *  log, a diff, a test run's summary — so only a genuine flood is ever shaped. */
export const OUTPUT_BURST_BYTES = 384_000;
/** Sustained budget per terminal. Far above what anyone reads, far below what a
 *  runaway `cat` of a large file or a progress bar redrawing at 60 Hz emits. */
export const OUTPUT_REFILL_BYTES_PER_SEC = 128_000;
/** Cadence of the composed screen sent in place of the dropped frames. */
export const OUTPUT_CATCH_UP_MS = 1_000;

export interface OutputGovernorDeps {
  /** Compose the current screen of one terminal, externalised the same way a
   *  bus frame for it would be. `null` = the screen is gone (exited). */
  compose(terminalId: string, checkoutId: string): Promise<AbMessage | null>;
  /** Send a frame down the governed stream, bypassing the bus. */
  send(msg: AbMessage): void;
  now?: () => number;
  setTimer?: (fn: () => void, ms: number) => unknown;
  clearTimer?: (handle: unknown) => void;
  burstBytes?: number;
  refillBytesPerSec?: number;
  catchUpMs?: number;
}

interface TerminalBudget {
  terminalId: string;
  checkoutId: string;
  tokens: number;
  refilledAt: number;
  /** Frames are being dropped; a catch-up screen is (or will be) scheduled. */
  lagging: boolean;
  /** Something was dropped since the last screen went out, so the next
   *  catch-up owes one. */
  droppedSinceCatchUp: boolean;
  timer: unknown | null;
}

/**
 * Shapes ONE relay stream's terminal output so a flooding terminal cannot
 * starve every other frame on the machine's single uplink.
 *
 * The uplink is one FIFO WebSocket with no priority, so every frame the bridge
 * writes — a session-list reply, a git status, a control result — waits behind
 * whatever terminal output was written before it. A single `cat` of a large
 * file or a progress bar redrawing at full rate queues megabytes ahead of a
 * reply the app times out after seconds, which surfaced as a sticky
 * "session reply timed out" banner. Bounding what enters the socket is the only
 * lever the bridge has: the queue is inside the runtime and the relay is
 * zero-knowledge, so nothing downstream can reorder.
 *
 * Per terminal, a token bucket admits output until the budget is spent, then
 * DROPS every frame for that terminal and instead sends one composed
 * `terminal:snapshot` per {@link OUTPUT_CATCH_UP_MS}: a whole screen is a
 * bounded number of bytes however much output produced it, and the app applies
 * it in place of the frames it never saw (its seq re-arms the app's cutoff, so
 * nothing dropped is ever waited for). Output resumes once the bucket has
 * refilled to half — hysteresis, so a flood alternates between a burst of live
 * frames and a screen rather than shaping frame by frame, which would split
 * escape sequences across dropped boundaries at every frame.
 *
 * The governor sits on the RELAY stream's delivery path, never on the bus: the
 * bus fans every frame to the desktop's loopback listener too, and the desktop
 * drives its own machine over a socket that no flood can starve.
 */
export class OutputGovernor {
  private readonly budgets = new Map<string, TerminalBudget>();
  private readonly now: () => number;
  private readonly setTimer: (fn: () => void, ms: number) => unknown;
  private readonly clearTimer: (handle: unknown) => void;
  private readonly burstBytes: number;
  private readonly refillPerMs: number;
  private readonly catchUpMs: number;
  private disposed = false;

  constructor(private readonly deps: OutputGovernorDeps) {
    this.now = deps.now ?? Date.now;
    this.setTimer = deps.setTimer ?? ((fn, ms) => {
      const t = setTimeout(fn, ms);
      t.unref?.();
      return t;
    });
    this.clearTimer = deps.clearTimer ?? ((h) => clearTimeout(h as ReturnType<typeof setTimeout>));
    this.burstBytes = deps.burstBytes ?? OUTPUT_BURST_BYTES;
    this.refillPerMs = (deps.refillBytesPerSec ?? OUTPUT_REFILL_BYTES_PER_SEC) / 1000;
    this.catchUpMs = deps.catchUpMs ?? OUTPUT_CATCH_UP_MS;
  }

  /** Whether `msg` may go down the stream now. Everything that is not terminal
   *  output passes untouched — the point is that those frames stop waiting. */
  admit(msg: AbMessage): boolean {
    if (this.disposed) return true;
    if (msg.type === "terminal:exited") {
      // The screen is gone, so a catch-up owed to it could only compose null;
      // and the id may be reused by a restart, which must start unshaped.
      this.forget(`${checkoutIdOf(msg)} ${msg.terminalId}`);
      return true;
    }
    if (msg.type !== "terminal:output") return true;

    const budget = this.budgetFor(msg.terminalId, checkoutIdOf(msg));
    this.refill(budget);
    if (budget.lagging) {
      budget.droppedSinceCatchUp = true;
      return false;
    }
    // `length`, not the encoded byte count: an over-estimate for ASCII is
    // impossible (one code unit is at least one byte), and encoding every
    // frame to measure it would cost more than the shaping saves.
    const cost = msg.data.length;
    if (budget.tokens >= cost) {
      budget.tokens -= cost;
      return true;
    }
    budget.lagging = true;
    budget.droppedSinceCatchUp = true;
    this.armCatchUp(budget);
    return false;
  }

  /** Terminals currently being shaped — for tests and diagnostics. */
  laggingTerminals(): string[] {
    return [...this.budgets].filter(([, b]) => b.lagging).map(([k]) => k);
  }

  dispose(): void {
    this.disposed = true;
    for (const key of [...this.budgets.keys()]) this.forget(key);
  }

  private budgetFor(terminalId: string, checkoutId: string): TerminalBudget {
    // Keyed by both: two checkouts may each run a slot named `dev`, so the
    // external id alone is not a terminal.
    const key = `${checkoutId} ${terminalId}`;
    let budget = this.budgets.get(key);
    if (!budget) {
      budget = {
        terminalId,
        checkoutId,
        tokens: this.burstBytes,
        refilledAt: this.now(),
        lagging: false,
        droppedSinceCatchUp: false,
        timer: null,
      };
      this.budgets.set(key, budget);
    }
    return budget;
  }

  private refill(budget: TerminalBudget): void {
    const now = this.now();
    const elapsed = Math.max(0, now - budget.refilledAt);
    budget.refilledAt = now;
    budget.tokens = Math.min(this.burstBytes, budget.tokens + elapsed * this.refillPerMs);
  }

  private forget(key: string): void {
    const budget = this.budgets.get(key);
    if (!budget) return;
    if (budget.timer !== null) this.clearTimer(budget.timer);
    this.budgets.delete(key);
  }

  private armCatchUp(budget: TerminalBudget): void {
    if (budget.timer !== null) return;
    budget.timer = this.setTimer(() => {
      budget.timer = null;
      void this.catchUp(budget);
    }, this.catchUpMs);
  }

  private async catchUp(budget: TerminalBudget): Promise<void> {
    const key = `${budget.checkoutId} ${budget.terminalId}`;
    if (this.disposed || this.budgets.get(key) !== budget) return;
    if (budget.droppedSinceCatchUp) {
      budget.droppedSinceCatchUp = false;
      try {
        const screen = await this.deps.compose(budget.terminalId, budget.checkoutId);
        // Re-read after the await: an exit or a dispose may have landed.
        if (this.disposed || this.budgets.get(key) !== budget) return;
        if (screen) this.deps.send(screen);
      } catch (err) {
        // The frames this screen stood in for are gone; only the next screen
        // can show what they painted, so keep owing one.
        log.warn("catch-up screen for terminal %s failed: %s", budget.terminalId, err);
        budget.droppedSinceCatchUp = true;
      }
    }
    // A screen still owed keeps the terminal shaped whatever the budget says:
    // releasing it now would resume live frames after a gap nothing paints.
    if (budget.droppedSinceCatchUp) {
      this.armCatchUp(budget);
      return;
    }
    this.refill(budget);
    if (budget.tokens >= this.burstBytes / 2) {
      budget.lagging = false;
      return;
    }
    // Still over budget: keep dropping, and keep the screen coming for as long
    // as anything is dropped.
    this.armCatchUp(budget);
  }
}

function checkoutIdOf(msg: AbMessage): string {
  return "checkoutId" in msg && typeof msg.checkoutId === "string" ? msg.checkoutId : "main";
}
