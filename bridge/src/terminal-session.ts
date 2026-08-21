import { spawn as ptySpawn } from "bun-pty";
import type { IPty, IDisposable } from "bun-pty";
import { execFileSync } from "node:child_process";
import { appendFileSync, mkdirSync } from "node:fs";
import { delimiter, dirname, extname } from "node:path";
import { logger } from "./logger";
const log = logger.child({ component: "terminal-session" });
import { createMessage, type AbMessage } from "./protocol";
import { findOnPath } from "./tool-detector";
import { TerminalNotificationScanner, type NotificationEvent } from "./notification-scanner";
import { VtCapabilityResponder } from "./vt-capability-responder";

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
    log.warn(`PTY log write failed: ${(e as Error).message}`);
  }
}

/**
 * Spawn options that put a child where `killProcessTree` can reach past it.
 *
 * POSIX kills a process GROUP, which exists only if the child leads one, and
 * `detached` is what makes it lead one — so this is not a preference, it is the
 * precondition for the POSIX half of `killProcessTree` doing anything at all.
 * Windows walks parent links instead and needs no such setup, where `detached`
 * would only cost a console window. Keep the two in lockstep.
 *
 * A PTY child needs none of this: its own `setsid` already made it a session
 * leader.
 */
export function processGroupSpawn(platform: NodeJS.Platform = process.platform): { detached: boolean } {
  return { detached: platform !== "win32" };
}

/**
 * Kill `pid` and everything it started.
 *
 * `IPty.kill()` and `ChildProcess.kill()` each signal one process, and it is
 * the survivors that matter. On Windows every one of them holds its working
 * directory open — a shell's children, and the headless `conhost.exe` each
 * console child gets — and a single orphan is enough to make
 * `git worktree remove` abort mid-tree, which strands an isolated session in a
 * state no retry can clear (Git deletes `.git` early in that sweep, a later
 * prune reaps the registration, and what is left is a directory Git will not
 * touch again). POSIX unlinks a directory out from under a running process
 * quite happily, so there an orphan blocks no delete — but it is still a
 * process nobody will ever reap, holding whatever it held.
 *
 * The two platforms are reached differently and fail differently. Windows walks
 * parent links, so the tree must die BEFORE the leader: once the leader exits
 * its children are re-parented out of reach. POSIX names the process group,
 * which needs no ordering — but a pid that leads no group names no group, and
 * the signal is then a harmless ESRCH that quietly reaches nothing. That is why
 * callers spawning outside a PTY must pass `processGroupSpawn()`.
 *
 * Synchronous on Windows because the session delete that awaits teardown has to
 * see the handles actually released, not merely requested.
 *
 * Exported because PTYs are not the only thing a checkout's runtime leaves
 * running: `command:run` children are spawned through a shell, so killing the
 * process handle alone reaches the wrapper and nothing under it.
 */
