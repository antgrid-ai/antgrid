import type { HookCommand } from "antgrid-agents/hook-command";
export { hookArgv, hookShellCommand, type HookCommand, type HookShellCommandOptions } from "antgrid-agents/hook-command";

export interface ResolveHookCommandOptions {
  compiled?: boolean;
  binary?: string;
  entrypoint?: string;
}

export function resolveHookCommand(
  opts: ResolveHookCommandOptions = {},
): HookCommand {
  const binary = opts.binary ?? process.execPath;
  const compiled =
    opts.compiled ?? process.env.ANTGRID_BRIDGE_COMPILED === "1";
  if (compiled) return { binary, preargs: ["hook"] };
  return {
    binary,
    preargs: [opts.entrypoint ?? Bun.main, "hook"],
  };
}
