// `antgrid orchestrator [off|status]` — read or lower this machine's orchestrator
// grant on the account. Raising is deliberately absent; see cli/agent-reach.ts.

import { RAISE_IN_APP, failure, lowerGrants, printStatus, resolveHost, type ReachCliOptions } from "./agent-reach";

export async function runOrchestratorCli(action: string | undefined, opts: ReachCliOptions = {}): Promise<number> {
  const verb = action ?? "status";
  if (verb === "on") {
    console.error(`antgrid orchestrator: ${RAISE_IN_APP}`);
    return 1;
  }
  if (verb !== "off" && verb !== "status") {
    console.error(`antgrid orchestrator: unknown action "${verb}"; use off or status.`);
    return 1;
  }
  const host = resolveHost("orchestrator", opts.dir);
  if (!host) return 1;
  if (verb === "status") return printStatus("orchestrator", host);

  const error = await lowerGrants("orchestrator", host, { orchestrator: false });
  if (error) {
    failure("orchestrator", error);
    return 1;
  }
  console.log("orchestrator is off.");
  return 0;
}
