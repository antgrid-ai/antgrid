import type { HookCommand } from "../hook-command";
import type { HookInvocation, HookPath, HookPost } from "./hook-posts";
import type { AbMessage } from "../protocol";
import type { StructuredDriver } from "../structured/structured-manager";
import type { HandlerEvent } from "../handler/engine";

/**
 * The provider-lifecycle subset of `HandlerEvent` a chat driver can raise: the
 * terminal is already bound by the factory, and a driver never reports a
 * blocking prompt this way. Derived from `HandlerEvent` so the two cannot drift.
 *
 * Deliberately a driver dep rather than a wire frame: opencode re-reports its
 * limit on every retry attempt, and one `agent:error` per attempt would flood
 * the app transcript with noise about a wait it is already handling.
 */
export type DriverLifecycleEvent =
  Pick<HandlerEvent, "resetsAt" | "errorClass" | "selfResuming"> & {
    event: Extract<HandlerEvent["event"], "limit_hit" | "limit_cleared" | "turn_failed">;
  };

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
  | "antigravity"
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

/** An agent's own on-disk updater state, when it keeps one (codex's
 *  ~/.codex/version.json). Two things we can read for free: a `latest_version`
 *  hint that lets detection work offline, and the `dismissed_version` the user
 *  already declined in the agent's own UI, which we honor rather than re-ask. */
export interface AgentUpdateState {
  latest_version?: string;
  dismissed_version?: string | null;
}

/** How an agent updates itself in place — the whole per-agent surface of the
 *  update path, which is otherwise agent-agnostic (see src/update/). */
export interface AgentUpdate {
  /** npm package whose dist-tags.latest is the "latest" authority. */
  npmPackage: string;
  /** PATH binary name to resolve (realpath) for --version and the updater.
   *  Not always the registry key: claude-code's binary is `claude`. */
  command: string;
  /** argv for the CLI's own self-updater (codex/claude `update`, opencode
   *  `upgrade` — the divergence this field exists to record). */
  updateArgs: string[];
  /** Reads this agent's updater state. Absent = no such file, and detection
   *  runs npm-only with app-side dismissal. */
  readState?: () => AgentUpdateState | null;
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
  /** Overrides the machine-global `~/.gemini/config` that only antigravity
   *  writes into. Test seam, same role as `cursorDir`. */
  geminiConfigDir?: string;
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
  /** Report that the provider stopped serving this session (limit or outage) so
   *  an armed Handler parks instead of going silent. Optional: a driver with no
   *  structured signal for it changes nothing by leaving it unused. */
  onLifecycle?: (evt: DriverLifecycleEvent) => void;
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
  antigravityHome?: string;
}

/** Inputs to a spec's `resumable`. The `*Home` fields are test seams. */
export interface ResumableArgs {
  agentSessionId: string;
  transcriptPath?: string;
  codexHome?: string;
  copilotHome?: string;
}

/**
 * A title read from an agent's own store, tagged with how good it actually is.
 *
 * `kind` is load-bearing, not description, and there are deliberately only two
 * values a resolver may report:
 *
 *   "manual"        — a name the USER typed at the agent (Claude's
 *                     `custom-title`, agy's `/rename`). Their intent, so it
 *                     outranks the one we generate.
 *   "first-message" — an echo of the opening prompt. Better than "Session 3"
 *                     and nothing else; it is what we generate a title to
 *                     REPLACE, and the caller keeps it only until ours lands.
 *
 * There is no value for a title the AGENT generated for itself. Reading those
 * made naming depend on whether a given agent happens to name conversations,
 * how good its names are, and when it writes them — which differed per agent
 * and left the sessions of agents that never name (codex's CLI, every
 * headless/SDK run) echoing the opening prompt forever. Antgrid names sessions
 * itself now, uniformly, from the first user message (see ./title-generate.ts).
 * A resolver that finds an agent-written name must drop it, not report it.
 */
export interface ResolvedTitle {
  title: string;
  kind: "manual" | "first-message";
}

