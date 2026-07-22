import { spawn as ptySpawn } from "bun-pty";
import type { IPty, IDisposable } from "bun-pty";
import { appendFileSync, mkdirSync } from "node:fs";
import { delimiter, dirname, extname } from "node:path";
import { logger } from "./logger";
import { createMessage, type AbMessage } from "./protocol";
import { findOnPath } from "./tool-detector";
import { TerminalNotificationScanner, type NotificationEvent } from "./notification-scanner";

/**
 * When ANTGRID_DEBUG_PTY_LOG is set, every PTY output chunk is appended to that
 * file path verbatim (raw bytes, including escape sequences). Used for
 * diagnosing terminal-emulator divergences against native terminals (e.g.
 * the opencode popup-shrink bg-attribute leak in kterm/Ghostty vs WT).
 *
 * Example: ANTGRID_DEBUG_PTY_LOG=C:\Users\bhara\Downloads\opencode-trace.bin
 *
 * Compare with `script(1)` / Windows Terminal's typescript output of the
 * same interaction to find the divergent VT op.
 */
const PTY_LOG_PATH = process.env.ANTGRID_DEBUG_PTY_LOG ?? "";
let ptyLogReady = false;
function logPtyChunk(terminalId: string, data: string): void {
  if (!PTY_LOG_PATH) return;
  if (!ptyLogReady) {
    try {
      mkdirSync(dirname(PTY_LOG_PATH), { recursive: true });
    } catch {
      // best-effort
    }
    ptyLogReady = true;
  }
  try {
    // Tag each chunk with a terminal-prefixed marker so multiple terminals
    // captured in the same file can be split apart later. The marker uses an
    // ESC-DCS sequence so it's a no-op to most parsers if the file is replayed.
    const marker = `\x1bP+|antgrid-pty:${terminalId}|\x1b\\`;
    appendFileSync(PTY_LOG_PATH, marker + data, "binary");
  } catch (e) {
    // Don't let logging failures break the agent.
    logger.warn(`PTY log write failed: ${(e as Error).message}`);
  }
}

/**
 * Builds the env record for a spawned PTY. Merges caller keys first so
 * ANTGRID_TERMINAL_ID and ANTGRID_API_PORT always win for their own slots,
 * while unrelated caller keys are preserved. ANTGRID_API_PORT is omitted when
 * no port is available so the absence is unambiguous to consumers.
 */
export function buildSpawnEnv(
  terminalId: string,
  apiPort: number | null | undefined,
  callerEnv: Record<string, string>,
): Record<string, string> {
  return {
    ...callerEnv,
    ANTGRID_TERMINAL_ID: terminalId,
    ...(apiPort != null ? { ANTGRID_API_PORT: String(apiPort) } : {}),
  };
}

/** Scanner event kinds that route to the notification path (never "title"). */
export type NotificationRouteEvent = NotificationEvent & {
  kind: "osc9" | "osc777";
};

/**
 * Routes a single scanner event to the appropriate sink. Title events are
 * directed to the title callback so they never enter the notification/drawer
 * path; every other kind goes to the notification sink.
 *
 * Extracted as a pure function so the routing contract can be unit-tested
 * without spawning a PTY (mirrors `stripInheritedCertOverrides`).
 */
export function routeScannerEvent(
  ev: NotificationEvent,
  onTitle: ((title: string) => void) | undefined,
  onNotification: (ev: NotificationRouteEvent) => void,
): void {
  if (ev.kind === "title") {
    // Empty title = clear request; ignore so it never wipes a good name.
    if (ev.title) onTitle?.(ev.title);
    return;
  }
  onNotification(ev as NotificationRouteEvent);
}

