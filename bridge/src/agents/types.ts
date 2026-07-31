import type { ToolUpdateSpec } from "../agent-update";
import type { HookCommand } from "../hook-command";
import type { HookInvocation, HookPost } from "./hook-posts";
import type { AbMessage } from "../protocol";
import type { StructuredDriver } from "../structured/structured-manager";
import type { JudgeTier } from "../handler/decision";

/**
 * Every coding agent the bridge can launch by registry key.
 *
 * Compile-time only, deliberately: a remote phone can drive session starts, so
 * the set of launchable binaries must be fixed at build time and can never be
 * data. `Record<AgentKey, AgentSpec>` in registry.ts is what turns "you forgot
 * to wire the new agent into resume/update/notifications" from a silent runtime
 * degradation into a type error at the point you add the key.
 */
export type AgentKey =
  | "claude-code"
  | "codex"
  | "opencode"
  | "cursor-agent"
  | "github-copilot"
  | "kilo"
  | "kimi"
  | "mistral-vibe";

/**
 * Inputs to a spec's `env`. `abDir` is passed in rather than resolved inside
 * because SessionManager launches against its own storeDir, which is not always
 * the process-wide `resolveAbDir()`.
 */
export interface LaunchEnvCtx {
  abDir: string;
}

/** Inputs a hook profile needs to turn one invocation into loopback API posts.
 *  `terminalId` is absent whenever the agent's plugin host dropped our env.
 *  `readStdin` is injected rather than read from `process.stdin` so a profile
 *  stays testable, and so an agent that takes its payload on argv can decline to
 *  drain a pipe it knows is empty. */
export interface HookPostCtx {
  port: number;
  terminalId?: string;
  readStdin: () => Promise<string>;
}

/** Additive argv/env for one spawn of an agent, produced by its hook profile's
 *  `inject`. */
export interface LaunchAugmentation {
  args: string[];
  env: Record<string, string>;
  /** False when a filesystem-backed integration could not be installed, so the
   * caller keeps OSC notifications enabled for this spawn. */
  notificationsInjected?: boolean;
}

/** Inputs to a hook profile's `inject`, one per spawn. `cursorDir` overrides the
 *  machine-global `~/.cursor` that only cursor-agent writes into. `hookCommand`
 *  is the rendered `bridge hook` invocation to bake into the agent's own config;
 *  it is passed in rather than resolved per agent so one spawn cannot mix a
 *  compiled and a dev-mode command. */
export interface HookInjectCtx {
  abDir: string;
  cursorDir?: string;
  hookCommand: HookCommand;
}

/**
 * Everything a chat driver needs that StructuredAgentManager does not carry:
 * the project it runs in, and the bridge-side sinks it writes back into. The
 * sinks are pre-bound to this session so a driver never has to know its own slot
 * id twice. `chatAugment` is a thunk because calling it materializes plugin
 * files on disk — a driver that needs no title injection must not pay for one.
 */
export interface DriverCtx {
  sessionId: string;
  send: (m: AbMessage) => void;
  projectPath: string;
  projectId: string;
  chatAugment: () => { args: string[]; env: Record<string, string> };
  /** Persist the agent-native resume id for this slot (overwrite-latest). */
  onAgentSession: (agentSessionId: string) => void;
  /** Hand a driver-supplied session title to the namer. */
  onTitle: (title: string) => void;
  /** Fire the advisory "a newer <tool> exists" nudge for this start. */
  emitUpdateCheck: () => void;
}

/**
 * Synchronous by contract. An async factory would flip StructuredDriver and
 * StructuredAgentManagerOpts async too, and move SDK-import and spawn failures
 * from bridge start to session start. A driver whose backend needs an await
 * defers it internally — see opencode's thunked client.
 */
export type SpecDriverFactory = (ctx: DriverCtx) => StructuredDriver;

/** Inputs to a spec's `transcript`. `codexHome` / `opencodeDbPath` are test
 *  seams; production omits both and each reader falls back to the real home. */
export interface TranscriptOpts {
  maxMsgs: number;
  transcriptPath?: string;
  agentSessionId?: string;
  codexHome?: string;
  opencodeDbPath?: string;
}

/** Inputs to a spec's `resolveTitle`. The `*Home` fields are test seams. */
export interface TitleArgs {
  sessionId: string;
  transcriptPath?: string;
  codexHome?: string;
  copilotHome?: string;
}

/**
 * A title read from an agent's own store, tagged with how good it actually is.
 *
 * `kind` is load-bearing, not description. Every resolver has a last-resort
 * branch that echoes the user's opening prompt, because that is better than no
 * name at all — but it is NOT a title, and the caller has to be able to tell
 * the two apart to decide whether generating one is worth a model call. The
 * resolvers are the only code that knows which branch it took, so they report
 * it rather than leaving the caller to guess from the string.
 *
 * Measured, not assumed: codex NEVER generates a title (its CLI writes the
 * first user message into `threads.title`; the desktop app is what fills in a
 * real one), and Claude writes its `custom-title` only in the interactive TUI,
 * never in headless/SDK runs. So "first-message" is the common case, not an
 * edge one.
 */
export interface ResolvedTitle {
  title: string;
  kind: "generated" | "first-message";
}

