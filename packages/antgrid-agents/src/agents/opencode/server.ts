import { killChildTree, processGroupSpawn, stripInheritedCertOverrides } from "../../host";
import { stripParentClaudeSession } from "../claude-code/parent-session";
import { toolSpawnArgs } from "../windows-argv";
import { raceTimeout } from "../race-timeout";
import { z } from "zod";
import { requireOpencodeV2 } from "./version";

export interface OpencodeServerOptions {
  cwd: string;
  env?: Record<string, string>;
  command?: string;
  prefixArgs?: string[];
  signal?: AbortSignal;
  timeoutMs?: number;
}

// Acquisition failures use this only after every allocated child has exited.
export class OpencodeStartupError extends Error {}

export class OpencodeStartupCancelledError extends OpencodeStartupError {
  constructor() {
    super("OpenCode startup cancelled");
    this.name = "OpencodeStartupCancelledError";
  }
}

// The SDK's server helper replaces OPENCODE_CONFIG_CONTENT and cannot set cwd
// or a per-process environment. Owning the spawn preserves native config layers
// and keeps concurrent chat sessions' MCP identities out of process.env.
export async function startOpencodeServer(opts: OpencodeServerOptions): Promise<{
  url: string;
  headers?: Record<string, string>;
  exited?: Promise<number>;
  close(): Promise<void>;
}> {
  if (opts.signal?.aborted) throw new OpencodeStartupCancelledError();
  const env = stripInheritedCertOverrides({
    ...stripParentClaudeSession(process.env), ...opts.env,
  } as Record<string, string>);
  // V2 always authenticates its API; retain native credentials or scope a fresh
  // password to this child rather than parsing a generated secret from stdout.
  env.OPENCODE_PASSWORD ||= env.OPENCODE_SERVER_PASSWORD || crypto.randomUUID();
  const headers = {
    Authorization: `Basic ${Buffer.from(`opencode:${env.OPENCODE_PASSWORD}`).toString("base64")}`,
  };
  const launch = toolSpawnArgs(opts.command ?? "opencode", [
    ...(opts.prefixArgs ?? []), "serve", "--hostname", "127.0.0.1", "--port", "0",
  ], env);
  const proc = (() => {
    try {
      return Bun.spawn(launch.cmd, {
        cwd: opts.cwd, env: launch.env, ...processGroupSpawn(),
        stdin: "ignore", stdout: "pipe", stderr: "pipe",
      });
    } catch (error) {
      throw new OpencodeStartupError(error instanceof Error ? error.message : String(error), { cause: error });
    }
  })();
  let closing: Promise<void> | undefined;
  const close = () => closing ??= (async () => {
    await killChildTree(proc);
    if (!await raceTimeout(proc.exited, 5_000)) throw new Error("OpenCode process did not exit after termination");
  })();

  let ready!: (url: string) => void;
  let fail!: (error: Error) => void;
  const started = new Promise<string>((resolve, reject) => { ready = resolve; fail = reject; });
  let stderr = "";
  let stdout: string | null = "";
  const drain = async (stream: ReadableStream<Uint8Array>, receive: (chunk: string) => void) => {
    const reader = stream.getReader();
    const decoder = new TextDecoder();
    try {
      for (;;) {
        const next = await reader.read();
        if (next.done) break;
        receive(decoder.decode(next.value, { stream: true }));
      }
    } catch (error) {
      fail(error instanceof Error ? error : new Error(String(error)));
    } finally { reader.releaseLock(); }
  };
  const stderrDone = drain(proc.stderr, (chunk) => { stderr = (stderr + chunk).slice(-8_192); });
  void drain(proc.stdout, (chunk) => {
    if (stdout === null) return;
    stdout = (stdout + chunk).slice(-8_192);
    const match = /(?:opencode )?server listening on (http:\/\/127\.0\.0\.1:\d+)(?=\s)/.exec(stdout);
    if (!match) return;
    stdout = null;
    ready(match[1]!);
  });
  void proc.exited.then(async (code) => {
    await stderrDone;
    fail(new Error(`OpenCode server exited (${code})${stderr ? `: ${stderr.trim()}` : ""}`));
  }, fail);
  const startup = new AbortController();
  const rejectStartup = (error: Error) => { startup.abort(error); fail(error); };
  const abort = () => rejectStartup(new OpencodeStartupCancelledError());
  opts.signal?.addEventListener("abort", abort, { once: true });
  const timeout = setTimeout(() => rejectStartup(new Error("OpenCode server startup timed out")), opts.timeoutMs ?? 15_000);
  try {
    const url = await started;
    const response = await fetch(`${url}/api/info`, { headers, signal: startup.signal });
    const info = z.object({ version: z.string() }).safeParse(
      response.ok ? await response.json().catch(() => null) : null,
    );
    const version = info.success ? info.data.version : undefined;
    requireOpencodeV2(version);
    startup.signal.throwIfAborted();
    return { url, headers, close, exited: proc.exited };
  } catch (error) {
    await close();
    if (startup.signal.reason instanceof OpencodeStartupCancelledError) throw startup.signal.reason;
    throw new OpencodeStartupError(error instanceof Error ? error.message : String(error), { cause: error });
  } finally {
    clearTimeout(timeout);
    opts.signal?.removeEventListener("abort", abort);
  }
}
