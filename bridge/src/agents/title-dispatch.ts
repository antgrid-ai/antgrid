import { logger } from "../logger";
import { AGENTS, BY_HOOK_NAME } from "./registry";
import type { ResolvedTitle, TitleArgs } from "./types";

const log = logger.child({ component: "title-resolver" });

/**
 * Resolve a session title for a loopback post that carries only correlation ids.
 *
 * `agent` is a HOOK name (`claude`, `cursor`, …), the vocabulary a post arrives
 * in — BY_HOOK_NAME maps it back to the registry key. It is optional on the
 * wire, and an agent with no `resolveTitle` returns null rather than being an
 * unhandled case: opencode supplies its title inline in the post, and
 * cursor-agent has no on-disk session file to read one from.
 *
 * Never throws: title resolution is advisory, and its callers fire it
 * unawaited.
 */
export async function resolveStructuredTitle(
  agent: string | undefined,
  args: { sessionId: string; transcriptPath?: string },
  // The agent-home test seams, taken off TitleArgs so a spec that adds one
  // doesn't need this signature widened by hand to stay injectable.
  opts: Omit<TitleArgs, "sessionId" | "transcriptPath"> = {},
): Promise<ResolvedTitle | null> {
  const key = agent ? BY_HOOK_NAME[agent] : undefined;
  const resolve = key ? AGENTS[key].resolveTitle : undefined;
  if (!resolve) return null;
  try {
    return await resolve({ ...args, ...opts });
  } catch (err) {
    log.warn("title resolution failed: %s", err);
    return null;
  }
}