export function killProcessTree(pid: number): void {
  if (!Number.isInteger(pid) || pid <= 0) return;
  if (process.platform !== "win32") {
    try {
      process.kill(-pid, "SIGKILL");
    } catch {
      // No group carries this id, so there is nothing here that the caller's
      // own kill of the leader does not already reach.
    }
    return;
  }
  try {
    execFileSync("taskkill", ["/F", "/T", "/PID", String(pid)], {
      timeout: 5_000,
      stdio: "ignore",
      windowsHide: true,
    });
  } catch {
    // Already gone, never started, or refused: `kill()` still signals the
    // leader afterwards, and a delete that goes on to fail reports why.
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
  /** The agent whose per-spawn injection includes a SessionStart hook pinging
   *  /hook-alive, or absent when this spawn's agent declares no such probe
   *  (`injectsHookAliveProbe`). Carries the key rather than a flag so the drift
   *  probe's warning can name the agent that actually went quiet. Distinct from
   *  suppressOscNotifications, which is set for every plugin-source agent. */
  hookAliveProbeAgent?: string;
}

const BATCH_INTERVAL_MS = 16;
const BATCH_MAX_BYTES = 4096;

/**
 * Some dev orchestrators inject network overrides into every child process
 * that break a spawned tool's TLS to the public internet, depending on which
 * env vars that tool's HTTP stack honors:
 *  - SSL_CERT_DIR / SSL_CERT_FILE (OpenSSL-style cert-bundle override,
 *    pointing at a private dev/OTLP cert dir with none of the public root
 *    CAs): honored by Codex's rustls WebSocket transport (rustls-native-certs)
 *    → `invalid peer certificate: UnknownIssuer`. Go's crypto/x509 does NOT
 *    read these on Windows (root_unix.go-only upstream), so this half is a
 *    no-op for a Go-built tool like antigravity's `agy`.
 *  - HTTP_PROXY / HTTPS_PROXY: honored by net/http on every platform
 *    (http.ProxyFromEnvironment) — including Go, unlike the cert-bundle vars
 *    above. If the orchestrator's injected proxy TLS-intercepts with a cert
 *    the child doesn't trust, this is the vector that actually bites a Go
 *    binary: confirmed as agy's `tls: failed to verify certificate: x509:
 *    certificate signed by unknown authority` calling
 *    daily-cloudcode-pa.googleapis.com when spawned under aspire, while a
 *    plain terminal (no inherited proxy) authenticates fine.
 * schannel-based HTTPS (which ignores SSL_CERT_*) still works either way.
 * Spawned terminals/agents talk to the public internet and the relay, never
 * to the orchestrator's services over TLS, so every one of these overrides is
 * pure downside for them.
 *
 * When the orchestrator opts in by setting ANTGRID_STRIP_INHERITED_CERT_OVERRIDES,
 * drop all of them so children fall back to the system trust store and a
 * direct connection. This is a generic mechanism; the dev launcher owns the
 * decision to enable it (the shipped app never sets the flag, so a user's
 * deliberate SSL_CERT_* / *_PROXY config is always preserved).
 */
const OVERRIDE_VARS = [
  "SSL_CERT_DIR",
  "SSL_CERT_FILE",
  "HTTP_PROXY",
  "HTTPS_PROXY",
  "ALL_PROXY",
  "http_proxy",
  "https_proxy",
  "all_proxy",
] as const;

export function stripInheritedCertOverrides(
  env: Record<string, string>,
): Record<string, string> {
  if (!process.env.ANTGRID_STRIP_INHERITED_CERT_OVERRIDES) return env;
  const out = { ...env };
  for (const k of OVERRIDE_VARS) delete out[k];
  return out;
}

/**
 * True for antigravity's `agy`/`agy.EXE` shim, bare or pathful. agy.EXE is a
 * real PE binary but is deliberately routed through cmd.exe on Windows rather
 * than direct-ConPTY-spawned like other .exe agents — see the isAgy usage in
 * spawn() for why (confirmed A/B: agy launched directly, outside any
 * ConPTY-attached spawn, completes its OAuth/eligibility check fine; the
 * identical binary, same user/machine/moment, fails every outbound HTTPS call
 * with `tls: ... certificate signed by unknown authority` only when bun-pty
 * makes it the direct ConPTY child).
 */
export function isAntigravityBinary(command: string): boolean {
  return /(^|[\\/])agy(\.exe)?$/i.test(command);
}

/**
 * Warms Windows' CryptoAPI intermediate-certificate cache for agy's target
 * host before spawning it. Go's crypto/x509 on Windows verifies via
 * CertGetCertificateChain with CACHE-ONLY lookups — unlike browsers/.NET, it
 * never fetches a missing intermediate CA over the network. If the
 * intermediate for daily-cloudcode-pa.googleapis.com isn't already cached in
 * this Windows profile, agy fails outright with `certificate signed by
 * unknown authority`. Confirmed live: with SSL_CERT_* / proxy vars already
 * stripped and the env otherwise identical, a plain PowerShell request
 * (Invoke-WebRequest → .NET → SChannel, which DOES fetch-and-cache missing
 * intermediates) against the same host succeeds every time — the failure is
 * specific to Go's cache-only lookup, not the environment or network path.
 *
 * Synchronous and blocking (not fire-and-forget): agy can fire its own HTTPS
 * call within ~1-2s of spawn, faster than an async priming request reliably
 * wins the race (that's what the async version of this probe demonstrated —
 * it usually completed just AFTER agy's own failing call). The priming has
 * to land before the PTY exists, not concurrently with it. Bounded by a
 * short timeout and fails open — a network hiccup here must never block
 * opening the terminal, since agy would then just show its normal error.
 *
 * Windows' CryptoAPI intermediate cache is machine/profile-level, so one
 * successful prime serves every agy spawn for this bridge's lifetime. We
 * memoize on success to pay the (event-loop-blocking) PowerShell cost at most
 * once per process — a failed prime is NOT recorded, so a later spawn retries.
 */
let antigravityCertCachePrimed = false;
function primeAntigravityCertCache(env: Record<string, string>): void {
  if (process.platform !== "win32" || antigravityCertCachePrimed) return;
  const script =
    "try { Invoke-WebRequest -UseBasicParsing -Uri https://daily-cloudcode-pa.googleapis.com -Method Head -TimeoutSec 4 | Out-Null; Write-Output 'CERT-CACHE-PRIME-OK' } catch { Write-Output ('CERT-CACHE-PRIME-DONE ' + $_.Exception.Message) }";
  try {
    const out = execFileSync(
      "powershell.exe",
      ["-NoProfile", "-NonInteractive", "-Command", script],
      { env, timeout: 5_000, encoding: "utf8" },
    ).trim();
    antigravityCertCachePrimed = true;
    logger.info(`antigravity cert-cache prime: ${out}`);
  } catch (e) {
    logger.warn(`antigravity cert-cache prime failed, continuing spawn anyway: ${(e as Error).message}`);
  }
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
  private _hookAliveProbeAgent?: string;

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
    this._hookAliveProbeAgent = opts.hookAliveProbeAgent;

    this.shell = opts.shell ?? this.detectShell();
    this.name = opts.name ?? opts.command ?? this.shell;
  }

  get cols(): number { return this._cols; }
  get rows(): number { return this._rows; }
  get driverClientId(): string | null { return this._driverClientId; }
  get isRunning(): boolean { return this._running; }
  get shellBinary(): string { return this.command ?? this.shell; }
  // The agent whose injection includes a SessionStart /hook-alive ping — the
  // drift probe arms for these and no others, and names this in its warning.
  get hookAliveProbeAgent(): string | undefined { return this._hookAliveProbeAgent; }

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
        if (/\.(cmd|bat)$/i.test(this.command) || isAntigravityBinary(this.command)) {
          needsShell = true; // explicit shim / ConPTY-direct-spawn workaround (see isAntigravityBinary)
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
    log.info(`Spawning terminal "${this.terminalId}": ${cmd} ${args.join(" ")} (${this._cols}x${this._rows})`);

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

    if (isAntigravityBinary(this.command ?? "")) {
      primeAntigravityCertCache(env);
    }

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
        log.info(`Terminal "${this.terminalId}" exited with code ${exitCode}`);
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
    log.info(`Terminal "${this.terminalId}" resized to ${cols}x${rows} by ${clientId}`);
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
   * Answer the VT capability queries the spawned process emits at startup.
   * The responder is stateful (it carries a query split across PTY chunks and
   * follows the guest's own mode changes), so it must live for the whole
   * session — see `vt-capability-responder.ts` for why this side answers at
   * all and why it is the only side that does.
   *
   * The colours are Antgrid's design tokens and must stay in lockstep with
   * `AbColors` (`app/lib/design/ab_colors.dart`): they are what the guest
   * picks its own contrast against.
   */
  private capabilityResponder = new VtCapabilityResponder({
    foreground: "rgb:fafa/fafa/fafa", // ≈ textPrimary
    background: "rgb:0909/0909/0b0b", // ≈ bgDeepest
    cursor: "rgb:8181/8c8c/f8f8", //     ≈ accent indigo
  });

  private respondToCapabilityQueries(data: string): void {
    const replies = this.capabilityResponder.feed(data);
    if (replies === "") return;
    try {
      this.pty?.write(replies);
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
    const pid = this.pty?.pid;
    if (pid !== undefined) killProcessTree(pid);
    this.pty?.kill();
  }
}
