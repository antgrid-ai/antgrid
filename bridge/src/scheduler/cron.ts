import { CronExpressionParser } from "cron-parser";

export const CRON_PRESETS = {
  hourly: "0 * * * *",
  daily: "0 9 * * *",
  weekdays: "0 9 * * 1-5",
} as const;

export class SchedulerInvalidCronError extends Error {
  readonly code = "SCHEDULER_INVALID_CRON";
}

export function schedulerErrorCode(error: unknown): string {
  return error instanceof SchedulerInvalidCronError ? error.code : "SCHEDULER_ERROR";
}

export function validateTimezone(timezone: string): string {
  if (!timezone || /^[+-]/.test(timezone)) throw new SchedulerInvalidCronError("Choose an IANA timezone, such as Europe/London");
  try { new Intl.DateTimeFormat("en", { timeZone: timezone }).format(0); }
  catch { throw new SchedulerInvalidCronError("Choose a valid IANA timezone"); }
  return timezone;
}

export function validateCron(expression: string, timezone: string): string {
  const fields = expression.trim().split(/\s+/);
  if (fields.length !== 5) throw new SchedulerInvalidCronError("Cron must contain five fields (minute, hour, day, month, weekday)");
  const item = /^(?:\*|\d+(?:-\d+)?)(?:\/[1-9]\d*)?$/;
  if (!fields.every((field) => field.split(",").every((part) => item.test(part)))) {
    throw new SchedulerInvalidCronError("Use numeric cron fields, wildcards, lists, ranges, and steps only");
  }
  validateTimezone(timezone);
  const normalized = fields.join(" ");
  // Parser strict mode rejects the standard DOM/DOW union and five-field form.
  try { CronExpressionParser.parse(normalized, { tz: timezone }).next(); }
  catch (error) { throw new SchedulerInvalidCronError(error instanceof Error ? error.message : "Invalid cron expression"); }
  return normalized;
}

export function nextOccurrences(expression: string, timezone: string, after: number, count = 5): number[] {
  const cron = validateCron(expression, timezone);
  const interval = CronExpressionParser.parse(cron, { tz: timezone, currentDate: new Date(after) });
  return interval.take(count).map((date) => date.getTime());
}