export interface TerminalSessionOptions {
  terminalId?: string;
  name?: string;
  shell?: string;
  command?: string;
  args?: string[];
  cwd?: string;
  env?: Record<string, string>;
  cols?: number;
  rows?: number;
  type?: "agent" | "service";
  onMessage: (msg: AbMessage) => void;
  /** Called with the agent's OSC 0/2 terminal title (non-empty only). Routed
   *  here instead of terminal:notification so a title never triggers the
   *  desktop-notification/drawer-float path. */
  onTitle?: (title: string) => void;
  /** When true, OSC 9/777 events from the scanner are NOT emitted as
   *  terminal:notification (titles still route). Set for plugin-source agents
   *  whose hooks own notifications, to prevent double-firing. */
  suppressOscNotifications?: boolean;
  /** When true, OSC 0/2 title events from the scanner are NOT forwarded to
   *  onTitle (notifications still route independently). Set for agents whose
   *  hook/plugin already correlates a structured session name, so a stale or
   *  mid-typed terminal-title guess never races the real one. Independent of
   *  suppressOscNotifications — see titleSourceFor vs notificationSourceFor in
   *  known-agents.ts. */
  suppressOscTitle?: boolean;
  /** True only for agents whose per-spawn injection includes a SessionStart hook
   *  that pings /hook-alive (currently codex) — drives the drift probe. Distinct
   *  from suppressOscNotifications, which is true for every plugin-source agent. */
  expectsHookAliveProbe?: boolean;
}

const BATCH_INTERVAL_MS = 16;
const BATCH_MAX_BYTES = 4096;

/**
 * Some dev orchestrators inject the OpenSSL cert-bundle overrides
 * SSL_CERT_DIR / SSL_CERT_FILE into every child process to point them at a
 * private dev/OTLP cert directory that holds none of the public root CAs. Any
 * spawned tool that honors those overrides (notably Codex's rustls WebSocket
 * transport, via rustls-native-certs) then stops reading the OS trust store and
 * fails public TLS with `invalid peer certificate: UnknownIssuer`, while
 * schannel-based HTTPS (which ignores these vars) still works. Spawned
 * terminals/agents talk to the public internet and the relay, never to the
 * orchestrator's services over TLS, so the override is pure downside.
 *
 * When the orchestrator opts in by setting ANTGRID_STRIP_INHERITED_CERT_OVERRIDES,
 * drop both vars so children fall back to the system trust store. This is a
 * generic mechanism; the dev launcher owns the decision to enable it (the
 * shipped app never sets the flag, so a user's deliberate SSL_CERT_* config is
 * always preserved).
 */
export function stripInheritedCertOverrides(
  env: Record<string, string>,
): Record<string, string> {
  if (!process.env.ANTGRID_STRIP_INHERITED_CERT_OVERRIDES) return env;
  const out = { ...env };
  delete out.SSL_CERT_DIR;
  delete out.SSL_CERT_FILE;
  return out;
}

/**
 * Resolve a bare Windows command (no path separator, no extension) against
 * PATH + PATHEXT, returning the first match and its extension. The extension
 * tells us whether the resolved target is a real PE binary (`.exe`/`.com` →
 * ConPTY can exec it directly) or a shim/script (`.cmd`/`.bat`/`.ps1`/… → must
 * go through cmd.exe). Reuses `findOnPath` so the directory/extension search
 * order and the `isFile()` guard stay consistent with tool detection. Returns
 * null if the command isn't found on PATH.
 */
function resolveWinExecutable(command: string): { path: string; ext: string } | null {
  const pathExt = (process.env.PATHEXT ?? ".COM;.EXE;.BAT;.CMD")
    .split(";")
    .map((e) => e.trim())
    .filter(Boolean);
  const dirs = (process.env.PATH ?? "").split(delimiter).filter(Boolean);
  const found = findOnPath(command, dirs, pathExt);
  return found ? { path: found, ext: extname(found).toLowerCase() } : null;
}

