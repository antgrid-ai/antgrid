import { logger } from "../logger";
import { headlessScratchCwd, logBorrow, resolveHeadless, runHeadless } from "./headless";
import { agentSpec } from "./registry";

const log = logger.child({ component: "title-generate" });

/** Matches SessionNamer's cap so a title that survives here survives there. */
const MAX_TITLE_LEN = 60;
/** Enough of the opening exchange to name it; more only costs tokens. */
const MAX_MSGS = 4;
const MAX_CONTEXT_CHARS = 4_000;
const DEFAULT_TIMEOUT_MS = 45_000;

// "often only the opening request" and "not the wording" both earn their place:
// this runs at the first user message for Claude, where the model has one
// message to work from and paraphrases it back unless told to name the
// underlying task. An echo is the exact outcome generating a title exists to
// avoid. "an excerpt" is not hedging either — every reader returns the LAST
// maxMsgs messages (AgentSpec.transcript), so an agent reached from its
// turn-END post hands the model the middle of a session, and calling that the
// start had it name whatever the session had drifted to.
const PROMPT_HEAD =
  "Below is an excerpt of a coding session — often only the opening request. " +
  "Reply with a title for the session's overall task: 3 to 6 words naming the " +
  "task, not the wording. " +
  "Imperative mood, no quotes, no trailing period, no preamble. " +
  "Output the title alone on a single line.\n\n";

/**
 * Strip a title out of a CLI's stdout.
 *
 * Takes the LAST non-empty line, not the first: every agent CLI here prefixes
 * its answer with startup chatter (auth notices, model banners), and none of
 * them append anything after the reply.
 */
export function parseTitleFromOutput(stdout: string): string | null {
  const lines = stdout.split("\n").map((l) => l.trim()).filter(Boolean);
  let line = lines[lines.length - 1];
  if (!line) return null;
  // Models wrap titles in quotes/backticks or label them despite instructions.
  line = line.replace(/^(?:title|session title)\s*[:\-—]\s*/i, "");
  line = line.replace(/^["'`*_\s]+|["'`*_\s.]+$/g, "");
  line = line.replace(/\s+/g, " ").trim();
  if (!line) return null;
  // A rambling answer is worse than the first user message we already have —
  // reject rather than truncate mid-sentence into a nonsense name.
  if (line.length > MAX_TITLE_LEN || line.split(" ").length > 12) return null;
  return line;
}

function buildPrompt(context: string): string {
  return PROMPT_HEAD + context.slice(0, MAX_CONTEXT_CHARS);
}

/**
 * The conversation text a title is written from, or null when there is nothing
 * to name yet.
 *
 * Split out from {@link generateTitleFromContext} so the caller can spend its
 * one-shot-per-session gate only once it knows a name is actually reachable. A
 * combined call cannot: the gate has to be claimed BEFORE any await to keep two
 * turns ending at once from both spawning, so claiming it around the whole
 * thing burned the attempt on the SessionStart post — which arrives before the
 * user has typed anything and therefore always resolves to no context at all.
 *
 * Never throws; a transcript that cannot be read falls back to `fallbackContext`.
 */
export async function buildTitleContext(opts: {
  /** Registry key (`claude-code`), not a hook name. */
  tool: string;
  transcriptPath?: string;
  agentSessionId?: string;
  /** Used when the agent exposes no readable transcript, or has not written the
   *  turn yet — the first user message, or the first-message title we are
   *  trying to improve on. */
  fallbackContext?: string;
  // Test seams; production callers omit these.
  codexHome?: string;
  opencodeDbPath?: string;
}): Promise<string | null> {
  const spec = agentSpec(opts.tool);
  let context = "";
  if (spec?.transcript) {
    try {
      const t = await spec.transcript({
        maxMsgs: MAX_MSGS,
        transcriptPath: opts.transcriptPath,
        agentSessionId: opts.agentSessionId,
        codexHome: opts.codexHome,
        opencodeDbPath: opts.opencodeDbPath,
      });
      context = t.msgs.join("\n---\n");
    } catch (err) {
      log.warn("transcript read failed for %s: %s", opts.tool, err);
    }
  }
  if (!context.trim()) context = opts.fallbackContext?.trim() ?? "";
  return context || null;
}

/**
 * Name a session by asking a headless CLI, because we no longer wait to see
 * whether the agent names it for us.
 *
 * Agents disagree about this completely — codex's CLI never names a thread
 * (only its desktop app does), Claude writes one in the interactive TUI and
 * never in a headless/SDK run, Copilot fills one in eventually — so depending
 * on them meant the quality and the timing of a session's name were decided by
 * which agent it happened to run. See ResolvedTitle in ./types.
 *
 * One caller of AgentSpec.headless among several, and the one that needs the
 * least: the conversation is inlined into the prompt, so it asks for `need:
 * "none"` and takes whichever installed agent can serve it (see resolveHeadless).
 *
 * Never throws — every failure is a null and the caller keeps the name it has.
 */
export async function generateTitleFromContext(context: string, opts: {
  tool: string;
  model?: string;
  timeoutMs?: number;
  spawn?: typeof Bun.spawn;
  /** Test seam; production reads PATH via detectInstalledTools(). */
  installedTools?: string[];
}): Promise<string | null> {
  // `need: "none"` — the conversation is inlined into the prompt, so this asks
  // for the tightest argv the agent has rather than one that can reach the repo.
  const picked = resolveHeadless(opts.tool, "none", opts.installedTools);
  if (!picked) return null;
  logBorrow("none", opts.tool, picked.tool);
  const result = await runHeadless(picked.command.cmd(buildPrompt(context), opts.model), {
    cwd: headlessScratchCwd(),
    timeoutMs: opts.timeoutMs ?? DEFAULT_TIMEOUT_MS,
    spawn: opts.spawn,
    env: picked.command.env,
  });
  // A timeout or a non-zero exit discards the output rather than parsing it.
  // These CLIs print their refusals to STDOUT and they are short: "Invalid API
  // key · Please run /login" clears every one of parseTitleFromOutput's checks
  // and reads as a title. With the `self` rank outranking the first-message
  // re-read, and one attempt per session, that error string would be the
  // session's name for good.
  if (!result || result.code !== 0) return null;
  return parseTitleFromOutput(result.stdout);
}
