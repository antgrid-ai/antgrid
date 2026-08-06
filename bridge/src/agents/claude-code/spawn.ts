import { query } from "@anthropic-ai/claude-agent-sdk";
import type { SDKMessage, SDKUserMessage, CanUseTool } from "@anthropic-ai/claude-agent-sdk";
import { stripInheritedCertOverrides } from "../../terminal-session";
import { resolveAgent } from "../../known-agents";

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
  onStderr: (line: string) => void;
  abortController: AbortController;
  extraArgs?: Record<string, string | null>;
  extraEnv?: Record<string, string>;
}

export interface SpawnedClaude {
  query: ClaudeQueryLike;
  controller: PromptStreamController;
}

// A user-set value in any source must win over our default (mirrors
// sdkOptionsBuilder's ENABLE_TOOL_SEARCH guard). Base defaults to process.env.
export function buildClaudeEnv(base?: Record<string, string | undefined>): Record<string, string> {
  const src = base ?? (process.env as Record<string, string | undefined>);
  const env = stripInheritedCertOverrides({ ...src } as Record<string, string>);
  delete (env as any).ANTHROPIC_API_KEY; // never silently bill an API key
  delete (env as any).OPENAI_API_KEY;
  env.CLAUDE_CODE_ENTRYPOINT ??= "cli";                 // first-party rate-limit lane
  env.ENABLE_TOOL_SEARCH ??= "auto:2";                  // trim upfront MCP token load
  env.CLAUDE_CODE_MCP_TOOL_IDLE_TIMEOUT ??= "0";        // don't 300s-kill interactive tools
  if (process.platform === "win32" && env.USERPROFILE) env.HOME = env.USERPROFILE; // stable ~/.claude for resume
  return env;
}

// Explicit paths win verbatim; bare names (incl. the known-agents default
// "claude") must be resolved via PATH because the SDK spawns the executable
// directly — no shell lookup, so a bare name won't spawn on Windows.
export function resolveClaudeBinary(pathHint?: string): string {
  const hint = pathHint ?? resolveAgent("claude-code").bin;
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

export function spawnClaude(opts: SpawnClaudeOpts): SpawnedClaude {
  const { iterable, controller } = createPersistentPromptStream();
  const q = query({
    prompt: iterable,
    options: {
      pathToClaudeCodeExecutable: resolveClaudeBinary(opts.binPath),
      cwd: opts.cwd,
      permissionMode: "default",
      canUseTool: opts.canUseTool,
      env: { ...buildClaudeEnv(), ...(opts.extraEnv ?? {}) },
      abortController: opts.abortController,
      stderr: opts.onStderr,
      ...(opts.model ? { model: opts.model } : {}),
      ...(opts.resume ? { resume: opts.resume } : {}),
      ...(opts.extraArgs ? { extraArgs: opts.extraArgs } : {}),
    },
  }) as unknown as ClaudeQueryLike;
  return { query: q, controller };
}
