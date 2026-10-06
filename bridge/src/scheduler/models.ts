import { z } from "zod";

export const ScheduleInputSchema = z.object({
  name: z.string().trim().min(1).max(160),
  projectId: z.string().min(1),
  agentId: z.string().min(1),
  mode: z.enum(["terminal", "chat"]),
  prompt: z.string().min(1).max(100_000),
  approvalPolicy: z.enum(["default", "bypass"]).default("default"),
  workspace: z.enum(["shared", "worktree"]),
  baseBranch: z.string().min(1).optional(),
  cron: z.string().min(1),
  timezone: z.string().min(1),
  enabled: z.boolean().default(true),
}).strict();
export const SchedulePatchSchema = ScheduleInputSchema.partial().extend({
  baseBranch: z.string().min(1).nullable().optional(),
});
export const ScheduleSchema = ScheduleInputSchema.extend({
  id: z.string(),
  authorDeviceId: z.string().nullable(),
  checkoutId: z.string().optional(),
  workspaceCreated: z.boolean().default(false),
  createdAt: z.number(),
  updatedAt: z.number(),
  nextOccurrence: z.number(),
  deletedAt: z.number().optional(),
});
export type ScheduleInput = z.infer<typeof ScheduleInputSchema>;
export type SchedulePatch = z.infer<typeof SchedulePatchSchema>;
export type Schedule = z.infer<typeof ScheduleSchema>;

export const RunStatusSchema = z.enum(["preparing", "running", "needs-input", "completed", "failed", "interrupted", "skipped"]);
export const SchedulerRunSchema = z.object({
  id: z.string(), scheduleId: z.string(), scheduleName: z.string(), projectId: z.string(),
  occurrenceAt: z.number(), trigger: z.enum(["cron", "manual", "missed"]),
  timezone: z.string().optional(),
  status: RunStatusSchema, startedAt: z.number(), finishedAt: z.number().optional(),
  reason: z.string().optional(), missedUntil: z.number().optional(),
  sessionId: z.string().optional(), runtimeGeneration: z.string().optional(), checkoutId: z.string().optional(),
});
export type SchedulerRun = z.infer<typeof SchedulerRunSchema>;
export type RunStatus = z.infer<typeof RunStatusSchema>;
export const ACTIVE_RUN_STATUSES: readonly RunStatus[] = ["preparing", "running", "needs-input"];
export function isActiveRun(run: SchedulerRun): boolean { return ACTIVE_RUN_STATUSES.includes(run.status); }

export const SchedulerCapabilitiesSchema = z.object({
  supported: z.boolean(), timezone: z.string(),
  supportsBaseBranchClear: z.boolean().optional(),
  agents: z.array(z.object({ agentId: z.string(), modes: z.array(z.enum(["terminal", "chat"])) })),
  error: z.string().optional(),
});
export type SchedulerCapabilities = z.infer<typeof SchedulerCapabilitiesSchema>;
