// The one place an agent is described. Everything per-agent that used to live in
// a `switch` with a silently-degrading `default:` (resume argv, initial-prompt
// argv, launch env, update spec) is a field here instead, so omitting it is a
// compile error rather than a feature that quietly never runs.
//
// Adding an agent: add the key to AgentKey in ./types, then fill the record the
// compiler now demands.

import { existsSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { readCodexVersionJson, codexHomeDir } from "../codex/codex-version";
import {
  codexThreadExistsSync,
  copilotSessionExistsSync,
  resolveClaudeTranscriptTitle,
  resolveCodexThreadName,
  resolveCodexThreadTitle,
  resolveCopilotSessionTitle,
} from "../title-resolver";
import { injectConfig } from "./config-inject";
import * as claudeHooks from "./claude-code/hooks";
import * as codexHooks from "./codex/hooks";
import * as cursorHooks from "./cursor-agent/hooks";
import * as copilotHooks from "./github-copilot/hooks";
import * as opencodeHooks from "./opencode/hooks";
import { createDriver as createClaudeDriver } from "./claude-code/driver";
import { createDriver as createCodexDriver } from "./codex/driver";
import { createDriver as createOpencodeDriver } from "./opencode/driver";
import { readTranscript as readClaudeTranscript } from "./claude-code/transcript";
import { readTranscript as readCodexTranscript } from "./codex/transcript";
import { readTranscript as readOpencodeTranscript } from "./opencode/transcript";
import type { AgentKey, AgentSpec } from "./types";

export const AGENTS: Record<AgentKey, AgentSpec> = {
  "claude-code": {
    bin: "claude",
    label: "Claude Code",
    hookName: "claude",
    hookDir: "~/.claude/hooks",
    notificationSource: "plugin",
    titleSource: "structured",
    resume: (id) => ["--resume", id],
    initialPrompt: (p) => ["--", p],
    hooks: claudeHooks,
    driver: createClaudeDriver,
    judge: {
      tier: "readonly",
      // The prompt goes BEFORE --allowedTools, not last. --allowedTools is
      // variadic, so a trailing prompt is parsed as one more tool name and
      // claude exits 1 with "Input must be provided ... when using --print" —
      // i.e. every judge call silently fails closed. Verified against the real
      // CLI; keep the prompt ahead of any variadic flag added here later.
      cmd: (prompt, model) => [
        "claude", "-p", prompt, "--allowedTools",
        "Read,Grep,Glob,Bash(git status:*),Bash(git diff:*),Bash(git log:*)",
        ...(model ? ["--model", model] : []),
      ],
    },
    transcript: readClaudeTranscript,
    resumable: ({ transcriptPath }) => !transcriptPath || existsSync(transcriptPath),
    resolveTitle: async ({ transcriptPath }) =>
      transcriptPath ? await resolveClaudeTranscriptTitle(transcriptPath) : null,
    update: {
      npmPackage: "@anthropic-ai/claude-code",
      command: "claude",
      updateArgs: ["update"],
    },
  },
  codex: {
    bin: "codex",
    label: "Codex",
    hookName: "codex",
    hookDir: "~/.codex/hooks",
    notificationSource: "plugin",
    titleSource: "structured",
    resume: (id) => ["resume", id],
    initialPrompt: (p) => ["--", p],
    hooks: codexHooks,
    driver: createCodexDriver,
    judge: {
      tier: "readonly",
      // --skip-git-repo-check because a project need not be a git repo: without
      // it codex exits 1 on "Not inside a trusted directory" and the judge fails
      // closed for every non-repo project. It does not widen the tier — the
      // read-only sandbox is what makes this argv provably read-only, and that
      // check only guards against writes in untracked dirs.
      cmd: (prompt, model) => [
        "codex", "exec", "--sandbox", "read-only", "--skip-git-repo-check",
        ...(model ? ["-m", model] : []), prompt,
      ],
    },
    transcript: readCodexTranscript,
    // null = the DB is undeterminable (missing/locked/schema drift), which is
    // not a confirmation that the thread is gone.
    resumable: ({ agentSessionId, codexHome }) =>
      codexThreadExistsSync(agentSessionId, codexHome ?? join(homedir(), ".codex")) ?? true,
    resolveTitle: async ({ sessionId, codexHome }) => {
      const home = codexHome ?? join(homedir(), ".codex");
      // Prefer the desktop app's richer generated title (session_index.jsonl) when
      // it has indexed this thread; otherwise use the CLI's live state DB, which is
      // the only source populated for bridge-spawned `codex-tui` sessions.
      return (
        (await resolveCodexThreadName(sessionId, home)) ??
        (await resolveCodexThreadTitle(sessionId, home))
      );
    },
    update: {
      npmPackage: "@openai/codex",
      command: "codex",
      updateArgs: ["update"],
      // Codex is the one tool with an updater-state file; the rest are npm-only.
      readState: () => readCodexVersionJson(codexHomeDir()),
    },
  },
  opencode: {
    bin: "opencode",
    label: "opencode",
    // No `bridge hook` events: opencode's plugin runs inside its own runtime and
    // POSTs to the loopback API itself, under this name.
    hookName: "opencode",
    hookDir: "~/.opencode/hooks",
    notificationSource: "plugin",
    titleSource: "structured",
    resume: (id) => ["--session", id],
    initialPrompt: (p) => ["--prompt", p],
    hooks: opencodeHooks,
    driver: createOpencodeDriver,
    judge: {
      // --agent plan selects opencode's built-in restricted Plan agent
      // (edits denied by default; non-interactive `run` without --auto fails
      // permission asks closed). Config-level, not flag-proven like claude's
      // --allowedTools, so the tier stays "transcript": no tool hints, and no
      // transcript-path handed to a judge whose restriction we can't verify.
      tier: "transcript",
      cmd: (prompt, model) =>
        ["opencode", "run", "--agent", "plan", ...(model ? ["--model", model] : []), prompt],
    },
    transcript: readOpencodeTranscript,
    // No resolveTitle: opencode's plugin posts the title inline.
    env: ({ abDir }) =>
      injectConfig("OPENCODE_TUI_CONFIG", abDir, "opencode-tui.json", {
        attention: { enabled: true },
      }),
    update: { npmPackage: "opencode-ai", command: "opencode", updateArgs: ["upgrade"] },
  },
  "cursor-agent": {
    bin: "cursor-agent",
    label: "Cursor",
    hookName: "cursor",
    hookDir: null,
    notificationSource: "plugin",
    titleSource: "osc",
    resume: (id) => ["--resume", id],
    initialPrompt: (p) => ["--", p],
    hooks: cursorHooks,
  },
  "github-copilot": {
    bin: "copilot",
    label: "Copilot",
    hookName: "github-copilot",
    hookDir: null,
    notificationSource: "osc",
    titleSource: "structured",
    // Copilot's optional-value --resume drops a space-separated value.
    resume: (id) => [`--resume=${id}`],
    initialPrompt: () => [],
    hooks: copilotHooks,
    resumable: ({ agentSessionId, copilotHome }) =>
      copilotSessionExistsSync(
        agentSessionId,
        copilotHome ?? process.env.COPILOT_HOME ?? join(homedir(), ".copilot"),
      ) ?? true,
    resolveTitle: async ({ sessionId, copilotHome }) =>
      await resolveCopilotSessionTitle(
        sessionId,
        copilotHome ?? process.env.COPILOT_HOME ?? join(homedir(), ".copilot"),
      ),
    // No `update`: github-copilot ships no self-updater (IDE-bound), so a
    // request for one fails soft via updateSpecFor → null.
  },
  // opencode fork: same attention gating (default-off + focus-blur). Enabled
  // via KILO_TUI_CONFIG injection (see env below); the app's default-blur
  // (DEC 1004) supplies the blur it waits on.
  kilo: {
    bin: "kilo",
    label: "Kilo",
    hookName: null,
    hookDir: null,
    notificationSource: "osc",
    titleSource: "osc",
    resume: () => [],
    initialPrompt: () => [],
    env: ({ abDir }) =>
      injectConfig("KILO_TUI_CONFIG", abDir, "kilo-tui.json", {
        attention: { enabled: true },
      }),
  },
  // Signals only with a bare terminal bell (no OSC 9/777). Since the bell now
  // rings audibly instead of raising a desktop notification, kimi is heard, not
  // notified — no OSC notification source exists to coerce it into.
  kimi: {
    bin: "kimi",
    label: "Kimi",
    hookName: null,
    hookDir: null,
    notificationSource: "osc",
    titleSource: "osc",
    resume: () => [],
    initialPrompt: () => [],
  },
  // Textual TUI: notifications default ON, fails CLOSED on Textual focus
  // (DEC 1004-derived), so the default-blur drives it — no injection.
  "mistral-vibe": {
    bin: "vibe",
    label: "Mistral Vibe",
    hookName: null,
    hookDir: null,
    notificationSource: "osc",
    titleSource: "osc",
    resume: () => [],
    initialPrompt: () => [],
  },
};

/**
 * hookName → AgentKey, for dispatching an inbound `bridge hook <name> <event>`
 * or a loopback post's `agent` field back to its registry entry. Derived, never
 * hand-maintained: the two vocabularies diverge (`cursor` vs `cursor-agent`) and
 * a stale hand-written map is exactly the silent drop this refactor removes.
 */
export const BY_HOOK_NAME: Record<string, AgentKey> = Object.fromEntries(
  (Object.entries(AGENTS) as [AgentKey, AgentSpec][])
    .filter(([, spec]) => spec.hookName !== null)
    .map(([key, spec]) => [spec.hookName as string, key]),
);

/**
 * Widening lookup for the many call sites that carry an arbitrary tool string
 * (an antgrid.yaml `agent.name`, a wire-supplied `session.tool`). Returns
 * undefined for anything not in the registry so callers keep an explicit
 * fallback instead of indexing into a Record that claims total coverage.
 */
export function agentSpec(tool: string): AgentSpec | undefined {
  return Object.hasOwn(AGENTS, tool) ? AGENTS[tool as AgentKey] : undefined;
}

/**
 * Whether this tool can drive a headless judge — the only legal values for the
 * Handler's judge-tool override. Named rather than inlined because the callers
 * validate an UNTRUSTED wire string, and a bare index into AGENTS would type as
 * always-present and let an unknown tool through.
 */
export function judgeCapable(tool: string): boolean {
  return agentSpec(tool)?.judge !== undefined;
}

// Events that POST a turn-END notification (task_complete / error / idle).
const TURN_END_EVENTS: ReadonlySet<string> = new Set(["stop", "after-agent", "agent-stop"]);

/**
 * True when a terminal-mode session of [tool] reports turn ENDS but no turn
 * START. Those are the only sessions whose "working" may be inferred from a
 * submitted keystroke: the inferred turn is guaranteed a closer, so it cannot
 * wedge the session on "working" (see work-status.ts's userReply).
 *
 * Excludes both ends of the spectrum. Claude declares "user-prompt" (a real
 * UserPromptSubmit turn-start hook), so guessing there could only be wrong. An
 * agent with no turn-end event — opencode, whose in-runtime plugin declares no
 * `bridge hook` events, and the hookless kilo/kimi/mistral-vibe — has nothing to
 * close an inferred turn, so theirs would run until the session stopped, which
 * is worse than reading "done".
 *
 * Lives here, off each agent's own hook profile, rather than in a table of its
 * own: this file is the single source of truth for what a tool actually fires,
 * so an agent whose events change can't silently disagree with the gate.
 */
export function needsKeystrokeTurnStart(tool: string | undefined): boolean {
  const events = tool === undefined ? undefined : agentSpec(tool)?.hooks?.events;
  if (events === undefined) return false;
  return !events.includes("user-prompt") && events.some((e) => TURN_END_EVENTS.has(e));
}
