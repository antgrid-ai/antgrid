import { z } from "zod";

/**
 * Every outcome the team forms report back to `/team`, as `?invite=<code>`.
 *
 * A closed enum rather than a message in the query string: the wording stays
 * server-side and out of a parameter anyone can hand a signed-in owner, which is
 * how `?cancel=` already works on the dashboard. Both ends narrow through this
 * schema, so a code one side stops producing is a type error on the other rather
 * than a silently unrendered redirect.
 */
export const TeamNoticeSchema = z.enum([
  "sent",
  "resent",
  "revoked",
  "accepted",
  "send_failed",
  "seat_cap",
  "over_subscribed",
  "already_member",
  "already_invited",
  "invalid_email",
  "no_subscription",
  "removed",
  "left",
  "last_owner",
  "account_owner",
  "not_a_member",
  "forbidden",
  "throttled",
  "failed",
]);
export type TeamNotice = z.infer<typeof TeamNoticeSchema>;

export function parseTeamNotice(raw: string | null | undefined): TeamNotice | null {
  const parsed = TeamNoticeSchema.safeParse(raw);
  return parsed.success ? parsed.data : null;
}
