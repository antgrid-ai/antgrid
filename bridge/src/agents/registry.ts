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
import { readCodexVersionJson, codexHomeDir } from "./codex/home";
import { antigravityCliHome, resolveAntigravityTitle } from "./antigravity/title";
import { resolveClaudeTranscriptTitle } from "./claude-code/title";
import { codexThreadExistsSync, resolveCodexThreadTitle } from "./codex/title";
import { copilotSessionExistsSync, resolveCopilotSessionTitle } from "./github-copilot/title";
import { injectConfig } from "./config-inject";
import { ETX } from "./types";
import * as antigravityHooks from "./antigravity/hooks";
import * as claudeHooks from "./claude-code/hooks";
import * as codexHooks from "./codex/hooks";
import * as cursorHooks from "./cursor-agent/hooks";
import * as copilotHooks from "./github-copilot/hooks";
import * as opencodeHooks from "./opencode/hooks";
import { createDriver as createClaudeDriver } from "./claude-code/driver";
import { createDriver as createCodexDriver } from "./codex/driver";
import { createDriver as createOpencodeDriver } from "./opencode/driver";
import { lastAssistantText, readTranscript as readClaudeTranscript } from "./claude-code/transcript";
import { readTranscript as readCodexTranscript } from "./codex/transcript";
import { readTranscript as readOpencodeTranscript } from "./opencode/transcript";
import { claudeForkHandoff, claudeNativeForkArgs } from "./claude-code/fork";
import { codexForkHandoff, codexNativeForkArgs } from "./codex/fork";
import { opencodeForkHandoff, opencodeNativeForkArgs } from "./opencode/fork";
import { terminalForkHandoff } from "./fork-handoff";

