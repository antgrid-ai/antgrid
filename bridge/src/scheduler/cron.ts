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

export interface MissedOccurrences {
  /** Last occurrence at or before `now`. */
  latest: number;
  /** The occurrence before `latest`, present only when `count > 1`. */
  previous?: number;
  /** Occurrences in [firstMissed, now], stopping at `cap`. */
  count: number;
  /** First occurrence after `now` on the same timetable. */
  following: number;
}

const FALLBACK_ANCHOR_MS = 3 * 60 * 60_000;

/**
 * Walks the forward `next()` timetable from `firstMissed`, which must itself be an instant that timetable produced
 * (a stored nextOccurrence). Every answer comes off that one chain because cron-parser's `next()` and `prev()`
 * disagree around DST: on a spring-forward day `next()` shifts a nonexistent 02:30 to 03:30 while `prev()` never
 * yields that day, and `next()` started inside the gap skips it too; in a repeated hour `prev()` yields the second
 * instance, which `next()` never emits for a fixed-hour cron.
 */
export function missedOccurrences(expression: string, timezone: string, firstMissed: number, now: number, cap: number): MissedOccurrences | null {
  const cron = validateCron(expression, timezone);
  if (firstMissed > now) return null;
  const forward = CronExpressionParser.parse(cron, { tz: timezone, currentDate: new Date(firstMissed) });
  let latest = firstMissed;
  let previous: number | undefined;
  let count = 1;
  let following = forward.next().getTime();
  while (following <= now && count < cap) {
    previous = latest;
    latest = following;
    count++;
    following = forward.next().getTime();
  }
  if (following > now) return { latest, count, following, ...(previous !== undefined ? { previous } : {}) };
  // Past the cap the chain is too long to walk, so re-seed it shortly before `now`: three occurrences back via
  // prev(), and at least a few hours back so a DST transition just before `now` is walked forward, not via prev().
  let anchor = now + 1;
  for (let i = 0; i < 3; i++) anchor = CronExpressionParser.parse(cron, { tz: timezone, currentDate: new Date(anchor) }).prev().getTime();
  const tail = CronExpressionParser.parse(cron, { tz: timezone, currentDate: new Date(Math.min(anchor, now - FALLBACK_ANCHOR_MS) - 1) });
  let tailLatest: number | undefined;
  let tailPrevious: number | undefined;
  for (let t = tail.next().getTime(); ; t = tail.next().getTime()) {
    if (t > now) { following = t; break; }
    tailPrevious = tailLatest;
    tailLatest = t;
  }
  latest = tailLatest ?? latest;
  previous = tailPrevious ?? CronExpressionParser.parse(cron, { tz: timezone, currentDate: new Date(latest) }).prev().getTime();
  return { latest, previous, count, following };
}
