/** How to re-enter this bridge: the program to run plus everything that has to
 *  precede the subcommand's own arguments. */
export interface BridgeCommand {
  binary: string;
  preargs: string[];
}

export type HookCommand = BridgeCommand;

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

export function hookArgv(
  command: BridgeCommand,
  agent: string,
  event: string,
): string[] {
  return [command.binary, ...command.preargs, agent, event];
}

/** The MCP server takes no arguments of its own — the caller's identity comes
 *  from the spawn environment, never from argv. */
export function mcpArgv(command: BridgeCommand): string[] {
  return [command.binary, ...command.preargs];
}

function quotePosix(value: string): string {
  return `'${value.replace(/'/g, `'"'"'`)}'`;
}

function quoteWindows(value: string): string {
  return `"${value.replace(/\\/g, "/").replace(/"/g, '\\"')}"`;
}

export interface HookShellCommandOptions {
  platform?: NodeJS.Platform;
  /**
   * Whether to emit PowerShell's `&` call operator. Turn this off only for a
   * consumer that does not route the command through PowerShell (cursor
   * tokenizes the string into argv itself) — see the note below.
   */
  callOperator?: boolean;
  /**
   * Quote every token with double quotes regardless of platform — for a
   * consumer that tokenizes the command into argv itself instead of handing
   * it to the platform shell. POSIX single quotes are shell syntax; under an
   * argv tokenizer they survive as literal bytes in the program path.
   */
  forceDoubleQuotes?: boolean;
}

export function hookShellCommand(
  command: HookCommand,
  agent: string,
  event: string,
  {
    platform = process.platform,
    callOperator = true,
    forceDoubleQuotes = false,
  }: HookShellCommandOptions = {},
): string {
  const quote =
    platform === "win32" || forceDoubleQuotes ? quoteWindows : quotePosix;
  const rendered = hookArgv(command, agent, event).map(quote).join(" ");
  // Agents run hook commands through the user's shell, which on Windows is
  // PowerShell (codex hard-codes that; copilot was measured to match). There a
  // quoted program path parses as a string expression rather than a command, so
  // without `&` the hook silently never runs — and the quotes can't just be
  // dropped, since the default install path contains a space. POSIX shells
  // execute the quoted form directly and treat a leading `&` as a syntax error.
  return platform === "win32" && callOperator ? `& ${rendered}` : rendered;
}
