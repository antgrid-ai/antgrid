import { hookShellCommand, type HookCommand } from "./hook-command";

export interface GeminiCommandHook {
  type: "command";
  command: string;
}
export interface GeminiHookDefinition {
  hooks: GeminiCommandHook[];
}
export interface GeminiHooks {
  SessionStart: GeminiHookDefinition[];
  // gemini's turn-end event is keyed `Stop` (its UI label is "After Agent
  // Hooks"); there is no `AfterAgent` config key — writing one silently no-ops.
  // The bridge command token stays `after-agent` to match HOOK_EVENTS in hook-runner.ts.
  Stop: GeminiHookDefinition[];
}

export function buildGeminiHooks(
  command: HookCommand,
  agent: "gemini",
): GeminiHooks {
  const make = (event: "session-start" | "after-agent"): GeminiHookDefinition[] => [
    { hooks: [{ type: "command", command: hookShellCommand(command, agent, event) }] },
  ];
  return {
    SessionStart: make("session-start"),
    Stop: make("after-agent"),
  };
}

export function composeGeminiDefaults(opts: {
  general?: Record<string, unknown>;
  hooks?: GeminiHooks;
}): Record<string, unknown> {
  return {
    ...(opts.general ? { general: opts.general } : {}),
    ...(opts.hooks ? { hooks: opts.hooks } : {}),
  };
}