export class TerminalSession {
  readonly terminalId: string;
  readonly name: string;
  private shell: string;
  private _cols: number;
  private _rows: number;
  private _driverClientId: string | null = null;
  private command: string | undefined;
  private args: string[];
  private cwd: string | undefined;
  private extraEnv: Record<string, string>;
  readonly type: "agent" | "service" | undefined;
  private onMessage: (msg: AbMessage) => void;
  private onTitle?: (title: string) => void;
  private _running = false;

  private pty: IPty | null = null;
  private disposables: IDisposable[] = [];

  // Output batching — collect chunks, join on flush
  private batchChunks: string[] = [];
  private batchBytes = 0;
  private batchTimer: ReturnType<typeof setTimeout> | null = null;

  private outputObservers = new Set<(data: string) => void>();
  private notificationScanner = new TerminalNotificationScanner();
  private suppressOscNotifications = false;
  private suppressOscTitle = false;
  private _expectsHookAliveProbe = false;

  onOutput(fn: (data: string) => void): () => void {
    this.outputObservers.add(fn);
    return () => {
      this.outputObservers.delete(fn);
    };
  }

  private notifyObservers(data: string): void {
    for (const fn of this.outputObservers) {
      try {
        fn(data);
      } catch {
        // observer errors must not break PTY streaming
      }
    }
  }

  constructor(opts: TerminalSessionOptions) {
    this.terminalId = opts.terminalId ?? "default";
    this._cols = opts.cols ?? 80;
    this._rows = opts.rows ?? 24;
    this.command = opts.command;
    this.args = opts.args ?? [];
    this.cwd = opts.cwd;
    this.extraEnv = opts.env ?? {};
    this.type = opts.type;
    this.onMessage = opts.onMessage;
    this.onTitle = opts.onTitle;
    this.suppressOscNotifications = opts.suppressOscNotifications ?? false;
    this.suppressOscTitle = opts.suppressOscTitle ?? false;
    this._expectsHookAliveProbe = opts.expectsHookAliveProbe ?? false;

    this.shell = opts.shell ?? this.detectShell();
    this.name = opts.name ?? opts.command ?? this.shell;
  }

  get cols(): number { return this._cols; }
  get rows(): number { return this._rows; }
  get driverClientId(): string | null { return this._driverClientId; }
  get isRunning(): boolean { return this._running; }
  get shellBinary(): string { return this.command ?? this.shell; }
  // True only for agents whose injection includes a SessionStart /hook-alive
  // ping (codex) — the drift probe arms for these and no others.
  get expectsHookAliveProbe(): boolean { return this._expectsHookAliveProbe; }

  // Re-enable the OSC scanner after it was suppressed for a plugin-owned agent.
  // Self-healing fallback for when the plugin's hooks never check in: restores
  // the terminal scanner as a best-effort notification net instead of leaving
  // the session permanently muted.
  enableOscNotifications(): void { this.suppressOscNotifications = false; }

  // Re-enable the OSC title scanner after it was suppressed for an agent whose
  // hook was expected to supply the structured name. Same self-healing intent
  // as enableOscNotifications, kept as a separate toggle since the two signals
  // are suppressed independently (see titleSourceFor vs notificationSourceFor).
  enableOscTitle(): void { this.suppressOscTitle = false; }

  private detectShell(): string {
    return process.env.SHELL || (process.platform === "win32" ? "powershell.exe" : "/bin/bash");
  }

