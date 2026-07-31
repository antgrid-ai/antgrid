import { logger } from "../logger";
import { agentSpec } from "./registry";

const log = logger.child({ component: "title-generate" });

/** Matches SessionNamer's cap so a title that survives here survives there. */
const MAX_TITLE_LEN = 60;
/** Enough of the opening exchange to name it; more only costs judge tokens. */
const MAX_MSGS = 4;
const MAX_CONTEXT_CHARS = 4_000;
const DEFAULT_TIMEOUT_MS = 45_000;

const PROMPT_HEAD =
  "Below is the start of a coding session. Reply with a title for it: " +
  "3 to 6 words, imperative mood, no quotes, no trailing period, no preamble. " +
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

/** One spawn, no retry: a title is advisory, and the session already has a
 *  usable name. Returns stdout, or null on spawn failure/timeout. */
async function spawnOnce(
  cmd: string[], cwd: string, timeoutMs: number, spawn: typeof Bun.spawn,
): Promise<string | null> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  try {
    const proc = spawn(cmd, { cwd, stdout: "pipe", stderr: "ignore" });
    let timedOut = false;
    timer = setTimeout(() => {
      timedOut = true;
      try { proc.kill(); } catch { /* already gone */ }
    }, timeoutMs);
    const out = await new Response(proc.stdout).text();
    await proc.exited;
    return timedOut ? null : out;
  } catch {
    return null;
  } finally {
    // Same reason as the handler's judge spawn: killing mid-read rejects the
    // stdout promise, and an uncleared timer would hold the dead proc alive.
    clearTimeout(timer);
  }
}

/**
 * Name a session by asking the agent's own headless CLI, for the sessions no
 * agent will name for us.
 *
 * This exists because there is nothing left to read: codex never generates a
 * thread title (only its desktop app does), and Claude only writes one in the
 * interactive TUI — so chat-mode and short sessions bottom out at "echo the
 * user's first message" on every agent. See ResolvedTitle in ./types.
 *
 * Reuses `spec.judge.cmd`, which is already the vetted headless one-shot for
 * this tool (and already carries its auth). The tier is irrelevant here, unlike
 * in the handler: the conversation is inlined into the prompt, so the judge
 * needs no tool access and is handed no transcript path.
 *
 * Never throws — every failure is a null and the caller keeps the name it has.
 */
export async function generateSessionTitle(opts: {
  /** Registry key (`claude-code`), not a hook name. */
  tool: string;
  cwd: string;
  transcriptPath?: string;
  agentSessionId?: string;
  /** Used when the agent exposes no readable transcript; normally the
   *  first-message title we are trying to improve on. */
  fallbackContext?: string;
  model?: string;
  timeoutMs?: number;
  // Test seams; production callers omit these.
  spawn?: typeof Bun.spawn;
  codexHome?: string;
  opencodeDbPath?: string;
}): Promise<string | null> {
  const spec = agentSpec(opts.tool);
  const judge = spec?.judge;
  if (!judge) return null;

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
  if (!context) return null;

  const prompt = buildPrompt(context);
  const stdout = await spawnOnce(
    judge.cmd(prompt, opts.model), opts.cwd, opts.timeoutMs ?? DEFAULT_TIMEOUT_MS,
    opts.spawn ?? Bun.spawn,
  );
  if (stdout === null) return null;
  return parseTitleFromOutput(stdout);
}
