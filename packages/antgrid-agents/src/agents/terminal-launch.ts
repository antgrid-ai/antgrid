import { existsSync } from "node:fs";
import { resolveAgent, resolveAgentEnv } from "../known-agents";
import { augmentAgentLaunch } from "../agent-launch-augmenter";
import { resolveApprovalPolicy } from "../agent-approval-policy";
import { initialPromptArgv } from "../initial-prompt";
import { agentSpec } from "./registry";
import type { ApprovalPolicy, LaunchAugmentation } from "./types";

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
}

export interface PreparedTerminalLaunch {
  command: string;
  invocationKind: "exec" | "shell";
  args: string[];
  env: Record<string, string>;
  resumed: boolean;
  promptDelivery: "none" | "included" | "buffered" | "unsupported";
  notificationsInjected?: boolean;
  observation?: LaunchAugmentation["observation"];
  /** Resources allocated before dispatch remain owned until terminal teardown. */
  dispose?: () => void | Promise<void>;
}

export function prepareTerminalLaunch(request: TerminalLaunchRequest): PreparedTerminalLaunch | Promise<PreparedTerminalLaunch> {
  const spec = agentSpec(request.tool ?? request.configured.name);
  if (!request.customCommand && spec?.prepareTerminal) return spec.prepareTerminal(request);
  return prepareCliTerminalLaunch(request);
}

/** Declarative helper for adapters whose terminal is a CLI with additive integration flags. */
export function prepareCliTerminalLaunch(request: TerminalLaunchRequest): PreparedTerminalLaunch {
  const { tool, configured, approvalPolicy, conversation } = request;
  const spec = agentSpec(tool ?? configured.name);
  let command: string;
  let args: string[] = [];
  let env: Record<string, string> = {};
  let augmentation: LaunchAugmentation | undefined;
  const custom = !tool && !!request.customCommand;
  let supportsResume = false;
  if (tool) {
    const resolved = resolveAgent(tool);
    command = resolved.bin;
    args = [...resolved.args];
    env = resolveAgentEnv(tool, request.storeDir);
    augmentation = augmentAgentLaunch(tool, request.storeDir, typeof request.adapterOptions?.cursorDir === "string" ? request.adapterOptions.cursorDir : undefined);
    supportsResume = true;
  } else if (custom) {
    if (approvalPolicy === "bypass") throw new Error("Custom-command sessions do not support bypass approval policy");
    command = request.customCommand!;
  } else {
    command = configured.command;
    args = [...configured.args ?? []];
    if (spec?.augmentsDefaultSpec) {
      augmentation = augmentAgentLaunch(configured.name, request.storeDir, typeof request.adapterOptions?.cursorDir === "string" ? request.adapterOptions.cursorDir : undefined);
      supportsResume = true;
    }
  }
  if (!command) throw new Error("agent.tool or agent.command not configured");
  if (augmentation) {
    args.push(...augmentation.args);
    env = { ...env, ...augmentation.env };
  }
  if (!custom) args.push(...resolveApprovalPolicy(tool ?? configured.name, "terminal", approvalPolicy));
  let conversationArgs: string[] = [];
  if (conversation.kind === "resume" && supportsResume) conversationArgs = spec?.resume(conversation.sessionId) ?? [];
  if (conversation.kind === "fork") {
    if (request.initialPrompt?.trim()) throw new Error("This provider-native fork starts immediately; send a prompt after the fork opens.");
    conversationArgs = spec?.fork.nativeForkArgs?.(conversation.sourceSessionId) ?? [];
    if (!conversationArgs.length) throw new Error("This agent cannot launch the captured native fork.");
  }
  const promptArgs = custom ? [] : initialPromptArgv(tool ?? configured.name, request.initialPrompt ?? "");
  const raw = request.rawArgs?.trim();
  const legacyConfiguredShell = !tool && !custom && args.length === 0 && /\s/.test(command) && !existsSync(command);
  if (raw) {
    const head = custom ? [command] : [shellQuoteArg(command), ...args.map(shellQuoteArg)];
    const tail = conversationArgs.map(shellQuoteArg);
    const after = spec?.resumeIsSubcommand === true;
    command = [...head, ...(after ? [] : tail), raw, ...(after ? tail : []),
      ...(process.platform === "win32" ? [] : promptArgs.map(shellQuoteArg))].join(" ");
    args = process.platform === "win32" ? promptArgs : [];
  } else {
    args = [...args, ...conversationArgs, ...promptArgs];
  }
  return {
    command, args, env,
    invocationKind: raw || custom || legacyConfiguredShell ? "shell" : "exec",
    resumed: conversation.kind === "resume" && conversationArgs.length > 0,
    promptDelivery: !request.initialPrompt?.trim() ? "none" : promptArgs.length > 0 ? "included" : request.promptKind === "fork-handoff" ? "buffered" : "unsupported",
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
