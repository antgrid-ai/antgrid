import type { HookCommand } from "antgrid-agents/hook-command";
export { hookArgv, hookShellCommand, type HookCommand, type HookShellCommandOptions } from "antgrid-agents/hook-command";
export type BridgeCommand = HookCommand;

/**
 * The bridge subcommands that exist so the bridge can invoke ITSELF. The
 * shipped bridge is a compiled single-file executable, so `process.execPath`
 * plus a subcommand is the only self-invocation available — `bun run <script>`
 * has no script to run.
 */
export type BridgeSubcommand = "hook" | "mcp";

export interface ResolveBridgeCommandOptions {
  compiled?: boolean;
  binary?: string;
  entrypoint?: string;
}

export type ResolveHookCommandOptions = ResolveBridgeCommandOptions;

export function resolveBridgeCommand(
  sub: BridgeSubcommand,
  opts: ResolveBridgeCommandOptions = {},
): BridgeCommand {
  const binary = opts.binary ?? process.execPath;
  const compiled =
    opts.compiled ?? process.env.ANTGRID_BRIDGE_COMPILED === "1";
  if (compiled) return { binary, preargs: [sub] };
  return {
    binary,
    preargs: [opts.entrypoint ?? Bun.main, sub],
  };
}

export function resolveHookCommand(
  opts: ResolveHookCommandOptions = {},
): BridgeCommand {
  return resolveBridgeCommand("hook", opts);
}

export function resolveMcpCommand(
  opts: ResolveBridgeCommandOptions = {},
): BridgeCommand {
  return resolveBridgeCommand("mcp", opts);
}

export function mcpArgv(command: BridgeCommand): string[] { return [command.binary, ...command.preargs]; }
