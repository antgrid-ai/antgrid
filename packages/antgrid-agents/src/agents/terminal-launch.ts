import { existsSync } from "node:fs";
import { resolveAgent, resolveAgentEnv } from "../known-agents";
import { augmentAgentLaunch } from "../agent-launch-augmenter";
import { resolveApprovalPolicy } from "../agent-approval-policy";
import { initialPromptArgv } from "../initial-prompt";
import { windowsRawArgv } from "./windows-argv";
import { agentSpec } from "./registry";
import type { ApprovalPolicy, LaunchAugmentation } from "./types";
import type { AgentRunScope } from "../run-scope";
import type { AgentHostServices } from "../host";
import type { AgentSpec } from "./types";
import type { TerminalAgentEvent } from "../terminal-events";

export type TerminalConversation =
  | { kind: "fresh" }
  | { kind: "resume"; sessionId: string }
  | { kind: "fork"; sourceSessionId: string };

export interface TerminalLaunchRequest {
  readonly tool?: string;
  readonly customCommand?: string;
  readonly configured: { readonly name: string; readonly command: string; readonly args?: readonly string[] };
  readonly rawArgs?: string;
  readonly conversation: TerminalConversation;
  readonly initialPrompt?: string;
  readonly promptKind?: "initial" | "fork-handoff";
  readonly approvalPolicy: ApprovalPolicy;
  readonly storeDir: string;
  readonly adapterOptions?: Record<string, unknown>;
  readonly cwd: string;
  readonly signal: AbortSignal;
  readonly scope: AgentRunScope<TerminalAgentEvent>;
}

export interface PreparedTerminalLaunch {
  command: string;
  invocationKind: "exec" | "shell";
  args: string[];
  env: Record<string, string>;
  resumed: boolean;
  promptDelivery: "none" | "included" | "buffered" | "adapter" | "unsupported";
  /** How many trailing `args` carry the opening prompt, so a host that cannot
   * pass them (cmd.exe cannot carry a newline) can drop them and type the prompt instead. */
  promptArgCount?: number;
  notificationsInjected?: boolean;
  observation?: LaunchAugmentation["observation"];
  /** The host durably records the attempt before this provider mutation, and
   * persists the returned identity before dispatching its resume invocation. */
  createNativeFork?: () => Promise<{ nativeId: string; launch: PreparedTerminalLaunch }>;
  /** Resources allocated before dispatch remain owned until terminal teardown. */
  dispose?: () => void | Promise<void>;
  attach?: (terminal: { write(data: string): void; submit(text: string): void }, scope: AgentRunScope<TerminalAgentEvent>) => Promise<void>;
  deliverPrompt?: (text: string, scope: AgentRunScope<TerminalAgentEvent>) => Promise<void>;
}

export function prepareTerminalLaunch(request: TerminalLaunchRequest): PreparedTerminalLaunch | Promise<PreparedTerminalLaunch> {
  const spec = agentSpec(request.tool ?? request.configured.name);
  if (!request.customCommand && spec?.prepareTerminal) return spec.prepareTerminal(request);
  return prepareCliTerminalLaunch(request);
}

