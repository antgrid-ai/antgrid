export interface HookCommand {
  binary: string;
  preargs: string[];
}

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

export function hookArgv(
  command: HookCommand,
  agent: string,
  event: string,
): string[] {
  return [command.binary, ...command.preargs, agent, event];
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
   * consumer that supplies its own — see the note on the call operator below.
   */
  callOperator?: boolean;
}

export function hookShellCommand(
  command: HookCommand,
  agent: string,
  event: string,
  { platform = process.platform, callOperator = true }: HookShellCommandOptions = {},
): string {
  const quote = platform === "win32" ? quoteWindows : quotePosix;
  const rendered = hookArgv(command, agent, event).map(quote).join(" ");
  // Agents run hook commands through the user's shell, which on Windows is
  // PowerShell (codex hard-codes that; copilot was measured to match). There a
  // quoted program path parses as a string expression rather than a command, so
  // without `&` the hook silently never runs — and the quotes can't just be
  // dropped, since the default install path contains a space. POSIX shells
  // execute the quoted form directly and treat a leading `&` as a syntax error.
  return platform === "win32" && callOperator ? `& ${rendered}` : rendered;
}
