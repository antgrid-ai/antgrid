import { redirectLogsToStderr } from "../logger";
import type { HookRunnerDeps } from "../hook-runner";

/**
 * The agent reads this process's stdout as the hook's reply, so the root
 * logger moves to stderr BEFORE the hook runner (and the logger-using agent
 * modules behind it) load: a warning from a failed post would otherwise
 * precede the JSON and make the agent discard or reject the whole output.
 */
export async function runHookCli(agent: string, event: string, payload?: string, deps?: HookRunnerDeps): Promise<void> {
  redirectLogsToStderr();
  const { runHookInvocation } = await import("../hook-runner");
  await runHookInvocation({ agent, event, payload }, deps);
}
