import { z } from "zod";

/**
 * Every outcome the install flow reports back to `/integrations`, as
 * `?github=<code>`.
 *
 * A closed enum rather than a message in the query string, for the same reason
 * `?invite=` is one on `/team`: the wording stays server-side and out of a
 * parameter anyone can hand a signed-in user. Both ends narrow through this
 * schema, so a code one side stops producing is a type error on the other.
 * Only codes a route actually redirects with belong here: an entry nothing
 * produces reads as a state the page can reach, and the exhaustive Record on the
 * rendering side makes it look implemented.
 *
 * The callback redirects here rather than rendering, so the `code` GitHub put in
 * the URL does not sit in history or in a referrer.
 */
export const IntegrationsNoticeSchema = z.enum([
  "connected",
  "bad_state",
  "not_your_installation",
  "installation_taken",
  "code_rejected",
  "install_requested",
  "provider_error",
  "not_configured",
]);
export type IntegrationsNotice = z.infer<typeof IntegrationsNoticeSchema>;

export function parseIntegrationsNotice(
  raw: string | null | undefined
): IntegrationsNotice | null {
  const parsed = IntegrationsNoticeSchema.safeParse(raw);
  return parsed.success ? parsed.data : null;
}