  spawn(): void {
    let cmd: string;
    let args: string[];
    if (this.command) {
      // Shell-wrap rules:
      //  - Free-form commands with whitespace (e.g. "npm run serve") need a
      //    shell because PTY treats arg 0 as a literal executable path.
      //  - On Windows, ConPTY can only directly exec a PE binary — it can't run
      //    `.cmd`/`.bat` shims (e.g. `npm`, `claude`, `opencode` under
      //    `~/.bun/bin` or `~/AppData/Roaming/npm`), which must go through
      //    cmd.exe. So we resolve bare names against PATH and direct-spawn
      //    anything that's a true `.exe`/`.com`, reserving the shell wrap for
      //    genuine shims, free-form lines, and unresolved commands.
      //  - WHY prefer direct spawn beyond shim support: bun-pty does not use
      //    Windows CommandLineToArgvW quoting. It serializes argv POSIX-style
      //    (single-quote each token, then `shell_words::split` on the Rust
      //    side) and re-joins for CreateProcess. A pre-joined, hand-quoted
      //    cmd.exe line gets processed twice and corrupted — e.g.
      //    `node -e "console.log('x')"` reaches node with the inner quoting
      //    mangled and prints nothing. Direct-spawning the resolved exe with a
      //    plain argv array skips the cmd.exe re-parse entirely. For the shims
      //    that genuinely need cmd.exe we pass argv as SEPARATE elements (not a
      //    pre-joined line) so each token survives the round-trip; see below.
      const isWin = process.platform === "win32";
      const hasWhitespace = this.args.length === 0 && /\s/.test(this.command);
      let directCmd: string | null = null; // resolved exe to spawn directly
      let needsShell = hasWhitespace;
      if (isWin && !hasWhitespace) {
        const pathful = this.command.includes("\\") || this.command.includes("/");
        if (/\.(cmd|bat)$/i.test(this.command)) {
          needsShell = true; // explicit shim
        } else if (/\.(exe|com)$/i.test(this.command) || pathful) {
          // Already a concrete target (explicit .exe/.com, or a path) — leave
          // it for direct spawn below.
        } else {
          // Bare name: resolve via PATH to tell a real exe from a shim.
          const resolved = resolveWinExecutable(this.command);
          if (resolved && (resolved.ext === ".exe" || resolved.ext === ".com")) {
            directCmd = resolved.path; // real executable — exec it directly
          } else {
            needsShell = true; // .cmd/.bat shim, assoc-run script, or not found
          }
        }
      }
      if (needsShell) {
        if (isWin) {
          // Pass command + args as SEPARATE argv elements, NOT a pre-joined,
          // hand-quoted line. bun-pty's POSIX-style serialization + Rust
          // re-join (see the comment above) corrupts a pre-quoted line —
          // splitting `"a b"` into two tokens and leaking literal quotes.
          // Separate elements survive intact; cmd.exe /c then runs
          // `<command> <args…>`. The free-form whitespace case has no args, so
          // the command travels as a single token. Caveat: raw cmd
          // metacharacters (& | < > ^) inside a discrete arg still aren't
          // escaped — a limitation of bun-pty's POSIX-oriented pipeline, not
          // reachable through the structured args[] our callers use.
          cmd = process.env.ComSpec ?? "cmd.exe";
          args = ["/d", "/s", "/c", this.command, ...this.args];
        } else {
          // POSIX only reaches here for the whitespace free-form case (args is
          // empty), so the command is already a complete `sh -c` line.
          cmd = process.env.SHELL ?? "/bin/sh";
          args = ["-c", this.command];
        }
      } else {
        cmd = directCmd ?? this.command;
        args = this.args;
      }
    } else {
      cmd = this.shell;
      args = [];
    }
    logger.info(`Spawning terminal "${this.terminalId}": ${cmd} ${args.join(" ")} (${this._cols}x${this._rows})`);

    // Announce a terminal identity that agents recognize as OSC-9-capable so
    // they emit rich desktop notifications (with a message) instead of bare
    // BEL. Ghostty is fitting — the app renderer is ghostty-VTE. See design
    // doc; revisit if kitty-graphics attempts cause rendering issues.
    const env = stripInheritedCertOverrides({
      ...process.env,
      TERM_PROGRAM: "ghostty",
      TERM_PROGRAM_VERSION: "1.0.0",
      ...this.extraEnv,
    } as Record<string, string>);

    this.pty = ptySpawn(cmd, args, {
      cols: this._cols,
      rows: this._rows,
      cwd: this.cwd ?? process.cwd(),
      env,
      name: "xterm-256color",
    });

    this._running = true;

    this.onMessage(
      createMessage("terminal:started", {
        terminalId: this.terminalId,
        shell: cmd,
        cols: this._cols,
        ...(this.type ? { terminalType: this.type } : {}),
        rows: this._rows,
      })
    );

    this.disposables.push(
      this.pty.onData((data) => {
        logPtyChunk(this.terminalId, data);
        this.respondToCapabilityQueries(data);
        try {
          for (const ev of this.notificationScanner.feed(data, Date.now())) {
            routeScannerEvent(ev, (title) => {
              if (this.suppressOscTitle) return; // hook owns the structured title
              this.onTitle?.(title);
            }, (notifEv) => {
              if (this.suppressOscNotifications) return; // plugin owns notifications
              this.onMessage(
                createMessage("terminal:notification", {
                  terminalId: this.terminalId,
                  kind: notifEv.kind,
                  ...(notifEv.title !== undefined ? { title: notifEv.title } : {}),
                  ...(notifEv.body !== undefined ? { body: notifEv.body } : {}),
                })
              );
            });
          }
        } catch {
          // scanner must never break PTY streaming
        }
        this.notifyObservers(data);
        this.enqueueBatch(data);
      })
    );

    this.disposables.push(
      this.pty.onExit(({ exitCode }) => {
        this._running = false;
        this.flushBatch();
        this.dispose();
        logger.info(`Terminal "${this.terminalId}" exited with code ${exitCode}`);
        this.onMessage(
          createMessage("terminal:exited", {
            terminalId: this.terminalId,
            exitCode,
          })
        );
      })
    );
  }