import { pickHeadlessFrom, type AgentKey, type AgentSpec } from "./types";

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
    fork: {
      kind: "native-fork",
      handoff: claudeForkHandoff,
      nativeForkArgs: claudeNativeForkArgs,
    },
    hooks: claudeHooks,
    notifyBodyFromTranscript: lastAssistantText,
    driver: createClaudeDriver,
    // Measured against the installed CLI on Windows. One Ctrl-C only arms the
    // quit ("Press Ctrl-C again to exit") and is spent for nothing; two exit an
    // idle session in 1.4-3.0s. The third covers a Ctrl-C the agent spends
    // interrupting a live turn instead, and costs nothing when it is not needed
    // — the presses stop the moment the PTY reports its exit.
    //
    // This is the agent the graceful phase exists for: the fullscreen renderer
    // arms a `fullscreenBootPending[pid]` canary in `~/.claude.json` and
    // withdraws it from a `process.on("exit")` hook, which neither
    // `TerminateProcess` nor `SIGKILL` runs. A stale entry auto-disables that
    // renderer MACHINE-WIDE until the file is hand-edited.
    gracefulExit: { keystrokes: [ETX, ETX, ETX] },
    // No "sealed" entry: an allowlist naming this agent's read tools is what a
    // sealed argv would have to omit, and `--allowedTools` with an empty value
    // has not been run against the real CLI. Until it is, naming takes the
    // readonly entry below — which is what it already ran under, since the
    // previous naming argv denied only Bash/Edit/Write/NotebookEdit and left
    // Read, Grep and Glob allowed.
    //
    // NOT `--bare`, which looks made for this (skips hooks, plugins, memory):
    // it also forces ANTHROPIC_API_KEY-only auth and never reads OAuth or the
    // keychain, so it fails closed for every subscription user.
    headless: {
      readonly: {
        // The prompt goes BEFORE --allowedTools, not last. --allowedTools is
        // variadic, so a trailing prompt is parsed as one more tool name and
        // claude exits 1 with "Input must be provided ... when using --print" —
        // i.e. every call silently fails closed. Verified against the real CLI;
        // keep the prompt ahead of any variadic flag added here later.
        cmd: (prompt, model) => [
          "claude", "-p", prompt, "--no-session-persistence", "--allowedTools",
          "Read,Grep,Glob,Bash(git status:*),Bash(git diff:*),Bash(git log:*)",
          ...(model ? ["--model", model] : []),
        ],
        // --no-session-persistence keeps these runs out of the user's own
        // history: a supervisor pass or a naming call is machine bookkeeping,
        // and one per agent pause buries the sessions the user actually started
        // under /resume. Valid only with --print, which this argv already uses.
        noHistory: "flag",
      },
    },
    transcript: readClaudeTranscript,
    // Antgrid owns the session lifecycle: a conversation that hands itself to
    // claude's own background supervisor exits the PTY, leaves the slot
    // resuming an id a job we don't manage still holds, and relocates its cwd
    // out of the session's checkout. Forced, not `??=` like buildClaudeEnv's
    // defaults — no per-machine preference makes that outcome survivable here.
    // Closes `/background`, `--bg`, `--routine`, `claude agents`. Does NOT
    // close the two-press LEFT-ARROW gesture: its only guard is the
    // machine-wide `leftArrowOpensAgents` global-config key, and the fleet
    // gate never reaches the REPL keymap (measured on the 2.1.247 binary).
    env: () => ({ CLAUDE_CODE_DISABLE_AGENT_VIEW: "1" }),
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
    resumeIsSubcommand: true,
    initialPrompt: (p) => ["--", p],
    fork: {
      kind: "native-fork",
      handoff: codexForkHandoff,
      nativeForkArgs: codexNativeForkArgs,
    },
    hooks: codexHooks,
    driver: createCodexDriver,
    // codex offers no sandbox tighter than read-only, so there is no sealed
    // entry to write: `--sandbox read-only` is the floor.
    headless: {
      readonly: {
        // --skip-git-repo-check because a project need not be a git repo:
        // without it codex exits 1 on "Not inside a trusted directory" and every
        // call fails closed for non-repo projects. It does not widen the reach —
        // the read-only sandbox is what makes this argv provably read-only, and
        // that check only guards against writes in untracked dirs.
        cmd: (prompt, model) => [
          "codex", "exec", "--ephemeral", "--sandbox", "read-only", "--skip-git-repo-check",
          ...(model ? ["-m", model] : []), prompt,
        ],
        // --ephemeral is codex's equivalent of claude's --no-session-persistence:
        // no rollout file, so `codex exec resume --last` still points at the
        // user's own work rather than at whichever bookkeeping pass ran most
        // recently.
        noHistory: "flag",
      },
    },
    transcript: readCodexTranscript,
    // null = the DB is undeterminable (missing/locked/schema drift), which is
    // not a confirmation that the thread is gone.
    resumable: ({ agentSessionId, codexHome }) =>
      codexThreadExistsSync(agentSessionId, codexHome ?? join(homedir(), ".codex")) ?? true,
    // The CLI's live state DB is the only source populated for bridge-spawned
    // `codex-tui` sessions. session_index.jsonl is not read at all: every name
    // in it is one the Codex DESKTOP app generated, and we name sessions
    // ourselves (see ResolvedTitle).
    resolveTitle: async ({ sessionId, codexHome }) =>
      await resolveCodexThreadTitle(sessionId, codexHome ?? join(homedir(), ".codex")),
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
    fork: {
      kind: "native-fork",
      handoff: opencodeForkHandoff,
      nativeForkArgs: opencodeNativeForkArgs,
    },
    hooks: opencodeHooks,
    driver: createOpencodeDriver,
    headless: {
      // "transcript", not "readonly": --agent plan selects opencode's built-in
      // restricted Plan agent (edits denied by default; non-interactive `run`
      // without --auto fails permission asks closed), which is config-level
      // rather than flag-proven like claude's --allowedTools. So no tool hints,
      // and no transcript path handed to a spawn whose restriction we can't
      // verify.
      transcript: {
        cmd: (prompt, model) =>
          ["opencode", "run", "--agent", "plan", ...(model ? ["--model", model] : []), prompt],
        // opencode has no --ephemeral, so persistence is redirected instead of
        // disabled: the whole session store is one SQLite file, and OPENCODE_DB
        // takes `:memory:` verbatim (opencode's own tests and its desktop dev
        // build use the same override), so the spawn's session is never written
        // anywhere.
        //
        // Safe for auth, which is the question this turns on: model credentials
        // live in auth.json under the DATA dir, read via OPENCODE_AUTH_CONTENT
        // or the file — never through the database. (The `credential` table
        // alongside `session` is connector secrets, not provider auth.) For the
        // same reason never redirect XDG_DATA_HOME to achieve this: that WOULD
        // move auth.json.
        //
        // What the scratch DB does lose is the `account` row, so an
        // opencode-account token is absent for this spawn — no session sharing,
        // and no account-backed remote config. Neither caller shares anything;
        // remote config is the live risk if a team serves model settings that way.
        env: { OPENCODE_DB: ":memory:" },
        noHistory: "ephemeral-store",
      },
    },
    transcript: readOpencodeTranscript,
    // No resolveTitle: opencode writes no name of its own that we read. The
    // one it generates arrives inline on the plugin's post and is dropped
    // (see ResolvedTitle), so an opencode session is named only by
    // generation off the transcript above.
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
    fork: terminalForkHandoff("Cursor"),
    hooks: cursorHooks,
    augmentsDefaultSpec: true,
    // No headless entry. `-p --mode ask` reads like the right argv and has
    // never been run: cursor-agent exits 1 on every invocation without an
    // `agent login` or CURSOR_API_KEY, so nothing about that argv's reach has
    // been observed. Absence is the honest answer, and it is not only about a
    // wrong label — ANY non-sealed reach makes the agent judge-capable, which
    // would arm a supervisor over the user's working tree on an argv nobody
    // has run. Naming is unaffected: a "none" call borrows an installed agent.
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
    fork: terminalForkHandoff("GitHub Copilot"),
    hooks: copilotHooks,
    augmentsDefaultSpec: true,
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
    headless: {
      // "readonly", not "sealed": -p reads the working tree with no flag asking
      // it to. Measured — it answered a "read package.json" prompt even under
      // --deny-tool, whose value is optional and which therefore denies nothing
      // when passed bare. Writes are the other half and they fail CLOSED: with
      // --allow-all-tools withheld, a write hits a permission ask that
      // non-interactive mode cannot answer ("unable to create the file due to
      // permission restrictions"), which is what the entry relies on since no
      // flag expresses read-only directly.
      readonly: {
        cmd: (prompt, model) => [
          "copilot", "-p", prompt, "--silent",
          ...(model ? ["--model", model] : []),
        ],
        // Copilot has no ephemeral flag — a -p run writes session-store.db and a
        // whole session-state/<uuid>/ tree — so the home is redirected to a
        // directory that lives only as long as the spawn.
        // Safe for auth, and that is NOT the generalization it looks like:
        // credentials do not live under COPILOT_HOME at all (no GH_TOKEN or
        // GITHUB_TOKEN path either), so a run against an EMPTY scratch home
        // still authenticates. Measured, because the opposite is true of vibe,
        // where the same move would take the credentials with it.
        scratchEnv: ["COPILOT_HOME"],
        noHistory: "ephemeral-store",
      },
    },
  },
  // Plugin-tier, but through agy's own GLOBAL `~/.gemini/config/hooks.json`
  // (see ./antigravity/hooks.ts) — it has no per-spawn hook channel, the same
  // constraint cursor-agent is under. The installed CLI shim is `agy` (Google's
  // Antigravity IDE), not `antigravity`. titleSource stays "osc": agy publishes
  // its exe path as the OSC-2 title, handled by oscTitleUnusable rather than by
  // suppressing the scanner.
  antigravity: {
    bin: "agy",
    label: "Antigravity",
    hookName: "antigravity",
    hookDir: null,
    notificationSource: "plugin",
    titleSource: "osc",
    oscTitleUnusable: true,
    // `agy --conversation <uuid>` is a global flag, so it goes before any raw
    // args. See `agy --help`.
    resume: (id) => ["--conversation", id],
    initialPrompt: (p) => ["--prompt-interactive", p],
    fork: terminalForkHandoff("Antigravity"),
    hooks: antigravityHooks,
    augmentsDefaultSpec: true,
    resolveTitle: async ({ sessionId, transcriptPath, antigravityHome }) =>
      await resolveAntigravityTitle(
        sessionId,
        antigravityHome ?? antigravityCliHome(),
        transcriptPath,
      ),
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
    // Kilo documents `--session <id> --fork`, but this integration does not
    // observe a Kilo-native id. Do not advertise an unreachable native path.
    fork: terminalForkHandoff("Kilo"),
    env: ({ abDir }) =>
      injectConfig("KILO_TUI_CONFIG", abDir, "kilo-tui.json", {
        attention: { enabled: true },
      }),
    headless: {
      // Kilo is an opencode fork down to the env-var names, so this is
      // opencode's entry with the prefix changed — see it for why "transcript"
      // rather than "readonly", and why the store is redirected rather than the
      // data dir (auth lives beside the DB, not inside it).
      transcript: {
        cmd: (prompt, model) =>
          ["kilo", "run", "--agent", "plan", ...(model ? ["--model", model] : []), prompt],
        env: { KILO_DB: ":memory:" },
        noHistory: "ephemeral-store",
      },
    },
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
    fork: terminalForkHandoff("Kimi"),
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
    // No headless entry, and `-p --agent ask` must not come back as one. Read
    // against mistralai/mistral-vibe v2.24.5: `ask` is the APPROVAL-gated
    // profile ("Requires approval for tool executions"), not a read-only one —
    // that is `plan`, the only builtin pinning write_file and edit to
    // permission "never". What makes ask LOOK read-only is that programmatic
    // mode denies every callback it is handed (cli/programmatic.py), so a write
    // fails closed on an approval it cannot answer.
    //
    // That is config-level, never argv-level, which is the whole distinction
    // HeadlessReach draws: an agent profile is just another config layer, `ask`
    // contributes no bypass_tool_permissions key, and the loop returns EXECUTE
    // before consulting any permission the moment a user's own config sets one
    // — no approval is raised, so nothing is denied. Even `--agent plan` falls
    // to the same switch, so the best reach available here is "transcript", and
    // it stays unrun besides (no MISTRAL_API_KEY on any machine measured).
    fork: terminalForkHandoff("Mistral Vibe"),
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
  // "repo", never "has a headless entry at all": a judge reads the working tree,
  // so a sealed argv cannot serve one — and treating any one-shot capability as
  // a judge would arm the Handler for every agent that can merely answer a
  // question (see AgentSpec.headless).
  return pickHeadlessFrom(agentSpec(tool)?.headless, "repo") !== null;
}

