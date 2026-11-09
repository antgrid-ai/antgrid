import { query } from "@anthropic-ai/claude-agent-sdk";
import type { SDKMessage, SDKUserMessage, CanUseTool, OnElicitation } from "@anthropic-ai/claude-agent-sdk";
import { spawn } from "node:child_process";
import { stripInheritedCertOverrides } from "../../host";
import { stripParentClaudeSession } from "./parent-session";
import type { ApprovalPolicy } from "../types";

// The slice of the SDK Query object the driver needs (injectable for tests —
// same rationale as CodexEndpoint). The SDK does not export Query cleanly.
export interface ClaudeQueryLike extends AsyncIterable<SDKMessage> {
  interrupt(): Promise<void>;
  setModel(model?: string): Promise<void>;
  setPermissionMode(mode: string): Promise<void>;
  supportedCommands(): Promise<any[]>;
  supportedModels(): Promise<any[]>;
  // Control-channel RPC returning the full init payload (commands, models,
  // account info) — unlike supportedModels()/supportedCommands(), this
  // resolves even with nothing pushed to the prompt stream, forcing the
  // subprocess to boot eagerly instead of waiting on the first prompt
  // (probe-verified against the real binary; see chat-backend.ts's
  // discoverCapabilities()).
  initializationResult(): Promise<any>;
  // Current context occupancy from the control channel. Optional because test
  // doubles and older SDK shapes may not expose this request.
  getContextUsage?(): Promise<any>;
  // Merges into the flag settings layer mid-session (probe-verified: resolves
  // cleanly whether called before or after boot). effortLevel is the live
  // "set effort" mechanism — there is no dedicated setEffort() on Query.
  // ultracode is the session flag behind Claude Code's top effort rung
  // (xhigh + standing dynamic-workflow orchestration) — it is NOT an
  // effortLevel value, so it's set on its own key.
  applyFlagSettings(settings: { effortLevel?: string | null; ultracode?: boolean }): Promise<void>;
  // Stops a background task by id; the SDK then emits a task_notification
  // with status "stopped" (sdk.d.ts Query.stopTask).
  stopTask(taskId: string): Promise<void>;
  close(): void;
}

export interface PromptStreamController {
  push(msg: SDKUserMessage): void;
  end(reason: string): void;
  isEnded(): boolean;
}

export interface SpawnClaudeOpts {
  cwd: string;
  binPath?: string;
  resume?: string;
  model?: string;
  canUseTool: CanUseTool;
  onElicitation?: OnElicitation;
  onStderr: (line: string) => void;
  abortController: AbortController;
  extraArgs?: Record<string, string | null>;
  extraEnv?: Record<string, string>;
  approvalPolicy?: ApprovalPolicy;
  allowedTools?: string[];
}

export interface SpawnedClaude {
  query: ClaudeQueryLike;
  controller: PromptStreamController;
}

// Keep native provider/configuration variables while removing parent-session
// identity. A chat child must own its session without losing the user's setup.
export function buildClaudeEnv(base?: Record<string, string | undefined>): Record<string, string> {
  const src = base ?? (process.env as Record<string, string | undefined>);
  const env = stripInheritedCertOverrides(stripParentClaudeSession({ ...src }) as Record<string, string>);
  env.CLAUDE_CODE_ENTRYPOINT ??= "cli";                 // first-party rate-limit lane
  // Antgrid owns the session lifecycle; a conversation that hands itself to
  // Claude Code's own background supervisor leaves the slot pointing at a job
  // this bridge does not manage. Chat mode surfaces claude's slash commands
  // (chat-backend's ingestCommands), so `/background` is reachable here too.
  env.CLAUDE_CODE_DISABLE_AGENT_VIEW ??= "1";
  if (process.platform === "win32" && env.USERPROFILE) env.HOME ??= env.USERPROFILE;
  return env;
}