  private enqueueBatch(data: string): void {
    this.batchChunks.push(data);
    this.batchBytes += data.length;

    if (this.batchBytes >= BATCH_MAX_BYTES) {
      this.flushBatch();
      return;
    }

    if (!this.batchTimer) {
      this.batchTimer = setTimeout(() => this.flushBatch(), BATCH_INTERVAL_MS);
    }
  }

  private flushBatch(): void {
    if (this.batchTimer) {
      clearTimeout(this.batchTimer);
      this.batchTimer = null;
    }
    if (this.batchChunks.length === 0) return;

    const data = this.batchChunks.length === 1
      ? this.batchChunks[0]
      : this.batchChunks.join("");
    this.batchChunks.length = 0;
    this.batchBytes = 0;

    this.onMessage(
      createMessage("terminal:output", {
        terminalId: this.terminalId,
        data,
      })
    );
  }

  private dispose(): void {
    for (const d of this.disposables) d.dispose();
    this.disposables.length = 0;
  }

  resize(clientId: string, cols: number, rows: number): void {
    this._driverClientId = clientId;
    this._cols = cols;
    this._rows = rows;
    logger.info(`Terminal "${this.terminalId}" resized to ${cols}x${rows} by ${clientId}`);
    try {
      this.pty?.resize(cols, rows);
    } catch {
      // PTY may have already exited
    }
  }

  write(data: string): void {
    try {
      this.pty?.write(data);
    } catch {
      // PTY may have already exited
    }
  }

