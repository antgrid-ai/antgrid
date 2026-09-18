// bridge/src/submit-gate.ts

// Holding a submit until the guest is reading. A leaf module: the rules below
// are about a PTY's buffering and a TUI's startup, not about the bridge's own
// plumbing, and `terminal-manager.ts` owns everything they are applied to.

import { logger } from "./logger";
import { BRACKETED_PASTE } from "./terminal-modes";

const log = logger.child({ component: "submit-gate" });

/** Why a held submit was let go. Both reach `send`; only one of them means the
 *  guest is reading, which is what the gate was waiting for. */
type ReleaseReason = "guest ready" | "guest reset";

/**
 * How long a submit waits for the guest to announce itself before going anyway.
 *
 * Generous on purpose: an agent CLI cold-starting a runtime on Windows takes
 * seconds, and the cost of the two outcomes is asymmetric. Waiting too long
 * delays a line nobody is reading yet; giving up too early is the bug this
 * module exists to fix. The bound exists only so a guest that never announces
 * an input mode submits the way it always did rather than never submitting.
 */
export const SUBMIT_READY_TIMEOUT_MS = 15_000;

/**
 * The same wait, for a terminal whose guest has been reading once already.
 *
 * What is being waited out there is an interface swap, not a cold start: the
 * two phases of Claude Code's startup are about 600ms apart, and a modal that
 * drops the mode is back within a frame or two. The cold-start bound is sized
 * for a runtime booting on Windows and would park a line for fifteen seconds
 * behind a swap that resolves in one.
 */
const SUBMIT_REARM_TIMEOUT_MS = 3_000;

/**
 * Whether the guest looks like it is reading, from its output alone.
 *
 * Bracketed paste on its own is not the answer, measured: Claude Code announces
 * DECSET 2004 about 700ms into startup, clears it ~600ms later and announces it
 * again when the real composer mounts. A line written against that FIRST
 * announcement is buffered unread and arrives welded to its own CR — the exact
 * failure {@link SubmitGate} exists to prevent, reached by trusting the wrong
 * half of a two-phase startup.
 *
 * What separates the two phases is PAINT. The pre-TUI phase emits nothing but
 * private-mode sets and terminal queries; a mounted TUI puts characters on the
 * grid. So readiness is: the guest has drawn its interface while the mode that
 * says how it wants input encoded is on.
 *
 * Evidence rather than proof, like the mode it refines — an agent that paints a
 * loading spinner before attaching its reader would still be believed, and the
 * gate's bound is what covers being wrong.
 */
export class GuestReadiness {
  private state: ScanState = "text";
  /** Parameter bytes of the CSI sequence in progress, so its final byte can be
   *  read together with what it applies to. */
  private csi = "";
  private ready = false;

  /**
   * Feed one output chunk plus what the mode tracker made of it, and learn
   * whether the guest's readiness CHANGED — `null` while it stands.
   *
   * The mode is asked for rather than parsed here so the answer comes from the
   * same latch the paste decision is taken from; this module only adds the half
   * that latch cannot see.
   *
   * `on` is the state at the END of the chunk, and {@link scan} credits only
   * the paint that falls after the last write of that mode — so a mount and its
   * first frame arriving in one read answer for themselves, while pre-TUI paint
   * ahead of the first `?2004h` still does not.
   */
  observe(chunk: string, mode: { on: boolean; changed: boolean }): ReadinessVerdict {
    // Scanned even where the answer is discarded: the parser state crosses
    // chunk boundaries, and a chunk skipped here would leave a split sequence
    // resolving against bytes from the wrong side of it.
    const painted = this.scan(chunk);
    // A guest that turned the mode off is between interfaces, and whatever it
    // painted belonged to the one that is gone.
    if (!mode.on) return this.settle(false);
    // A chunk that MOVED the mode retires whatever the previous interface
    // earned: only paint following the move speaks for the one now mounted.
    return this.settle(mode.changed ? painted : this.ready || painted);
  }

  /** Only an EDGE is reported: the caller latches, so restating readiness on
   *  every painted chunk would be noise it has to filter anyway. */
  private settle(ready: boolean): ReadinessVerdict {
    if (ready === this.ready) return null;
    this.ready = ready;
    return ready ? "ready" : "lost";
  }

