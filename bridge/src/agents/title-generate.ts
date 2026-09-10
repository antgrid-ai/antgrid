import { logger } from "../logger";
import { capturePrompt } from "../modelwatch";
import { headlessScratchCwd, logBorrow, resolveHeadless, runHeadless } from "./headless";
import { unwrapEnvelope } from "./usage-envelope";
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
  const envelope = unwrapEnvelope(stdout);
  // A vendor that states its own verdict turns the length heuristic below from a
  // guess into a check. It is only a guess where nothing else is available: a
  // refusal is short ("Invalid API key · Please run /login" is six words) and
  // clears every test this makes, and with the `self` rank outranking the
  // first-message re-read that string is the session's name for good. The
  // heuristic stays, because for a CLI with no envelope it is still the only
  // defence there is.
  if (envelope?.failed) return null;
  const lines = (envelope?.text ?? stdout).split("\n").map((l) => l.trim()).filter(Boolean);
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
 * A generated title, or why there is none.
 *
 * The reasons are NOT interchangeable to the caller, which is the whole point
 * of returning one rather than a bare null. "failed" is a spawn that ran and
 * did not produce a usable title — a signed-out CLI, a timeout, a rambling
 * answer — any of which the next turn may not repeat, so it is worth a bounded
 * retry.
 *
 * The other two are the machine's answer rather than this attempt's, so every
 * retry would re-read a transcript to reach the same refusal. They stay apart
 * because they send a reader to different places: "unavailable" means no
 * installed agent declares an argv that can serve the call at all, where
 * "skipped" means one does and we declined to spend it (AgentSpec.billsPerCall).
 * Collapsing the second into the first would report a working install as a
 * missing one.
 */
export type TitleGeneration =
  | ({ ok: true; title: string } & TitleCallRef)
  | ({ ok: false; reason: "unavailable" | "failed" | "skipped" } & TitleCallRef);

/**
 * What the caller needs to record the OUTCOME of a naming call against the
 * spawn's own records.
 *
 * `callId` is the join. The tools travel with it because a naming call is
 * routinely served by a borrowed CLI, and the caller — which sits above this
 * function and only ever names a session's own agent — would otherwise file
 * every borrowed call under the vendor that did not run it.
 */
export interface TitleCallRef {
  callId: string;
  /** The CLI that served the call, or — where nothing ran — the one that would
   *  have. On `unavailable` that is the requested tool, since there is no second
   *  vendor to name and the reason itself says so; on `skipped` it is the vendor
   *  whose billing IS the reason, which is the whole content of the record. */
  actualTool: string;
  /** The headless entry that served it, or `"none"` when no installed agent
   *  declares one — the `unavailable` case has no reach to name. A `skipped`
   *  call names the reach it declined, which is what says an argv existed. */
  reach: string;
}

/**
 * `ANTGRID_NAMING_MODEL=0` spawns naming with no `--model` at all, whatever the
 * registry declares and whatever the caller asked for.
 *
 * The same hazard `usageCaptureEnabled` (./headless) answers, one layer up and
 * with a worse blast radius. Every entry was verified against one account, and
 * the set of models an ACCOUNT can reach is account-specific: a user whose
 * claude points at Bedrock or Vertex (headlessEnv inherits the host's whole
 * environment, so `CLAUDE_CODE_USE_BEDROCK` reaches this spawn), or whose
 * account-scoped codex slug was retired, gets a 404 or a local exit 1 on every
 * naming call — and TitleAttempts refuses a session for good after two. Nothing
 * downstream can parse its way out of that, so the switch is what such a user
 * can reach without a new build. Read per spawn, so it applies to a running host.
 *
 * OFF-ONLY, never a substitute slug: a value here could not know which vendor
 * ends up serving a borrowed call, which is the exact mismatch the resolution
 * below exists to prevent.
 */
function namingModelEnabled(): boolean {
  return process.env.ANTGRID_NAMING_MODEL !== "0";
}

/**
 * Which model string a naming call asks for, given who was requested and who
 * actually answered.
 *
 * Resolved off the SERVING agent, never the requested one: naming borrows
 * across vendors, and a model name verified for one CLI means nothing to
 * another — a Claude model name handed to codex fails the call outright. A
 * caller's own model is subject to the same rule rather than exempt from it: it
 * can only have been chosen for the tool the caller named, so a borrow drops it
 * and takes the serving agent's own verified entry instead.
 */