/**
 * How far a headless spawn of an agent's CLI may reach.
 *
 * It describes the ARGV, not the agent: one CLI has a different shape per reach
 * (claude denies write tools for a naming run and allows read tools for a
 * judge), so an agent declares one entry per reach it has a verified command
 * for. Ordered tightest-first — {@link pickHeadless} relies on that.
 *
 *   "sealed"     — no tools at all; everything the model may use is in the prompt.
 *   "readonly"   — the argv provably restricts the tool to reads.
 *   "transcript" — the restriction is config-level and unverified, so the spawn
 *                  is never handed a transcript path it could act on.
 */
export const HEADLESS_REACHES = ["sealed", "readonly", "transcript"] as const;
export type HeadlessReach = (typeof HEADLESS_REACHES)[number];

/** The reaches a judge may run at. A sealed argv cannot read the repo, which is
 *  the one thing a supervisor pass exists to do. */
export type JudgeTier = Exclude<HeadlessReach, "sealed">;

/**
 * One verified non-interactive invocation of an agent's CLI: a prompt in, the
 * model's answer on stdout, nothing persisted.
 *
 * Its own type because the runner may execute one agent's command for ANOTHER
 * agent's work — see resolveHeadless in ./headless.ts.
 */
export interface HeadlessCommand {
  cmd: (prompt: string, model?: string) => string[];
  /** Merged over the bridge's environment for this spawn ONLY — never for a
   *  terminal session, which is the spec-level `env`. */
  env?: Record<string, string>;
  /**
   * HOW this argv keeps the run out of the user's own history. Stated rather
   * than assumed because nothing else can check it: no passing test can tell a
   * spawn that persisted a session from one that did not, and every run that
   * does shows up in the user's own `--resume` picker forever.
   *
   *   "flag"            — an explicit off switch, argv or env (claude's
   *                       --no-session-persistence, codex's --ephemeral,
   *                       vibe's VIBE_SESSION_LOGGING__ENABLED=false).
   *   "ephemeral-store" — `env` points the agent's store somewhere disposable
   *                       (opencode's OPENCODE_DB=:memory:).
   *   "stateless"       — the CLI writes no history in this mode at all.
   *
   * An agent whose CLI offers none of the three gets no entry at that reach:
   * absence costs a borrowed spawn, a wrong claim costs the user's history.
   */
  noHistory: "flag" | "ephemeral-store" | "stateless";
}

/**
 * What the CALLER needs from a headless spawn, which is not the same question
 * as what an argv permits (see {@link HeadlessReach}).
 *
 *   "none" — everything the model may use is inlined into the prompt, so the
 *            tightest available entry wins.
 *   "repo" — reading the working tree IS the work, so a sealed argv cannot
 *            serve it however much tighter it would be.
 */
export type HeadlessNeed = "none" | "repo";

const REACHES_FOR: Record<HeadlessNeed, readonly HeadlessReach[]> = {
  none: HEADLESS_REACHES,
  repo: HEADLESS_REACHES.filter((r) => r !== "sealed"),
};

/**
 * The tightest declared entry that still satisfies `need`, or null.
 *
 * Pure and spec-shaped (it takes the map, not a tool name) so `judgeCapable` in
 * ./registry.ts can answer from it without importing ./headless.ts, which
 * imports the registry back.
 */