  /**
   * Did this chunk put anything on the grid while the mode held the state the
   * chunk ends in?
   *
   * Position, not merely presence. A PTY coalesces a TUI's mount and its first
   * frame into one read whenever the bridge is busy, and such a guest then
   * waits for input — so a chunk answered with "ambiguous" is answered with
   * "never", not with "one chunk later". Paint after the last write of
   * {@link BRACKETED_PASTE} is paint under that write's state, which lets the
   * chunk answer for itself while pre-TUI paint ahead of the first
   * announcement still cannot.
   *
   * A state machine rather than a regex because a PTY splits wherever it likes,
   * and a startup burst is where it splits most: `ESC [ ?2004h ESC [ ?203` /
   * `1h` would otherwise read as the printable text `1h` and call a guest that
   * has drawn nothing ready. Only the STATE and the parameter run cross the
   * boundary, so a long OSC title cannot grow an unbounded carry.
   */
  private scan(chunk: string): boolean {
    let state = this.state;
    let csi = this.csi;
    let painted = false;
    for (let i = 0; i < chunk.length; i++) {
      const c = chunk[i]!;
      switch (state) {
        case "text": {
          if (c === "\x1b") { state = "esc"; break; }
          // Answered a RUN at a time, not a byte: text carries no parser state,
          // so the stretch up to the next escape either holds a glyph or does
          // not, and once one is found the rest of the run says nothing new.
          // This loop runs on every chunk for the life of the terminal — the
          // mode can retire a paint at any point, so it cannot stop at the first
          // one — and walking it byte by byte would put the full size of every
          // frame a TUI draws on the PTY's own path.
          const next = chunk.indexOf("\x1b", i);
          const end = next === -1 ? chunk.length : next;
          if (!painted) {
            for (let j = i; j < end; j++) {
              const code = chunk.charCodeAt(j);
              // C0 and DEL move the cursor or ring a bell; neither is a glyph.
              if (code >= 0x20 && code !== 0x7f) { painted = true; break; }
            }
          }
          i = end - 1;
          break;
        }
        case "esc":
          if (c === "\x1b") break;
          if (c === "[") { state = "csi"; csi = ""; break; }
          state = c === "]" ? "osc" : "text";
          break;
        case "csi":
          // Parameter and intermediate bytes run below 0x40; the first byte at
          // or above it ends the sequence.
          if (c >= "@" && c <= "~") {
            state = "text";
            if ((c === "h" || c === "l") && setsBracketedPaste(csi)) painted = false;
            break;
          }
          if (csi.length < MAX_CSI_PARAMS) csi += c;
          break;
        case "osc":
          if (c === "\x07") state = "text";
          else if (c === "\x1b") state = "oscEsc";
          break;
        case "oscEsc":
          state = c === "\\" ? "text" : "osc";
          break;
      }
    }
    this.state = state;
    this.csi = csi;
    return painted;
  }
}

/** Longest parameter run kept while a CSI sequence is open — generous for the
 *  real thing (`?1000;1002;1006;2004`), and a cap at all because a sequence
 *  whose terminator never arrives would otherwise grow without bound. */
const MAX_CSI_PARAMS = 64;

/** Whether a CSI parameter run sets or resets {@link BRACKETED_PASTE} — DEC
 *  private (`?`-led), possibly among other modes in one sequence. */
function setsBracketedPaste(params: string): boolean {
  if (params[0] !== "?") return false;
  for (const param of params.slice(1).split(";")) {
    if (param !== "" && Number(param) === BRACKETED_PASTE) return true;
  }
  return false;
}

/** A change in what the guest's output says about its reader. `null` is "no
 *  change", which is what almost every chunk is. */
type ReadinessVerdict = "ready" | "lost" | null;

/** Where the paint scanner is in the guest's byte stream. */
type ScanState = "text" | "esc" | "csi" | "osc" | "oscEsc";

/**
 * Holds an agent's submits until its TUI is reading.
 *
 * A PTY write lands in a buffer whether or not the guest is reading, and a guest
 * that is not reading gets the whole buffer in ONE read once it starts — the
 * line and its submitting CR together, which is the case `SUBMIT_CR_GAP_MS`
 * cannot cover: that gap is on the WRITER's side and produces no boundary in a
 * read the guest has not taken yet. The line is typed into the composer and
 * never sent, and two cards written seconds apart arrive welded onto one line.
 *
 * The window that matters is the agent's own startup — a session is started and
 * a queued session-bus card, a launch prompt, or a Handler reply drains into it
 * a moment later, long before the TUI has attached its reader. `initialPromptArgv`
 * exists because argv never races this; everything arriving afterwards has to
 * wait for the guest instead.
 *
 * Readiness is decided by {@link GuestReadiness}, which is evidence rather than
 * proof — hence the bound.
 */
export class SubmitGate {
  private readonly ready = new Set<string>();
  private readonly waiters = new Map<string, ((reason: ReleaseReason) => void)[]>();
  private readonly chains = new Map<string, Promise<void>>();
  /** How many guests this id has had. Captured when a submit is ASKED FOR and
   *  compared when it is about to wait, which is a microtask later: without it a
   *  reset landing in that window releases nothing, because the waiter it would
   *  release does not exist yet, and the submit then waits out the full bound on
   *  a guest that is already gone. Never deleted -- an id whose count went back
   *  to zero would match a submit captured under the first guest. */
  private readonly guests = new Map<string, number>();
  /** Ids whose guest has been reading at least once, so a later wait is an
   *  interface swap and takes {@link SUBMIT_REARM_TIMEOUT_MS}. */
  private readonly rearming = new Set<string>();

