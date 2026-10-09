// The contract between an agent session's loopback `/scheduler/*` routes (in the
// core) and the host's scheduler. The core proves WHO is calling; the host and
// the service decide what that caller may do, so no rule lives in the MCP
// process or the route.

export type ApprovalLevel = "gated" | "ungated";

/** Resolved by the core from a run-bound session entry. `projectId` is absent
 *  here: the host binds its own catalog key, because a core's computed id can
 *  differ from the key schedules are stored under. */
export interface AgentCallerIdentity {
  sessionId: string;
  sessionName: string;
  /** Undefined for a custom command or any tool outside the agent registry. */
  agentId?: string;
  mode: "terminal" | "chat";
  approvalLevel: ApprovalLevel;
  /** True when the session entry carries `launchedByScheduleId`. The host also
   *  treats any session that a scheduler run record names as scheduled. */
  scheduled: boolean;
}

export interface AgentCaller extends AgentCallerIdentity {
  projectId: string;
}

export const SCHEDULER_AGENT_METHODS = ["list", "runs", "create", "update", "delete", "runNow"] as const;
export type SchedulerAgentMethod = (typeof SCHEDULER_AGENT_METHODS)[number];

/** What `BuildAgentCoreOptions.schedulerForAgent` carries: the host's
 *  `schedulerRequestForAgent` with its catalog projectId already bound.
 *  Resolves to the success body; rejects with a {@link SchedulerRefusal}. */
export type SchedulerForAgent = (
  caller: AgentCallerIdentity,
  method: SchedulerAgentMethod,
  params: Record<string, unknown>,
) => Promise<Record<string, unknown>>;

// One vocabulary for the route's status and the tool's text, in the
// `SESSION_BUS_ERRORS` pattern. SCHEDULER_INVALID_CRON keeps its shipped name:
// the app's editor keys on that exact string.
export const SCHEDULER_AGENT_ERRORS = {
  NOT_A_SESSION: 403,
  APPROVAL_CEILING: 403,
  SCHEDULED_SESSION_READ_ONLY: 403,
  SCHEDULE_NOT_FOUND: 404,
  SCHEDULE_EXISTS: 409,
  WORKSPACE_LOCKED: 409,
  SCHEDULER_INVALID_CRON: 400,
  INVALID_RUN_AT: 400,
  INVALID_ARGUMENT: 400,
  AGENT_NOT_SCHEDULABLE: 422,
  WORKTREE_UNSUPPORTED: 422,
  SCHEDULER_UNAVAILABLE: 503,
  SCHEDULER_ERROR: 500,
} as const;
export type SchedulerAgentErrorCode = keyof typeof SCHEDULER_AGENT_ERRORS;

export class SchedulerRefusal extends Error {
  constructor(readonly code: SchedulerAgentErrorCode, message: string) {
    super(message);
  }
}