/** Declarative helper for adapters whose terminal is a CLI with additive integration flags. */
export function prepareCliTerminalLaunch(request: TerminalLaunchRequest, runtime?: { get(tool: string): AgentSpec | undefined; host: AgentHostServices }): PreparedTerminalLaunch {
  const { tool, configured, approvalPolicy, conversation } = request;
  const spec = runtime ? runtime.get(tool ?? configured.name) : agentSpec(tool ?? configured.name);
  const augment = (id: string) => augmentAgentLaunch(id, {
    abDir: request.storeDir,
    cursorDir: typeof request.adapterOptions?.cursorDir === "string" ? request.adapterOptions.cursorDir : undefined,
    kimiHome: typeof request.adapterOptions?.kimiHome === "string" ? request.adapterOptions.kimiHome : undefined,
    hookCommand: runtime?.host.hookCommand(),
    mcpCommand: runtime?.host.mcpCommand?.(),
  }, runtime?.get);
  let command: string;
  let args: string[] = [];
  let env: Record<string, string> = {};
  let augmentation: LaunchAugmentation | undefined;
  const custom = !tool && !!request.customCommand;
  let supportsResume = false;
  if (tool) {
    const resolved = runtime ? { bin: spec?.cli?.bin ?? "", args: spec?.cli?.args ?? [] } : resolveAgent(tool);
    command = resolved.bin;
    args = [...resolved.args];
    env = runtime ? spec?.cli?.env?.({ abDir: request.storeDir }) ?? {} : resolveAgentEnv(tool, request.storeDir);
    augmentation = augment(tool);
    supportsResume = true;
  } else if (custom) {
    if (approvalPolicy === "bypass") throw new Error("Custom-command sessions do not support bypass approval policy");
    command = request.customCommand!;
  } else {
    command = configured.command;
    args = [...configured.args ?? []];
    if (spec?.augmentsDefaultSpec) {
      augmentation = augment(configured.name);
      supportsResume = true;
    }
  }
  if (!command) throw new Error("agent.tool or agent.command not configured");
  if (augmentation) {
    args.push(...augmentation.args);
    env = { ...env, ...augmentation.env };
  }
  if (!custom) args.push(...resolveApprovalPolicy(tool ?? configured.name, "terminal", approvalPolicy, runtime?.get));
  let conversationArgs: string[] = [];
  if (conversation.kind === "resume" && supportsResume) conversationArgs = spec?.cli?.resume?.(conversation.sessionId) ?? [];
  if (conversation.kind === "fork") {
    if (request.initialPrompt?.trim()) throw new Error("This provider-native fork starts immediately; send a prompt after the fork opens.");
    conversationArgs = spec?.cli?.nativeForkArgs?.(conversation.sourceSessionId) ?? [];
    if (!conversationArgs.length) throw new Error("This agent cannot launch the captured native fork.");
  }
  const prompt = request.initialPrompt?.trim();
  const promptArgs = custom || !prompt ? [] : runtime ? spec?.cli?.initialPrompt?.(prompt) ?? [] : initialPromptArgv(tool ?? configured.name, prompt);
  const raw = request.rawArgs?.trim();
  const legacyConfiguredShell = !tool && !custom && args.length === 0 && /\s/.test(command) && !existsSync(command);
  // On Windows the raw args string becomes the argv cmd.exe would have handed
  // the agent, rather than cmd syntax, so its quoted paths reach the agent
  // verbatim and none of it runs as a command. What cmd would also have done
  // with it is lost; windows-argv.ts lists it. A custom or legacy command is
  // itself a shell line, so it keeps the shell.
  const rawArgv = raw && process.platform === "win32" && !custom && !legacyConfiguredShell
    ? windowsRawArgv(raw, { ...process.env, ...env })
    : undefined;
  if (rawArgv) {
    const after = spec?.cli?.resumeIsSubcommand === true;
    args = [...args, ...(after ? [] : conversationArgs), ...rawArgv, ...(after ? conversationArgs : []), ...promptArgs];
  } else if (raw) {
    const head = custom ? [command] : [shellQuoteArg(command), ...args.map(shellQuoteArg)];
    const tail = conversationArgs.map(shellQuoteArg);
    const after = spec?.cli?.resumeIsSubcommand === true;
    command = [...head, ...(after ? [] : tail), raw, ...(after ? tail : []),
      ...(process.platform === "win32" ? [] : promptArgs.map(shellQuoteArg))].join(" ");
    args = process.platform === "win32" ? promptArgs : [];
  } else {
    args = [...args, ...conversationArgs, ...promptArgs];
  }
  return {
    command, args, env,
    invocationKind: (raw && !rawArgv) || custom || legacyConfiguredShell ? "shell" : "exec",
    resumed: conversation.kind === "resume" && conversationArgs.length > 0,
    promptDelivery: !request.initialPrompt?.trim() ? "none" : promptArgs.length > 0 ? "included" : request.promptKind === "fork-handoff" ? "buffered" : "unsupported",
    // On POSIX the folded branch quotes the prompt into `command`, so it is not a trailing arg there.
    promptArgCount: promptArgs.length > 0 && (process.platform === "win32" || !raw) ? promptArgs.length : undefined,
    notificationsInjected: augmentation?.notificationsInjected,
    observation: augmentation?.observation,
  };
}

function shellQuoteArg(value: string): string {
  if (value === "" || !/[\s"'\\]/.test(value)) return value;
  return process.platform === "win32"
    ? `"${value.replace(/"/g, '""')}"`
    : `'${value.replace(/'/g, `'\\''`)}'`;
}