export function pickHeadlessFrom(
  declared: AgentSpec["headless"], need: HeadlessNeed,
): { reach: HeadlessReach; command: HeadlessCommand } | null {
  if (!declared) return null;
  for (const reach of REACHES_FOR[need]) {
    const command = declared[reach];
    if (command) return { reach, command };
  }
  return null;
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
  /**
   * Every loopback path this agent's INSTALLED INTEGRATION can POST — whether
   * through `bridge hook` (this profile's `toPosts`) or from inside the agent's
   * own runtime (opencode's in-process plugin, which posts /session-title,
   * /notify and /handler-event and shells out to nothing).
   *
   * Scoped to the integration, not to `toPosts`, because the two questions
   * nothing else can answer from outside are integration-level: does an armed
   * Handler ever hear from this agent's TERMINAL sessions (`/handler-event`),
   * and does the agent probe the hook channel at startup (`/hook-alive`, whose
   * absence the terminal treats as a dead integration).
   *
   * Over-declaring a path only claims a capability nothing exercises; omitting
   * one silently gates a feature off. Keep it in step with `toPosts` and with
   * `bridge/plugin/<agent>/`.
   */
  posts: readonly HookPath[];
  /**
   * Which turn boundaries this agent's hook events actually report. The
   * keystroke turn-start inference (work-status.ts's `userReply({submitted})`)
   * is legal ONLY for a session that reports ENDS but no START: the inferred
   * turn is then guaranteed a closer and cannot wedge on "working".
   *
   * One object, not two arrays, so a profile cannot declare an end without
   * having considered whether it also has a start. Lives beside the `events`
   * list it names, so an agent whose events change cannot silently disagree
   * with the gate.
   *
   * "Boundary", not "notification": copilot's `agent-stop` posts only a title,
   * and claude's `stop-failure` posts a turn-end notify on the fatal classes
   * only. What matters is whether an inferred turn would be closed.
   */
  turnBoundaryEvents: { start: readonly string[]; end: readonly string[] };
  /**
   * True when this agent's plugin host may drop our environment, so a hook
   * invocation that arrives with no ANTGRID_API_PORT falls back to reading
   * `<ANTGRID_DIR>/api.port`. Copilot's plugin host does.
   *
   * Absent is a TRUST BOUNDARY, not an oversight. cursor-agent's hooks are
   * machine-global (`~/.cursor/hooks.json`), so every unrelated cursor-agent run
   * on the box invokes `bridge hook`; the missing ANTGRID_API_PORT is the only
   * thing that makes those runs a no-op (see agents/cursor-agent/hooks.ts's
   * note on why machine-global is safe). A universal port-file fallback would
   * hand the loopback API to any local process that can spell `bridge hook`.
   */
  portFileFallback?: true;
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
   *  plugin notifications but no structured title source (there is no
   *  agents/cursor-agent/title.ts), so gating its OSC title would kill auto-naming;
   *  github-copilot has a structured title source (materializeCopilotPlugin's
   *  sessionStart hook) despite osc-sourced notifications. See
   *  [[two-perspawn-injection-systems-separate]]-style split — these are
   *  independently-toggled signals, not one flag. */
  titleSource: "structured" | "osc";
  /** True when the agent's OSC-2 terminal title is NOT a usable session name —
   *  antigravity's `agy` publishes its own EXECUTABLE PATH as the title, which
   *  would otherwise auto-name the session `C:\...\agy.EXE`. For these the namer
   *  uses `label` until the plugin hook supplies the real conversation title.
   *  Most agents (claude → "Claude Code", cursor → "Cursor Agent") publish a good
   *  name here and leave this unset. */
  oscTitleUnusable?: boolean;
  /** Argv appended to the base launch args to resume a specific agent-native
   *  conversation. `[]` = no verified resume-by-id support (fresh start). */
  resume: (agentSessionId: string) => string[];
  /**
   * True when this agent's resume argv is a SUBCOMMAND (`codex resume <uuid>`)
   * rather than a switch, so it must be appended AFTER the user's raw `args`
   * string. Absent = a switch, which goes ahead of raw args so a user-supplied
   * `--` boundary cannot swallow it.
   *
   * Deliberately separate from `resume` rather than folded into it: `resume`
   * returns the tokens, this says where in the folded shell line they land, and
   * only ONE call site (the args-folding branch of SessionManager.start) is
   * positional at all.
   */
  resumeIsSubcommand?: true;
  /**
   * True when a launch through the antgrid.yaml DEFAULT spec (`agent.command`,
   * no per-session `tool`) still gets this agent's hook injection AND resume
   * argv. One field, not two, because `SessionManager.start()` and
   * `resumeToolFor()` must answer it identically — they diverged silently once.
   *
   * Absent = that path launches the configured command bare. Not a degradation:
   * no other agent's default-spec launch has ever been verified, and widening it
   * changes the argv of every existing antgrid.yaml spawn — claude would gain
   * `--plugin-dir`, codex a `-c hooks.state={…}` block whose trusted_hash is
   * computed for the interactive TUI, not for whatever binary `agent.command`
   * names.
   */
  augmentsDefaultSpec?: true;
  /** Argv appended LAST so the interactive TUI opens with a prompt already
   *  submitted. `[]` = no VERIFIED interactive form; see initial-prompt.ts for
   *  why an unverified `--` separator is worse than the misparse it guards. */
  initialPrompt: (prompt: string) => string[];
  /** Extra launch environment, applied only on the registry-key launch path.
   *  Either a generated config file the agent needs in order to notify, or a
   *  behaviour switch the bridge must pin for every spawn. Absent = neither. */
  env?: (ctx: LaunchEnvCtx) => Record<string, string>;
  /** How this agent updates itself in place. The registry key is the `tool` id
   *  the update path keys by, so it is not restated here.
   *  Absent = the agent ships no self-updater (github-copilot is IDE-bound). */
  update?: AgentUpdate;
  hooks?: HookProfile;
  /**
   * Reads the notification body for this agent's `/notify` posts out of the
   * transcript path the post carried. Absent = the agent carries its final
   * message inline on the post (codex's Stop hook does) or carries no
   * transcript at all, and compose.ts falls back to the type label.
   *
   * Takes a path, not the whole post: the caller has already decided the post
   * carried no inline message, and the path is the only thing this can read.
   */
  notifyBodyFromTranscript?: (transcriptPath: string) => Promise<string | null>;
  /** Presence is what makes a tool chat-capable; there is no separate list. */
  driver?: SpecDriverFactory;
  /**
   * Verified non-interactive invocations of this agent's CLI, keyed by how far
   * each one may reach (see {@link HeadlessReach}). One capability, several
   * consumers: naming a session (./headless.ts via ./title-generate.ts) and the
   * supervisor's judge (../handler/judge.ts) are two callers of the same spawn,
   * and every future one-shot model call belongs here rather than growing a
   * third near-identical field.
   *
   * The reach a caller needs is what selects the entry, and the two questions
   * are NOT the same:
   *   - naming wants the TIGHTEST entry available; the conversation is inlined
   *     into the prompt, so it needs no repo access at all.
   *   - the judge REQUIRES at least "readonly" — reading the repo is the work —
   *     and its reach decides whether it may be handed a transcript path it
   *     could act on. `judgeCapable` therefore stays "has a non-sealed entry",
   *     never "has any entry": collapsing the two is what made "can this agent
   *     name a session" mean "does this agent have a vetted SUPERVISOR", a much
   *     higher bar that left every other agent's sessions unnamed.
   *
   * Every entry must also hold NO WRITES: the model is asked for text and given
   * no transcript path, so deny tools where a flag can and rely on
   * non-interactive permission denial where it can't. Its no-history half is
   * declared per entry — see {@link HeadlessCommand.noHistory}.
   *
   * A missing reach = no argv VERIFIED against the real CLI at that reach. For
   * naming that is not "this agent cannot be named": the prompt carries its own
   * context, so ./headless.ts borrows another installed agent's command rather
   * than guessing this one's flags. Add an entry only after running it.
   */
  headless?: Partial<Record<HeadlessReach, HeadlessCommand>>;
  /** Returns messages AND, only when the source is a followable file, its path.
   *  Never synthesize a path: a "transcript"-tier judge has no verified
   *  read-only restriction, so it gets no file hint it could not follow. */
  transcript?: (opts: TranscriptOpts) => Promise<{ msgs: string[]; transcriptPath?: string }>;
  /** Can this stored id still be resumed? False ONLY when the agent can
   *  POSITIVELY confirm the conversation is gone — a false negative silently
   *  starts a fresh session, so uncertainty must answer true. Absent = this
   *  agent has no store-existence check (the honest answer, not a default);
   *  callers treat absence as resumable. */
  resumable?: (args: ResumableArgs) => boolean;
  /** Reads the name for this agent's session that is NOT one the agent chose
   *  for itself, tagged `manual` vs `first-message` (see ResolvedTitle — the tag
   *  drives whether we spend a model call). Absent = the agent has neither on
   *  disk: opencode and cursor-agent store no rename of their own that we read.
   */
  resolveTitle?: (args: TitleArgs) => Promise<ResolvedTitle | null>;
}