  constructor(
    private readonly timeoutMs: number = SUBMIT_READY_TIMEOUT_MS,
    private readonly rearmMs: number = SUBMIT_REARM_TIMEOUT_MS,
  ) {}

  /** The guest announced an input mode. Idempotent — the caller sees every
   *  output chunk and cannot cheaply know which one first carried the mode. */
  markReady(terminalId: string): void {
    if (this.ready.has(terminalId)) return;
    this.ready.add(terminalId);
    this.rearming.add(terminalId);
    this.release(terminalId, "guest ready");
  }

  /**
   * The guest stopped looking like it is reading — same guest, different
   * interface.
   *
   * Deliberately not a `reset`: the process is the one the held submits were
   * asked for, so the wait counter must not move (moving it resolves waits that
   * should keep waiting) and nothing is released — the whole point is that the
   * next submit waits for the new interface rather than landing in the gap.
   */
  markUnready(terminalId: string): void {
    this.ready.delete(terminalId);
  }

  /**
   * A fresh guest is about to occupy this id, or the old one is gone.
   *
   * Held submits are RELEASED rather than dropped: whether they still go
   * anywhere is the caller's decision (it holds the session identity), and a
   * waiter left holding the chain would strand every later submit to a same-id
   * respawn behind a promise nothing can ever resolve.
   */
  reset(terminalId: string): void {
    this.ready.delete(terminalId);
    // A new process cold-starts, whatever the last one managed.
    this.rearming.delete(terminalId);
    this.guests.set(terminalId, this.guest(terminalId) + 1);
    this.release(terminalId, "guest reset");
  }

  /** Run `send` once the guest is reading, keeping this terminal's submits in
   *  the order they were asked for.
   *
   *  `sha` is the caller's join key for the line (`line-key.ts`), carried only
   *  so the reason this gate released joins the same log walk as the queue and
   *  the PTY write. Absent where the caller has none to give. */
  run(terminalId: string, send: () => void, sha?: string): void {
    // Synchronous once the guest has announced itself and nothing is held: the
    // steady-state path — a Handler reply, the `continue` nudge, a bus card into
    // a live agent — must not grow a scheduling hop, and a submit that jumped
    // ahead of one still waiting would reorder the two.
    if (this.ready.has(terminalId) && !this.chains.has(terminalId)) {
      send();
      return;
    }
    const guest = this.guest(terminalId);
    const prior = this.chains.get(terminalId) ?? Promise.resolve();
    // The catch matches `PtySubmitQueue.chain`'s and is load-bearing for the
    // same reason: a rejected tail would stall every later submit on this
    // terminal for the life of the session.
    const next = prior.then(() => this.whenReady(terminalId, guest, sha)).then(send).catch(() => {});
    this.chains.set(terminalId, next);
    void next.then(() => {
      if (this.chains.get(terminalId) === next) this.chains.delete(terminalId);
    });
  }

  private guest(terminalId: string): number {
    return this.guests.get(terminalId) ?? 0;
  }

  private whenReady(terminalId: string, guest: number, sha?: string): Promise<void> {
    if (this.ready.has(terminalId) || this.guest(terminalId) !== guest) return Promise.resolve();
    const waitedFrom = Date.now();
    return new Promise<void>((resolve) => {
      let done = false;
      // WHICH of the three ends the wait is the whole diagnostic value here.
      // `timeout` is the one the gate exists to avoid: the line is going into a
      // TUI that has announced nothing, which is what welds a prompt to its CR.
      const finish = (reason: ReleaseReason | "timeout"): void => {
        if (done) return;
        done = true;
        clearTimeout(timer);
        log.debug({ terminalId, ...(sha ? { sha } : {}), reason, waitedMs: Date.now() - waitedFrom }, "submit gate: wait ended");
        resolve();
      };
      const bound = this.rearming.has(terminalId) ? this.rearmMs : this.timeoutMs;
      const timer = setTimeout(() => finish("timeout"), bound);
      // A bounded wait must not be a reason to stay alive: a bridge whose last
      // outstanding work is a submit into a guest that never announces should
      // still exit when everything else is done.
      timer.unref?.();
      const list = this.waiters.get(terminalId);
      if (list) list.push(finish);
      else this.waiters.set(terminalId, [finish]);
    });
  }

  private release(terminalId: string, reason: ReleaseReason): void {
    const list = this.waiters.get(terminalId);
    if (!list) return;
    this.waiters.delete(terminalId);
    for (const resolve of list) resolve(reason);
  }
}
