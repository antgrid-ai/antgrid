import { CronExpressionParser } from "cron-parser";
import { SchedulerRefusal } from "./agent";

export const CRON_PRESETS = {
  hourly: "0 * * * *",
  daily: "0 9 * * *",
  weekdays: "0 9 * * 1-5",
} as const;

export class SchedulerInvalidCronError extends Error {
  readonly code = "SCHEDULER_INVALID_CRON";
}

export function schedulerErrorCode(error: unknown): string {
  if (error instanceof SchedulerRefusal) return error.code;
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

// One-off wall-clock resolution. Local times are mapped to instants by probing the zone's UTC offset a day either
// side of the wall time, so no date library is needed and a transition inside the window shows up as two candidates.
// Strict ISO-8601 only, with or without an offset. Date.parse is never used: it rolls an impossible date such as
// Feb 30 into March and accepts non-ISO forms, which would silently schedule a different day.
const DATE_TIME = /^(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2})(?::(\d{2})(?:\.\d+)?)?(Z|[+-]\d{2}(?::?\d{2})?)?$/i;
const DAY_MS = 86_400_000;

function zoneOffsetMs(instant: number, timezone: string): number {
  const parts = new Intl.DateTimeFormat("en-US", { timeZone: timezone, hourCycle: "h23", year: "numeric", month: "numeric", day: "numeric",
    hour: "numeric", minute: "numeric", second: "numeric" }).formatToParts(new Date(instant));
  const field = (type: string) => Number(parts.find((p) => p.type === type)!.value);
  const wall = Date.UTC(field("year"), field("month") - 1, field("day"), field("hour"), field("minute"), field("second"));
  return wall - Math.floor(instant / 1000) * 1000;
}

/**
 * A number is an instant and is used as is. A string is either ISO-8601 with an offset (an instant) or a local
 * date-time read in `timezone`. A local time inside a spring-forward gap is refused; one in a repeated fall-back hour
 * resolves to its first instance.
 */
export function resolveRunAt(value: string | number, timezone: string): number {
  if (typeof value === "number") {
    if (!Number.isSafeInteger(value) || value <= 0) throw new SchedulerRefusal("INVALID_RUN_AT", "runAt must be a positive epoch-millisecond instant");
    return value;
  }
  const text = value.trim();
  const match = DATE_TIME.exec(text);
  if (!match) {
    throw new SchedulerRefusal("INVALID_RUN_AT", `"${value}" is not a date and time; use a form like 2026-10-09T09:00 or 2026-10-09T09:00+02:00`);
  }
  const [year, month, day, hour, minute, second] = match.slice(1, 7).map((part) => (part === undefined ? 0 : Number(part)));
  const wall = Date.UTC(year!, month! - 1, day!, hour!, minute!, second!);
  const check = new Date(wall);
  if (check.getUTCFullYear() !== year || check.getUTCMonth() !== month! - 1 || check.getUTCDate() !== day
    || check.getUTCHours() !== hour || check.getUTCMinutes() !== minute) {
    throw new SchedulerRefusal("INVALID_RUN_AT", `"${value}" is not a real calendar date and time`);
  }
  const offset = match[7];
  if (offset !== undefined) {
    if (offset.toUpperCase() === "Z") return wall;
    const digits = offset.slice(1).replace(":", "");
    const offsetHours = Number(digits.slice(0, 2));
    const offsetMinutes = digits.length > 2 ? Number(digits.slice(2)) : 0;
    if (offsetHours > 23 || offsetMinutes > 59) throw new SchedulerRefusal("INVALID_RUN_AT", `"${value}" has an invalid UTC offset`);
    return wall - (offset[0] === "-" ? -1 : 1) * (offsetHours * 60 + offsetMinutes) * 60_000;
  }
  validateTimezone(timezone);
  const candidates = [...new Set([zoneOffsetMs(wall - DAY_MS, timezone), zoneOffsetMs(wall + DAY_MS, timezone)])]
    .map((offset) => ({ offset, instant: wall - offset }))
    .filter(({ offset, instant }) => zoneOffsetMs(instant, timezone) === offset)
    .map(({ instant }) => instant);
  if (candidates.length === 0) {
    throw new SchedulerRefusal("INVALID_RUN_AT", `${text} does not exist in ${timezone}: clocks skip forward over it. Choose a time after the change.`);
  }
  return Math.min(...candidates);
}