function namingModel(requested: string, serving: string, callerModel?: string): string | undefined {
  if (!namingModelEnabled()) return undefined;
  if (callerModel && requested === serving) return callerModel;
  return agentSpec(serving)?.cheapNamingModel;
}

/**
 * Name a session by asking a headless CLI, rather than waiting to see whether
 * the agent names it for us.
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
 * Never throws — every failure is a `reason` and the caller keeps the name it has.
 */
export async function generateTitleFromContext(context: string, opts: {
  tool: string;
  /** Explicit override, honoured only when this call is NOT borrowed — a caller
   *  can only have chosen a model for the tool it named. Absent is the common
   *  case: the model is then looked up off the tool that actually serves the
   *  call, not this one, since naming may borrow across vendors. */
  model?: string;
  timeoutMs?: number;
  /** Which session is being named. Attribution for the modelwatch record only —
   *  nothing about the call itself depends on it, which is why it is optional. */
  terminalId?: string;
  spawn?: typeof Bun.spawn;
  /** Test seam; production reads PATH via detectInstalledTools(). */
  installedTools?: string[];
}): Promise<TitleGeneration> {
  const callId = crypto.randomUUID();
  // `need: "none"` — the conversation is inlined into the prompt, so this asks
  // for the tightest argv the agent has rather than one that can reach the repo.
  const picked = resolveHeadless(opts.tool, "none", opts.installedTools);
  if (!picked) {
    return { ok: false, reason: "unavailable", callId, actualTool: opts.tool, reach: "none" };
  }
  logBorrow("none", opts.tool, picked.tool);
  // Asked of the SERVING agent, because that is the account that gets billed: a
  // session of a token-billed vendor that borrows this one would otherwise
  // spend the unit on a name anyway, and the session's own tool says nothing
  // about who pays for a borrowed call.
  if (agentSpec(picked.tool)?.billsPerCall) {
    return {
      ok: false, reason: "skipped", callId,
      actualTool: picked.tool, reach: picked.reach,
    };
  }
  const model = namingModel(opts.tool, picked.tool, opts.model);
  // Sliced once and then both sent and digested: a digest taken over the whole
  // transcript would identify text the model was never shown.
  const excerpt = context.slice(0, MAX_CONTEXT_CHARS);
  const prompt = PROMPT_HEAD + excerpt;
  const budgetMs = opts.timeoutMs ?? DEFAULT_TIMEOUT_MS;
  const ref: TitleCallRef = { callId, actualTool: picked.tool, reach: picked.reach };
  const result = await runHeadless(picked.command.cmd(prompt, model), {
    cwd: headlessScratchCwd(),
    timeoutMs: budgetMs,
    spawn: opts.spawn,
    env: picked.command.env,
    scratchEnv: picked.command.scratchEnv,
    usage: picked.command.usage,
    // Requested and actual are both recorded because they routinely differ
    // here: `need: "none"` takes whichever installed agent can serve it and
    // registry order puts Claude first, so on a machine with Claude installed
    // every borrowed title is billed to the Claude account. logBorrow says so
    // in one log line; this is what makes it countable.
    call: {
      callId, purpose: "title", attempt: 1,
      requestedTool: opts.tool, actualTool: picked.tool, reach: picked.reach,
      requestedModel: model,
      terminalId: opts.terminalId,
      promptChars: prompt.length,
      // The scaffold is ours and safe verbatim; the excerpt is the user's
      // session talking back, so it goes through the context arm rather than
      // being inlined as prompt text.
      prompt: capturePrompt({ scaffold: PROMPT_HEAD, context: excerpt }),
    },
  });
  // A timeout or a non-zero exit discards the output rather than parsing it.
  // These CLIs print their refusals to STDOUT and they are short: "Invalid API
  // key · Please run /login" clears every one of parseTitleFromOutput's checks
  // and reads as a title. With the `self` rank outranking the first-message
  // re-read, that error string would be the session's name for good.
  // `vendorFailed` is the same rejection one layer up, for a CLI whose envelope
  // never reaches the parser: copilot writes its verdict to a side file and
  // leaves stdout as plain text.
  if (!result || result.code !== 0 || result.vendorFailed) return { ok: false, reason: "failed", ...ref };
  const title = parseTitleFromOutput(result.stdout);
  // An unparseable answer is a failed attempt, not an absent capability: the
  // spawn worked and the model rambled, which the next turn may not repeat.
  return title ? { ok: true, title, ...ref } : { ok: false, reason: "failed", ...ref };
}
