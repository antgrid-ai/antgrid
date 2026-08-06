import { JsonRpcEndpoint } from "./jsonrpc-stdio";
import { resolveToolLaunchPath } from "../launch-path";
import { stripInheritedCertOverrides } from "../../terminal-session";

export interface SpawnedCodex {
  endpoint: JsonRpcEndpoint;
  /** Resolves only once the codex process has fully exited — see the kill impl. */
  kill: () => Promise<void>;
  /**
   * Settles when codex's stderr closes (i.e. the process is gone): a
   * user-facing explanation if the captured stderr matched a known fatal
   * spawn error, else null. Never settles while the process lives — bound any
   * await on it with a timeout.
   */
  failureDiagnosis: Promise<string | null>;
}

// Map codex's fatal spawn-time stderr to actionable user-facing guidance.
// Returns null when nothing is recognized. Pure and exported for tests.
//
// The sqlite state runtime allows ONE app-server per CODEX_HOME machine-wide;
// the Codex desktop app and IDE extensions each run their own app-server, so
// any of them being open makes our spawn fail at initialize with this line.
export function diagnoseCodexStderr(stderrText: string): string | null {
  if (stderrText.includes("failed to initialize sqlite state runtime")) {
    return (
      "Codex is already in use by another app on this machine — its ~/.codex " +
      "state database is locked (usually the Codex desktop app or an IDE " +
      "extension). Close it and try again."
    );
  }
  return null;
}

/**
 * Spawn `codex app-server` and wrap its stdio in a JSON-RPC endpoint.
 * Codex speaks NDJSON JSON-RPC over stdin/stdout.
 * On Windows, `codex` resolves via the shell PATH shim; Bun.spawn handles the
 * .cmd/.exe resolution when given the bare name.
 */
export function spawnCodex(opts: {
  cwd: string;
  command?: string;
  args?: string[];
  env?: Record<string, string>;
}): SpawnedCodex {
  const command = opts.command ?? "codex";
  const args = opts.args ?? ["app-server"];
  // Match the PTY path (terminal-session.ts): under Aspire, DCP injects
  // SSL_CERT_DIR/SSL_CERT_FILE at a dev-cert dir with no public root CAs, which
  // makes codex's rustls WebSocket to chatgpt.com fail with UnknownIssuer. Strip
  // them (dev-only flag) so codex falls back to the system trust store.
  const env = stripInheritedCertOverrides({
    ...process.env,
    ...(opts.env ?? {}),
  } as Record<string, string>);
  // Resolve `command` to codex's REAL on-disk path before spawning. codex finds
  // its Windows sandbox helper (codex-windows-sandbox-setup.exe) relative to
  // std::env::current_exe() as `<exe>/../codex-resources/` from the launch path
  // verbatim, NOT canonicalized. The installer's PATH junction
  // (…\Programs\OpenAI\Codex\bin -> …\standalone\current\bin) collapses the
  // `current` level where codex-resources lives, so spawning via the junction
  // makes `bin/../codex-resources` miss and every sandboxed shell exec dies with
  // "codex-windows-sandbox-setup.exe … program not found". realpath (inside
  // resolveToolLaunchPath) restores the collapsed level. No-op on posix.
  const launchPath = resolveToolLaunchPath(command, env.PATH ?? env.Path);
  const proc = Bun.spawn([launchPath, ...args], {
    cwd: opts.cwd,
    env,
    stdin: "pipe",
    stdout: "pipe",
    // Piped AND continuously drained below (an unconsumed pipe would block
    // codex on a full OS buffer). Each chunk is forwarded to the bridge's own
    // stderr — preserving the old "inherit" diagnostics flow — while a bounded
    // tail is kept so fatal spawn errors can be diagnosed for the app.
    stderr: "pipe",
  });

  // Drain stderr: forward + keep a bounded tail for diagnosis at stream end.
  const failureDiagnosis: Promise<string | null> = (async () => {
    const reader = (proc.stderr as ReadableStream<Uint8Array>).getReader();
    const decoder = new TextDecoder();
    let tail = "";
    try {
      while (true) {
        const { value, done } = await reader.read();
        if (done) break;
        process.stderr.write(value);
        tail += decoder.decode(value, { stream: true });
        // The error line appears within the first KBs of output; a bounded
        // tail caps memory if codex ever gets stderr-chatty.
        if (tail.length > 16_384) tail = tail.slice(-8_192);
      }
    } catch {
      // Reader torn down mid-flight (kill) — diagnose whatever was captured.
    }
    return diagnoseCodexStderr(tail);
  })();

  // proc.stdin is a Bun FileSink; write() accepts string directly.
  const stdin = proc.stdin;

  // Split stdout bytes into newline-delimited text lines.
  const lines = new ReadableStream<string>({
    async start(controller) {
      const reader = (proc.stdout as ReadableStream<Uint8Array>).getReader();
      const decoder = new TextDecoder();
      let buf = "";
      try {
        while (true) {
          const { value, done } = await reader.read();
          if (done) break;
          buf += decoder.decode(value, { stream: true });
          let nl: number;
          while ((nl = buf.indexOf("\n")) >= 0) {
            const line = buf.slice(0, nl);
            buf = buf.slice(nl + 1);
            controller.enqueue(line);
          }
        }
      } finally {
        if (buf.trim()) controller.enqueue(buf);
        controller.close();
      }
    },
  });

  const endpoint = new JsonRpcEndpoint({
    readLines: lines,
    // The endpoint does not append newlines; we add "\n" here for NDJSON framing.
    writeLine: (line) => { void stdin.write(line + "\n"); },
  });

  // If codex exits on its own, dispose the endpoint so pending requests reject
  // promptly. (stdout-close also triggers rejection via the read loop; exit is
  // the definitive signal and covers a process that dies without closing stdout.)
  void proc.exited.then(() => endpoint.dispose());

  return {
    endpoint,
    failureDiagnosis,
    kill: async () => {
      endpoint.dispose();
      void stdin.end();
      proc.kill();
      // Codex funnels all app-server state through a single sqlite DB under
      // ~/.codex and holds its lock for the process's whole lifetime. A restart
      // that spawns a new app-server before this one has exited fails hard at
      // initialize ("failed to initialize sqlite state runtime"). Await exit so
      // the lock is released before any successor spawns — a process that ran a
      // turn can take a few hundred ms to go away. (Verified: without this, a
      // stop→immediate-start of a chat session wedges the new codex.) Bounded so a
      // pathological non-reaping kill can't wedge the session's next start forever.
      await Promise.race([proc.exited, Bun.sleep(5_000)]);
    },
  };
}