  /**
   * Detect VT capability queries that the spawned process (e.g. opencode)
   * emits at startup, and write canned responses back into the PTY so the
   * process believes it is talking to a fully-featured terminal.
   *
   * Without responses, modern TUIs like opencode time out and fall back to
   * a "diff/economy" rendering strategy that uses ECH + cursor-skip and
   * leaks popup-bg attributes into cells the popup vacated (the muted
   * "open" half of the opencode banner reproduces this).
   *
   * Pattern matching is per-chunk, so a query split across two PTY chunks
   * will be missed. In practice opencode batches these queries into a
   * single startup write, so this is fine for the common case. Revisit
   * with a small parser-state machine if we hit fragmentation.
   *
   * Modes claimed "set" match the WT capability handshake we observed in
   * the trace diff (`opencode-wt-trace.bin`).
   */
  private respondToCapabilityQueries(data: string): void {
    if (!data.includes("\x1b")) return; // fast path: no escape sequences
    const replies: string[] = [];

    // OSC 10/11/12 — default fg/bg/cursor color queries. Match either ST
    // (\E\\) or BEL (\x07) terminator. Respond with Antgrid's design tokens.
    const oscQuery = /\x1b\][\d]+;\?(?:\x07|\x1b\\)/g;
    for (const m of data.matchAll(oscQuery)) {
      const which = m[0].slice(2, m[0].indexOf(";"));
      const term = m[0].includes("\x07") ? "\x07" : "\x1b\\";
      // 8-bit-per-channel rgb format expected by xterm OSC color responses
      // (rgb:RRRR/GGGG/BBBB or rgb:RR/GG/BB; xterm accepts both).
      const colors: Record<string, string> = {
        "10": "rgb:fafa/fafa/fafa", // default fg ≈ Antgrid textPrimary
        "11": "rgb:0909/0909/0b0b", // default bg ≈ Antgrid bgDeepest
        "12": "rgb:8181/8c8c/f8f8", // cursor    ≈ Antgrid accent indigo
      };
      const rgb = colors[which];
      if (rgb) replies.push(`\x1b]${which};${rgb}${term}`);
    }

    // CSI 6 n — Device Status Report (cursor position). Respond with 1;1
    // — opencode uses this at startup as a sync probe; exact position
    // doesn't matter for capability detection.
    if (/\x1b\[6n/.test(data)) replies.push("\x1b[1;1R");

    // CSI > 0 q  /  CSI > q — XTVERSION. Identify ourselves so opencode
    // sees a known terminal. Some TUIs match on the name string.
    if (/\x1b\[>0?q/.test(data)) replies.push("\x1bP>|antgrid(1.0)\x1b\\");

    // CSI c  or  CSI 0 c — DA1 (Primary Device Attributes). Advertise the
    // xterm VT420 feature set including ANSI color (22) — same as a
    // modern xterm.
    if (/\x1b\[(?:0)?c/.test(data) && !/\x1b\[>(?:0)?c/.test(data)) {
      replies.push("\x1b[?64;1;2;6;9;15;18;21;22c");
    }

    // CSI > c  or  CSI > 0 c — DA2 (Secondary). xterm-style
    // (terminal id 1, version 1000, no cartridge ROM).
    if (/\x1b\[>(?:0)?c/.test(data)) replies.push("\x1b[>1;1000;0c");

    // DECRQM — CSI ? n $ p — query DEC private mode state.
    // 0 = not recognised, 1 = set, 2 = reset, 3 = perm-set, 4 = perm-reset.
    // Modes we claim supported match what WT reported in the trace diff.
    const claimedSet = new Set([
      1004, // focus in/out events
      2004, // bracketed paste
      2026, // synchronised output
      2027, // grapheme-cluster width
      2031, // color-scheme change notifications
    ]);
    const decrqm = /\x1b\[\?(\d+)\$p/g;
    for (const m of data.matchAll(decrqm)) {
      const mode = Number(m[1]);
      const state = claimedSet.has(mode) ? 1 : 2;
      replies.push(`\x1b[?${mode};${state}$y`);
    }

    // CSI ? u — Kitty keyboard protocol flags query. We don't implement
    // Kitty kbd yet, so report 0 (no flags). Avoids opencode treating us
    // as a non-responsive terminal.
    if (/\x1b\[\?u/.test(data)) replies.push("\x1b[?0u");

    if (replies.length === 0) return;
    try {
      this.pty?.write(replies.join(""));
    } catch {
      // PTY may have already exited
    }
  }

  killGracefully(): void {
    if (!this.pty || !this._running) return;
    try {
      process.kill(this.pty.pid, "SIGTERM");
    } catch {
      // Process may have already exited
    }
  }

  kill(): void {
    this._running = false;
    this.flushBatch();
    this.pty?.kill();
  }
}
