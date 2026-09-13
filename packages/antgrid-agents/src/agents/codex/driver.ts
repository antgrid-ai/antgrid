import { CodexDriver, type CodexEndpoint } from "./chat-backend";
import { spawnCodex } from "./spawn";
import type { StructuredDriver } from "../../structured/structured-driver";
import type { DriverCtx } from "../types";

// codex app-server rejects the -c hooks.* args that augmentAgentLaunch emits for
// the interactive TUI (its -c parser errors on hooks.state={...} — "expected a
// map"). Titles only need the top-level notify=[...] program, which app-server
// DOES honor, so slice out just that -c pair. See the chat-mode title spike.
export function codexNotifyOnlyArgs(augArgs: string[]): string[] {
  const i = augArgs.findIndex((a) => a.startsWith("notify="));
  if (i < 1) return [];
  return [augArgs[i - 1], augArgs[i]]; // ["-c", "notify=[...]"]
}

// Unified exec (exec_command/write_stdin with persistent background sessions)
// is default-ON everywhere EXCEPT Windows builds (codex features/src/lib.rs:
// `default_enabled: !cfg!(windows)`). Background-task tracking depends on it,
// so force it on explicitly — a no-op where it's already the default. Uses the
// top-level scalar key (safest for app-server's -c parser).
export function codexUnifiedExecArgs(): string[] {
  return ["-c", "experimental_use_unified_exec_tool=true"];
}

type CodexProcess = { endpoint: CodexEndpoint; failureDiagnosis: Promise<string | null>; kill: () => Promise<void> };

export function createDriver(
  ctx: DriverCtx,
  spawn: (opts: Parameters<typeof spawnCodex>[0]) => CodexProcess = spawnCodex,
): StructuredDriver {
  let spawned: CodexProcess | undefined;
  let closed = false;
  const registrations: Array<(endpoint: CodexEndpoint) => void> = [];
  const endpoint: CodexEndpoint = {
    request: (method, params) => {
      if (closed || !spawned) return Promise.reject(new Error("Codex backend is not running"));
      return spawned.endpoint.request(method, params);
    },
    notify: (method, params) => {
      if (!closed && spawned) spawned.endpoint.notify(method, params);
    },
    onNotification: (method, handler) => { registrations.push((ep) => ep.onNotification(method, handler)); },
    onRequest: (method, handler) => { registrations.push((ep) => ep.onRequest(method, handler)); },
    onClose: (handler) => { registrations.push((ep) => ep.onClose(handler)); },
    dispose: () => { closed = true; spawned?.endpoint.dispose(); },
  };
  const driver = new CodexDriver({
    sessionId: ctx.sessionId,
    endpoint,
    sendMessage: ctx.send,
    cwd: ctx.projectPath,
    // failureDiagnosis settles only when the codex process is gone; if
    // start failed while the process somehow lives on, give up quickly
    // and let the original error surface instead of hanging startChat.
    diagnoseStartFailure: () =>
      spawned ? Promise.race([spawned.failureDiagnosis, Bun.sleep(1_500).then(() => null)]) : Promise.resolve(null),
  });
  // Tie the spawned process lifetime to the driver's dispose. dispose
  // resolves only once codex has fully exited (spawned.kill awaits
  // proc.exited) so the manager can serialize a stop→start handoff — codex's
  // global ~/.codex sqlite lock must be released before a restart spawns.
  const origDispose = driver.dispose.bind(driver);
  let disposal: Promise<void> | undefined;
  driver.dispose = () => disposal ??= (async () => {
    try { await origDispose(); }
    finally { closed = true; await spawned?.kill(); }
  })();
  const start = driver.start.bind(driver);
  let starting: Promise<string> | undefined;
  const owned: StructuredDriver = driver;
  owned.start = (resumeId, signal) => {
    if (closed || disposal) return Promise.reject(new Error("Codex backend is disposed"));
    if (signal?.aborted) return Promise.reject(signal.reason);
    return starting ??= (async () => {
      const chatAug = ctx.chatAugment();
      spawned = spawn({
        cwd: ctx.projectPath,
        args: [
          "app-server", ...codexUnifiedExecArgs(),
          ...(ctx.approvalPolicy === "bypass"
            ? ["-c", 'approval_policy="never"', "-c", 'sandbox_mode="danger-full-access"']
            : []),
          ...codexNotifyOnlyArgs(chatAug.args),
        ],
        env: chatAug.env,
      });
      for (const register of registrations) register(spawned.endpoint);
      ctx.emitUpdateCheck();
      return start(resumeId);
    })();
  };
  return driver;
}
