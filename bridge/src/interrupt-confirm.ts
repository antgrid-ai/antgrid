import { statSync } from "node:fs";
import { open, type FileHandle } from "node:fs/promises";

/**
 * Confirms a lone Esc/Ctrl+C keystroke actually interrupted a running turn by
 * watching the agent's own transcript for the marker record its `AgentSpec`
 * declares (`transcriptInterruptFor`, `antgrid-agents/builtins`) — see
 * bridge/CLAUDE.md's interrupt entry for why the key alone is ambiguous
 * (closes a picker, a dialog, a task view) and why the transcript is the only
 * signal left (neither Claude nor Codex fires any hook on a real interrupt).
 *
 * Deps are injected so a test can drive a confirmation window without a real
 * sleep and without a real file on disk.
 */
export interface InterruptConfirmDeps {
  /** Wall clock, ms. */
  now(): number;
  /** Schedules [fn] to run roughly every [intervalMs] ms; returns an opaque
   *  handle for {@link clearRepeating}. The default unref's it — a pending
   *  confirmation must never keep the process alive. */
  setRepeating(fn: () => void, intervalMs: number): unknown;
  clearRepeating(handle: unknown): void;
  /** The current size, in bytes, of the file at [path] — undefined if it does
   *  not exist. Synchronous and called BEFORE the keystroke reaches the PTY
   *  ({@link InterruptConfirmer.arm}'s only caller), so the baseline can never
   *  itself race the CLI's write. */
  fileSize(path: string): number | undefined;
  /** Bytes appended to the file at [path] since byte offset [from] — never the
   *  bytes before it (rule: never read the whole transcript). Empty when the
   *  file has not grown or no longer exists; a read failure is swallowed by
   *  the caller, not thrown here. */
  readAppended(path: string, from: number): Promise<string>;
}

// Long enough for Codex's measured ~36ms post-key append with slack for a
// slower machine; short enough that a picker/dialog Esc's dead window is not
// user-visible in any status the bridge derives from it.
const CONFIRM_WINDOW_MS = 3_000;
const POLL_INTERVAL_MS = 250;

interface Pending {
  transcriptPath: string;
  predicate: (record: unknown) => boolean;
  onConfirmed: () => void;
  offset: number;
  /** An incomplete trailing line from the previous read — a poll can land
   *  mid-write, and the next read picks up exactly where the last one's bytes
   *  ended, so the halves must be stitched before parsing. */
  carry: string;
  deadline: number;
  handle: unknown;
  /** True while a poll's `readAppended` is in flight. A slow read (or a
   *  machine hiccup) can outlast the 250ms tick, and a second overlapping
   *  poll reading from the same stale `offset` would double-apply whatever
   *  the first one is about to append to it. */
  polling: boolean;
}

export class InterruptConfirmer {
  private readonly pending = new Map<string, Pending>();

  constructor(private readonly deps: InterruptConfirmDeps) {}

  /**
   * A lone Esc/Ctrl+C landed on [sessionId], whose agent's transcript at
   * [transcriptPath] is matched against [predicate]. [onConfirmed] fires at
   * most once, the moment a newly appended, fully-parsed JSONL line matches.
   *
   * A transcript that does not exist is a silent no-op — nothing here may
   * guess. A key landing while [sessionId] already has a confirmation in
   * flight extends its window instead of starting a second reader against the
   * same file.
   */
  arm(
    sessionId: string,
    transcriptPath: string,
    predicate: (record: unknown) => boolean,
    onConfirmed: () => void,
  ): void {
    const existing = this.pending.get(sessionId);
    if (existing) {
      existing.deadline = this.deps.now() + CONFIRM_WINDOW_MS;
      return;
    }
    const offset = this.deps.fileSize(transcriptPath);
    if (offset === undefined) return;
    const state: Pending = {
      transcriptPath,
      predicate,
      onConfirmed,
      offset,
      carry: "",
      deadline: this.deps.now() + CONFIRM_WINDOW_MS,
      handle: undefined,
      polling: false,
    };
    state.handle = this.deps.setRepeating(() => { void this.poll(sessionId); }, POLL_INTERVAL_MS);
    this.pending.set(sessionId, state);
  }

  /** Drops [sessionId]'s confirmation, if any, without firing it. Callers:
   *  a confirmed match (below), a window that ran out with no match, and the
   *  owner on session exit/dispose — a watched transcript path is only ever
   *  this bridge's to read for as long as the session that reported it is
   *  still alive. */
  cancel(sessionId: string): void {
    const state = this.pending.get(sessionId);
    if (!state) return;
    this.deps.clearRepeating(state.handle);
    this.pending.delete(sessionId);
  }

  private async poll(sessionId: string): Promise<void> {
    const state = this.pending.get(sessionId);
    if (!state || state.polling) return;
    state.polling = true;
    try {
      let appended: string;
      try {
        appended = await this.deps.readAppended(state.transcriptPath, state.offset);
      } catch {
        appended = "";
      }
      // A cancel (session exit, or this same tick's own match on a re-entrant
      // call) may have landed while the read above was in flight.
      const current = this.pending.get(sessionId);
      if (current !== state) return;
      if (appended) {
        current.offset += Buffer.byteLength(appended, "utf8");
        const lines = (current.carry + appended).split("\n");
        current.carry = lines.pop() ?? "";
        for (const line of lines) {
          const trimmed = line.trim();
          if (!trimmed) continue;
          let record: unknown;
          try {
            record = JSON.parse(trimmed);
          } catch {
            continue;
          }
          if (current.predicate(record)) {
            this.cancel(sessionId);
            current.onConfirmed();
            return;
          }
        }
      }
      if (this.deps.now() >= current.deadline) this.cancel(sessionId);
    } finally {
      state.polling = false;
    }
  }
}

function defaultReadAppended(path: string, from: number): Promise<string> {
  return (async () => {
    let handle: FileHandle | undefined;
    try {
      handle = await open(path, "r");
      const stat = await handle.stat();
      const length = stat.size - from;
      if (length <= 0) return "";
      const buf = Buffer.alloc(length);
      await handle.read(buf, 0, length, from);
      return buf.toString("utf8");
    } catch {
      return "";
    } finally {
      await handle?.close();
    }
  })();
}

export function createDefaultInterruptConfirmDeps(): InterruptConfirmDeps {
  return {
    now: () => Date.now(),
    setRepeating: (fn, intervalMs) => {
      const handle = setInterval(fn, intervalMs);
      handle.unref?.();
      return handle;
    },
    clearRepeating: (handle) => clearInterval(handle as ReturnType<typeof setInterval>),
    fileSize: (path) => {
      try {
        return statSync(path).size;
      } catch {
        return undefined;
      }
    },
    readAppended: defaultReadAppended,
  };
}

export function createInterruptConfirmer(deps?: InterruptConfirmDeps): InterruptConfirmer {
  return new InterruptConfirmer(deps ?? createDefaultInterruptConfirmDeps());
}
