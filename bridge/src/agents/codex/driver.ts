import { CodexDriver } from "./chat-backend";
import { spawnCodex } from "./spawn";
import type { StructuredDriver } from "../../structured/structured-manager";
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

export function createDriver(ctx: DriverCtx): StructuredDriver {
  const chatAug = ctx.chatAugment();
  const spawned = spawnCodex({
    cwd: ctx.projectPath,
    args: [
      "app-server",
      ...codexUnifiedExecArgs(),
      ...(ctx.approvalPolicy === "bypass"
        ? ["-c", 'approval_policy="never"', "-c", 'sandbox_mode="danger-full-access"']
        : []),
      ...codexNotifyOnlyArgs(chatAug.args),
    ],
    env: chatAug.env,
  });
  const driver = new CodexDriver({
    sessionId: ctx.sessionId,
    endpoint: spawned.endpoint,
    sendMessage: ctx.send,
    cwd: ctx.projectPath,
    // failureDiagnosis settles only when the codex process is gone; if
    // start failed while the process somehow lives on, give up quickly
    // and let the original error surface instead of hanging startChat.
    diagnoseStartFailure: () =>
      Promise.race([spawned.failureDiagnosis, Bun.sleep(1_500).then(() => null)]),
  });
  // Tie the spawned process lifetime to the driver's dispose. dispose
  // resolves only once codex has fully exited (spawned.kill awaits
  // proc.exited) so the manager can serialize a stop→start handoff — codex's
  // global ~/.codex sqlite lock must be released before a restart spawns.
  const origDispose = driver.dispose.bind(driver);
  driver.dispose = async () => { origDispose(); await spawned.kill(); };
  // Proactive version check: if the spawned codex is behind npm's latest
  // (and not dismissed via ~/.codex/version.json), nudge the app with a
  // dismissible chip. Same seam as every other tool.
  ctx.emitUpdateCheck();
  return driver;
}
