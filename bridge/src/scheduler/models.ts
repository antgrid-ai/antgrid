import { z } from "zod";

// Fields carry no defaults here: the patch schema is built from them, and a Zod 4
// `.partial()` over a defaulted field would re-apply the default to an absent key,
// so a pause (`{enabled:false}`) would silently reset approvalPolicy and catchUp.
const scheduleFields = {
  name: z.string().trim().min(1).max(160),
  projectId: z.string().min(1),
  agentId: z.string().min(1),
  mode: z.enum(["terminal", "chat"]),
  prompt: z.string().min(1).max(100_000),
  approvalPolicy: z.enum(["default", "bypass"]),
  workspace: z.enum(["shared", "worktree"]),
  baseBranch: z.string().min(1).optional(),
  cron: z.string().min(1),
  // Epoch ms of a one-off. The host resolves wall-clock strings to this before validation.
  runAt: z.number().int().positive(),
  timezone: z.string().min(1),
  enabled: z.boolean(),
  catchUp: z.enum(["latest", "skip"]),
};
const exactlyOneKind = { message: "A schedule needs exactly one of cron (recurring) or runAt (one-off)" };
const ScheduleInputBase = z.object({
  ...scheduleFields,
  approvalPolicy: scheduleFields.approvalPolicy.default("default"),
  enabled: scheduleFields.enabled.default(true),
  catchUp: scheduleFields.catchUp.default("latest"),
  cron: scheduleFields.cron.optional(),
  runAt: scheduleFields.runAt.optional(),
}).strict();
/** Field names, for callers that rebuild an input from a stored record. */
export const SCHEDULE_INPUT_KEYS = Object.keys(ScheduleInputBase.shape) as (keyof ScheduleInput)[];
export const ScheduleInputSchema = ScheduleInputBase.refine((s) => (s.cron === undefined) !== (s.runAt === undefined), exactlyOneKind);
export const SchedulePatchSchema = z.object(scheduleFields).partial().extend({
  baseBranch: z.string().min(1).nullable().optional(),
}).strict().refine((p) => p.cron === undefined || p.runAt === undefined, { message: "Name cron or runAt in a patch, not both" });
export const ScheduleSchema = ScheduleInputBase.extend({
  id: z.string(),
  authorDeviceId: z.string().nullable(),
  // Display-only provenance for schedules an agent session created or last edited.
  authorSessionId: z.string().optional(),
  authorSessionName: z.string().optional(),
  editedBySessionName: z.string().optional(),
  editedAt: z.number().optional(),
  checkoutId: z.string().optional(),
  workspaceCreated: z.boolean().default(false),
  createdAt: z.number(),
  updatedAt: z.number(),
  nextOccurrence: z.number(),
  // Written in the claim transaction that fires or misses a one-off, so "finished" survives a restart without
  // overloading `enabled`, which keeps meaning "the user paused it".
  firedRunId: z.string().optional(),
  firedAt: z.number().optional(),
  // Set when a due one-off was handed back unconsumed: an overlapping run deferred it, or a settings change re-armed
  // it. The occurrence fell due while the desktop was open, so the next claim runs it even under catch-up "skip".
  deferredAt: z.number().optional(),
  deletedAt: z.number().optional(),
}).refine((s) => (s.cron === undefined) !== (s.runAt === undefined), exactlyOneKind);
export type ScheduleInput = z.infer<typeof ScheduleInputSchema>;
export type SchedulePatch = z.infer<typeof SchedulePatchSchema>;
export type Schedule = z.infer<typeof ScheduleSchema>;

export const RunStatusSchema = z.enum(["preparing", "running", "needs-input", "completed", "failed", "interrupted", "skipped"]);
export const SchedulerRunSchema = z.object({
  id: z.string(), scheduleId: z.string(), scheduleName: z.string(), projectId: z.string(),
  occurrenceAt: z.number(), trigger: z.enum(["cron", "manual", "missed", "catch-up"]),
  timezone: z.string().optional(),
  status: RunStatusSchema, startedAt: z.number(), finishedAt: z.number().optional(),
  reason: z.string().optional(), missedUntil: z.number().optional(),
  missedCount: z.number().int().positive().optional(),
  sessionId: z.string().optional(), runtimeGeneration: z.string().optional(), checkoutId: z.string().optional(),
});
// Mirrored by hand in the app; a consolidated record stores this when the true count is larger.
export const MISSED_COUNT_CAP = 1000;
export type SchedulerRun = z.infer<typeof SchedulerRunSchema>;
export type RunStatus = z.infer<typeof RunStatusSchema>;
export const ACTIVE_RUN_STATUSES: readonly RunStatus[] = ["preparing", "running", "needs-input"];
export function isActiveRun(run: SchedulerRun): boolean { return ACTIVE_RUN_STATUSES.includes(run.status); }

export const SchedulerCapabilitiesSchema = z.object({
  supported: z.boolean(), timezone: z.string(),
  supportsBaseBranchClear: z.boolean().optional(),
  supportsCatchUp: z.boolean().optional(),
  supportsOneOff: z.boolean().optional(),
  agents: z.array(z.object({ agentId: z.string(), modes: z.array(z.enum(["terminal", "chat"])) })),
  error: z.string().optional(),
});
export type SchedulerCapabilities = z.infer<typeof SchedulerCapabilitiesSchema>;