export interface HookProfile {
  /** Installs this agent's callback channel for one spawn: the argv/env it needs
   *  plus whatever config or plugin file has to exist on disk first. Required,
   *  not optional — an agent that declares hook events but injects nothing has
   *  declared events nothing will ever fire. */
  inject: (ctx: HookInjectCtx) => LaunchAugmentation;
  /** Events this agent is allowed to dispatch. An event outside this list is
   *  dropped before any payload is read — the allowlist is the trust boundary
   *  for `bridge hook <name> <event>`, which any local process can invoke.
   *  Empty when the injected integration posts to the loopback API from inside
   *  the agent's own runtime instead of shelling out to `bridge hook`. */
  events: readonly string[];
  /** Turns one allowlisted invocation into the loopback posts it implies. Called
   *  only after the event passed `events`, so it never re-checks. */
  toPosts: (invocation: HookInvocation, ctx: HookPostCtx) => Promise<HookPost[]>;
}

/**
 * One agent, one record. Required fields are the ones whose absence would
 * silently degrade a session; the behavior layers (`hooks`, `driver`, `judge`,
 * `transcript`, `resolveTitle`) are optional because an agent genuinely may not
 * have them, and their absence is the honest answer rather than a default.
 */
export interface AgentSpec {
  /** PATH binary name. Detection resolves this per PATH entry. */
  bin: string;
  /** Display name for agent pickers. Travels to the app on the tools
   *  advertisement so a newly-added agent shows with a proper name without
   *  needing an app release. */
  label: string;
  /**
   * Name this agent identifies itself by in `bridge hook <name> <event>` and in
   * the `agent` field of its loopback posts. Deliberately NOT `AgentKey`: the
   * value is baked into on-disk hook configs and into codex's `trusted_hash`
   * (hashed over the rendered command string), so renaming it silently
   * un-trusts hooks in every already-configured install.
   *
   * null = the agent never posts under a name of its own. opencode has a name
   * despite having no `bridge hook` events: its in-process JS plugin POSTs to
   * the loopback API directly with `agent: "opencode"`, so title dispatch still
   * has to resolve that name back to a registry key.
   */
  hookName: string | null;
  hookDir: string | null;
  /**
   * Default argv prepended whenever we launch this tool by registry key (not on
   * the custom-command or antgrid.yaml fallback paths). Used to coerce an agent
   * into emitting terminal notifications our scanner can see, without asking the
   * user to edit their own config.
   */
  args?: string[];
  /** Where this agent's notifications come from. "plugin" = injected hook/plugin
   *  POSTs to /notify (richer, intent-aware) and the OSC scanner is suppressed
   *  for its terminals; "osc" = rely on the terminal OSC scanner. */
  notificationSource: "plugin" | "osc";
  /** Where this agent's session NAME comes from. "structured" = a hook/plugin
   *  correlates the terminal to an on-disk session file (or, for opencode,
   *  pushes the title inline) and the OSC-2 title scanner is suppressed for its
   *  terminals; "osc" = rely on the terminal's OSC-0/2 window-title escapes.
   *  Deliberately NOT the same set as notificationSource: cursor-agent has
   *  plugin notifications but no structured title source (title-resolver.ts has
   *  no cursor-agent case), so gating its OSC title would kill auto-naming;
   *  github-copilot has a structured title source (materializeCopilotPlugin's
   *  sessionStart hook) despite osc-sourced notifications. See
   *  [[two-perspawn-injection-systems-separate]]-style split — these are
   *  independently-toggled signals, not one flag. */
  titleSource: "structured" | "osc";
  /** Argv appended to the base launch args to resume a specific agent-native
   *  conversation. `[]` = no verified resume-by-id support (fresh start). */
  resume: (agentSessionId: string) => string[];
  /** Argv appended LAST so the interactive TUI opens with a prompt already
   *  submitted. `[]` = no VERIFIED interactive form; see initial-prompt.ts for
   *  why an unverified `--` separator is worse than the misparse it guards. */
  initialPrompt: (prompt: string) => string[];
  /** Extra launch environment, applied only on the registry-key launch path.
   *  Absent = the agent needs no generated config to notify. */
  env?: (ctx: LaunchEnvCtx) => Record<string, string>;
  /** ToolUpdateSpec minus its `tool` field — the registry key already is it.
   *  Absent = the agent ships no self-updater (github-copilot is IDE-bound). */
  update?: Omit<ToolUpdateSpec, "tool">;
  hooks?: HookProfile;
  /** Presence is what makes a tool chat-capable; there is no separate list. */
  driver?: SpecDriverFactory;
  /** Headless one-shot judge for the supervisor. Absent = no VERIFIED headless
   *  judge for this tool, which gates the Handler off (escalate-only) rather
   *  than guessing an argv. `tier` and `cmd` are one field precisely because
   *  they must never drift: "readonly" asserts the argv provably restricts the
   *  tool to reads, "transcript" that the restriction is config-level and
   *  unverified — and the tier is what decides whether the judge is handed a
   *  transcript path it could act on. */
  judge?: { tier: JudgeTier; cmd: (prompt: string, model?: string) => string[] };
  /** Returns messages AND, only when the source is a followable file, its path.
   *  Never synthesize a path: a "transcript"-tier judge has no verified
   *  read-only restriction, so it gets no file hint it could not follow. */
  transcript?: (opts: TranscriptOpts) => Promise<{ msgs: string[]; transcriptPath?: string }>;
  /** Reads this agent's own session name, tagged `generated` vs `first-message`
   *  (see ResolvedTitle — the tag drives whether we spend a model call). Absent
   *  = the agent has no on-disk name to read: opencode pushes its title inline
   *  on the loopback post, cursor-agent stores none at all. */
  resolveTitle?: (args: TitleArgs) => Promise<ResolvedTitle | null>;
}
