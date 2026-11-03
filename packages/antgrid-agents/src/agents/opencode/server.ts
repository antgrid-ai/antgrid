import { killChildTree, processGroupSpawn, stripInheritedCertOverrides } from "../../host";
import { stripParentClaudeSession } from "../claude-code/parent-session";
import { resolveToolLaunchPath } from "../launch-path";

export interface OpencodeServerOptions {
  cwd: string;
  env?: Record<string, string>;
  command?: string;
  prefixArgs?: string[];
  signal?: AbortSignal;
  timeoutMs?: number;
}

// A cancelled acquisition rejects with this only when no child remains owned.
export class OpencodeStartupCancelledError extends Error {
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
  close(): Promise<void>;
}> {
  if (opts.signal?.aborted) throw new OpencodeStartupCancelledError();
  const env = stripInheritedCertOverrides({
    ...stripParentClaudeSession(process.env), ...opts.env,
  } as Record<string, string>);
  const proc = Bun.spawn([
    resolveToolLaunchPath(opts.command ?? "opencode", env.PATH ?? env.Path),
    ...(opts.prefixArgs ?? []), "serve", "--hostname", "127.0.0.1", "--port", "0",
  ], {
    cwd: opts.cwd, env, ...processGroupSpawn(),
    stdin: "ignore", stdout: "pipe", stderr: "pipe",
  });
  let closing: Promise<void> | undefined;
  const close = () => closing ??= (async () => {
    await killChildTree(proc);
    let timer: ReturnType<typeof setTimeout> | undefined;
    try {
      await Promise.race([
        proc.exited,
        new Promise<never>((_, reject) => {
          timer = setTimeout(() => reject(new Error("OpenCode process did not exit after termination")), 5_000);
        }),
      ]);
    } finally { clearTimeout(timer); }
  })();

  let ready!: (url: string) => void;
  let fail!: (error: Error) => void;
  const started = new Promise<string>((resolve, reject) => { ready = resolve; fail = reject; });
  let stderr = "";
  let stdout = "";
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
    stdout = (stdout + chunk).slice(-8_192);
    const match = /opencode server listening on (http:\/\/127\.0\.0\.1:\d+)(?=\s)/.exec(stdout);
    if (match) ready(match[1]!);
  });
  void proc.exited.then(async (code) => {
    await stderrDone;
    fail(new Error(`OpenCode server exited (${code})${stderr ? `: ${stderr.trim()}` : ""}`));
  }, (error) => fail(error));
  const abort = () => fail(new OpencodeStartupCancelledError());
  opts.signal?.addEventListener("abort", abort, { once: true });
  if (opts.signal?.aborted) abort();
  const timeout = setTimeout(() => fail(new Error("OpenCode server startup timed out")), opts.timeoutMs ?? 15_000);
  try {
    const password = env.OPENCODE_SERVER_PASSWORD;
    const headers = password ? {
      Authorization: `Basic ${Buffer.from(`${env.OPENCODE_SERVER_USERNAME || "opencode"}:${password}`).toString("base64")}`,
    } : undefined;
    return { url: await started, headers, close };
  } catch (error) {
    await close();
    throw error;
  } finally {
    clearTimeout(timeout);
    opts.signal?.removeEventListener("abort", abort);
  }
}
