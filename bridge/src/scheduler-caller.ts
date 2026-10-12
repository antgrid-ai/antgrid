import type { SessionEntry } from "./protocol";
import { SchedulerRefusal, type AgentCallerIdentity } from "./scheduler/agent";

export interface SchedulerCallerDeps {
  session(id: string): SessionEntry | undefined;
  /** Side-effect free: see `SessionManager.isLiveRun`. */
  isLiveRun(id: string, runId: string): boolean;
  launchedBySchedule(id: string): boolean;
  /** The agent the live run `runId` was LAUNCHED as: the session's own tool,
   *  else what its checkout's antgrid.yaml named at that launch (a worktree
   *  reads its own file). Never the file as it reads now, which can have been
   *  edited under a process that is still running the old agent. */
  runAgent(id: string, runId: string): string | undefined;
  /** The registry entry for an agent name, or undefined for anything else. */
  registryAgent(name: string): { defaultApprovalGated?: boolean } | undefined;
}

const NOT_A_SESSION = "This session's Antgrid MCP server did not pass a valid run id. "
  + "Restart the session; if this persists, re-run the Antgrid project setup.";

/**
 * Turns the claimed slot and run id of a loopback call into the identity of the
 * live session behind it, or refuses. The loopback API has no token and
 * `GET /terminals?all=true` lists agent slot ids, so the slot alone proves
 * nothing; the run id is what only the session's own process tree was handed.
 *
 * Every clause is required, and none of this may go through `acceptsHookRun`:
 * that answers true for an id with no entry, and its api-server wrapper treats
 * an absent run id as a lost hook channel and fails the session's observation.
 */
export function resolveSchedulerCaller(
  deps: SchedulerCallerDeps,
  terminalId: string | undefined,
  runId: string | undefined,
): AgentCallerIdentity {
  if (!terminalId || !runId) throw new SchedulerRefusal("NOT_A_SESSION", NOT_A_SESSION);
  const entry = deps.session(terminalId);
  if (!entry || entry.archived || !deps.isLiveRun(terminalId, runId)) {
    throw new SchedulerRefusal("NOT_A_SESSION", NOT_A_SESSION);
  }

  const named = entry.command ? undefined : deps.runAgent(terminalId, runId);
  const agent = named ? deps.registryAgent(named) : undefined;

  // Ungated only on evidence. A custom command, a shell tool or an agent
  // missing from the registry has none, so it falls to gated.
  const ungated = entry.approvalPolicy === "bypass" || (agent !== undefined && agent.defaultApprovalGated === false);

  return {
    sessionId: entry.id,
    sessionName: entry.name,
    ...(agent ? { agentId: named } : {}),
    mode: entry.mode,
    approvalLevel: ungated ? "ungated" : "gated",
    scheduled: deps.launchedBySchedule(entry.id),
  };
}
