import { z } from "zod";
import { ScheduleInputSchema, SchedulePatchSchema } from "./models";

const IdParams = z.object({ id: z.string().min(1) }).strict();
// Both preview shapes are strict so a request naming a cron and a runAt is refused rather than half-answered.
const RunAtValue = z.union([z.string().min(1), z.number()]);
export const SchedulerRequestSchemas: Record<string, z.ZodType> = {
  "scheduler.capabilities": z.object({}).strict(),
  "scheduler.list": z.object({}).strict(),
  "scheduler.preview": z.union([
    z.object({ cron: z.string(), timezone: z.string() }).strict(),
    z.object({ runAt: RunAtValue, timezone: z.string() }).strict(),
  ]),
  "scheduler.create": z.object({ schedule: ScheduleInputSchema }).strict(),
  "scheduler.update": z.object({ id: z.string().min(1), patch: SchedulePatchSchema }).strict(),
  "scheduler.delete": IdParams,
  "scheduler.runNow": IdParams,
  "scheduler.runs": z.object({ scheduleId: z.string().min(1).optional() }).strict(),
  "scheduler.stop": IdParams,
};