// Explicit paths win verbatim; bare names (incl. the known-agents default
// "claude") must be resolved via PATH because the SDK spawns the executable
// directly — no shell lookup, so a bare name won't spawn on Windows.
export function resolveClaudeBinary(pathHint?: string): string {
  const hint = pathHint ?? "claude";
  if (hint.includes("/") || hint.includes("\\")) return hint;
  return Bun.which(hint) ?? hint; // PATH is augmented at host startup (host-path.ts); let query() surface a not-found error otherwise
}

// Persistent prompt stream: yields queued user messages and blocks (never
// returns) until end() so the SDK keeps the binary's stdin open for the whole
// session. Ending it lets streamInput() return → transport.endInput() closes
// stdin cleanly. See spawn/driver notes: bare-string prompts cause "Stream closed".
export function createPersistentPromptStream(initial?: SDKUserMessage): {
  iterable: AsyncIterable<SDKUserMessage>; controller: PromptStreamController;
} {
  const queue: SDKUserMessage[] = [];
  if (initial) queue.push(initial);
  let ended = false;
  let wake: (() => void) | null = null;
  const notify = () => { const w = wake; wake = null; w?.(); };

  async function* gen(): AsyncGenerator<SDKUserMessage> {
    while (true) {
      while (queue.length) yield queue.shift()!;
      if (ended) return;
      await new Promise<void>((r) => { wake = r; });
    }
  }
  return {
    iterable: gen(),
    controller: {
      push: (m) => { queue.push(m); notify(); },
      end: () => { ended = true; notify(); },
      isEnded: () => ended,
    },
  };
}

export function spawnClaude(opts: SpawnClaudeOpts, sdkQuery: typeof query = query): SpawnedClaude {
  const { iterable, controller } = createPersistentPromptStream();
  const q = sdkQuery({
    prompt: iterable,
    options: {
      pathToClaudeCodeExecutable: resolveClaudeBinary(opts.binPath),
      cwd: opts.cwd,
      settingSources: ["user", "project", "local"],
      systemPrompt: { type: "preset", preset: "claude_code" },
      ...(opts.approvalPolicy === "bypass"
        ? { permissionMode: "bypassPermissions", allowDangerouslySkipPermissions: true }
        : {}),
      // Owning the spawn is the only way to drop the SDK's forced default mode
      // (see nativeClaudeArgs). It also turns the SDK's `stderr` option inert,
      // so stderr is read here.
      spawnClaudeCodeProcess: (options) => {
        const child = spawn(options.command, nativeClaudeArgs(options.args),
          { cwd: options.cwd, env: options.env, signal: options.signal, stdio: "pipe", windowsHide: true });
        child.stderr.on("data", (chunk: Buffer) => opts.onStderr(chunk.toString()));
        return child;
      },
      canUseTool: opts.canUseTool,
      onElicitation: opts.onElicitation,
      env: { ...buildClaudeEnv(), ...(opts.extraEnv ?? {}) },
      abortController: opts.abortController,
      ...(opts.model ? { model: opts.model } : {}),
      ...(opts.resume ? { resume: opts.resume } : {}),
      ...(opts.extraArgs ? { extraArgs: opts.extraArgs } : {}),
      // Allow rules, not canUseTool: the user's deny rules still outrank them. The SDK
      // warns (CLAUDE_SDK_CAN_USE_TOOL_SHADOWED) that canUseTool is skipped for these
      // tools on every query; that is the intent, not a misconfiguration.
      ...(opts.allowedTools ? { allowedTools: opts.allowedTools } : {}),
    },
  }) as unknown as ClaudeQueryLike;
  return { query: q, controller };
}

// The pinned SDK emits --permission-mode default even when no mode is selected.
// Leave that choice to the CLI so permissions.defaultMode in native settings
// remains effective; explicit Antgrid bypass and live mode picks still win.
export function nativeClaudeArgs(args: string[]): string[] {
  const result = [...args];
  const at = result.indexOf("--permission-mode");
  if (at >= 0 && result[at + 1] === "default") result.splice(at, 2);
  return result;
}