/**
 * True when a terminal-mode session of [tool] reports turn ENDS but no turn
 * START. Those are the only sessions whose "working" may be inferred from a
 * submitted keystroke: the inferred turn is guaranteed a closer, so it cannot
 * wedge the session on "working" (see work-status.ts's userReply).
 *
 * Excludes both ends of the spectrum. Claude declares a real UserPromptSubmit
 * turn-start hook, so guessing there could only be wrong. An agent with no
 * turn-end event — opencode and antigravity, whose out-of-band integrations
 * declare no `bridge hook` events, and the hookless kilo/kimi/mistral-vibe —
 * has nothing to close an inferred turn, so theirs would run until the session
 * stopped, which is worse than reading "done".
 *
 * Read straight off each agent's own hook profile: this file no longer holds a
 * cross-agent table of event names that an agent's events could drift from.
 */
export function needsKeystrokeTurnStart(tool: string | undefined): boolean {
  const tb = tool === undefined ? undefined : agentSpec(tool)?.hooks?.turnBoundaryEvents;
  return tb !== undefined && tb.start.length === 0 && tb.end.length > 0;
}

/**
 * Whether an armed Handler can OBSERVE a session of [tool] in [mode] at all.
 * "Unsupported" and "armed but quiet" are different facts, and this is the only
 * thing that separates them — an unobservable terminal session arms cleanly
 * today and then never fires, which reads to the user as a broken feature
 * rather than an absent one.
 *
 * terminal: the agent's installed integration must POST /handler-event —
 *   nothing else reaches the engine from a PTY.
 * chat:     any chat driver qualifies; the engine taps the driver's own
 *   outbound frames in-process (observeChatFrameForHandler in agent-core.ts).
 *
 * Derived rather than a fourth boolean on the spec: a standalone flag is exactly
 * the kind of table that drifts from what the integration actually posts.
 */
export function handlerObservable(tool: string | undefined, mode: "terminal" | "chat"): boolean {
  const spec = tool === undefined ? undefined : agentSpec(tool);
  if (!spec) return false;
  return mode === "chat"
    ? spec.driver !== undefined
    : spec.hooks?.posts.includes("/handler-event") === true;
}
