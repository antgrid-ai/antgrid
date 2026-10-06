import { z } from "zod";
import { ScheduleInputSchema, SchedulePatchSchema } from "./models";

const IdParams = z.object({ id: z.string().min(1) }).strict();
export const SchedulerRequestSchemas: Record<string, z.ZodType> = {
  "scheduler.capabilities": z.object({}).strict(),
  "scheduler.list": z.object({}).strict(),
  "scheduler.preview": z.object({ cron: z.string(), timezone: z.string() }).strict(),
  "scheduler.create": z.object({ schedule: ScheduleInputSchema }).strict(),
  "scheduler.update": z.object({ id: z.string().min(1), patch: SchedulePatchSchema }).strict(),
  "scheduler.delete": IdParams,
  "scheduler.runNow": IdParams,
  "scheduler.runs": z.object({ scheduleId: z.string().min(1).optional() }).strict(),
  "scheduler.stop": IdParams,
};
