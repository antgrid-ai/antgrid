import {
  cmdProgramToken, escapeCmdArg, expandWindowsEnv, splitWindowsCommandLine, WINDOWS_CMD_CARRIER_ARGS, WINDOWS_CMDLINE_ENV,
} from "antgrid-agents/windows-argv";

export interface TerminalInvocation {
  command: string;
  args: string[];
  invocationKind?: "exec" | "shell";
}

export interface TerminalInvocationHost {
  platform: NodeJS.Platform;
  shell: string;
  /** The environment the PTY will be spawned with; `%NAME%` in a shell line is expanded against it. */
  env?: Record<string, string | undefined>;
  resolveWindowsExecutable(command: string): { path: string; ext: string } | null;
  requiresWindowsShell(command: string): boolean;
}

interface ResolvedTerminalInvocation {
  command: string;
  args: string[];
  env?: Record<string, string>;
  /** The line cmd.exe runs, which `args` only reference through `env`. */
  cmdLine?: string;
}

/** cmd.exe refuses a longer line ("The input line is too long."). */
const WINDOWS_CMD_LINE_LIMIT = 8191;
/** cmd.exe parses the carried line behind this, inside the same limit. */
const CARRIER_PREFIX_LENGTH = `set ${WINDOWS_CMDLINE_ENV}=& `.length;
/** A batch shim re-expands `%*` behind its own expanded prefix (an npm shim's
 * COMSPEC, node path and script path), and that line must fit the limit too. */
const BATCH_SHIM_HEADROOM = 1024;
/** CreateProcess's lpCommandLine limit, terminating NUL included. */
const WINDOWS_PROCESS_LINE_LIMIT = 32_767;

type WindowsShellLimitReason = "nul" | "newline" | "length";

export class WindowsShellLimitError extends Error {
  constructor(readonly reason: WindowsShellLimitReason, program: string) {
    super(
      reason === "nul"
        ? `Windows cannot pass a NUL character on a command line, so "${program}" cannot be launched with an argument that contains one`
        : reason === "newline"
          ? `cmd.exe cannot carry a newline in the command line, so "${program}" cannot be launched with an argument that contains one`
          : `The Windows command line for "${program}" would be too long, so it cannot be launched with arguments this long`,
    );
    this.name = "WindowsShellLimitError";
  }
}

type Resolved = { path: string; ext: string } | null;

/** Only a bare name without a program extension is looked up on PATH; anything else names itself. */
function probe(program: string, host: TerminalInvocationHost): Resolved {
  return /[\\/]/.test(program) || /\.(exe|com|cmd|bat)$/i.test(program) ? null : host.resolveWindowsExecutable(program);
}

/** Only a known PE binary is parsed once; anything else is assumed to be a batch shim. */
function isPeBinary(program: string, found: Resolved): boolean {
  return /\.(exe|com)$/i.test(program) || found?.ext === ".exe" || found?.ext === ".com";
}

type Plan =
  | { via: "direct"; command: string }
  | { via: "cmd"; line: string; program: string; batch: boolean };

/** `line` is already %-expanded. */
function shellLinePlan(line: string, args: string[], host: TerminalInvocationHost): Plan {
  const program = splitWindowsCommandLine(line)[0] ?? line;
  const batch = !isPeBinary(program, probe(program, host));
  return { via: "cmd", line: [line, ...args.map((a) => escapeCmdArg(a, batch))].join(" "), program, batch };
}

function isShellLine({ command, args, invocationKind }: TerminalInvocation): boolean {
  return invocationKind === "shell" || (invocationKind === undefined && args.length === 0 && /\s/.test(command));
}

/** Windows only. */
function plan(invocation: TerminalInvocation, host: TerminalInvocationHost): Plan {
  const { args } = invocation;
  // A YAML block scalar (`command: >`) always ends in a newline, which carries
  // nothing; only a newline INSIDE the command still refuses below.
  // cmd expands the carrier variable once and never rescans what it held, so
  // the command's own %NAME% references are expanded here, against the PTY
  // environment. cmd's dynamic variables (%CD%, %RANDOM%, %DATE%, %TIME%,
  // %ERRORLEVEL%) and the %NAME:~a,b% / %NAME:x=y% forms are not in that
  // environment and reach the program literally. Letting cmd rescan instead
  // would expand `%` inside the escaped arguments as well, an injection path.
  const command = expandWindowsEnv(invocation.command.replace(/[\r\n]+$/, ""), host.env ?? {});
  if (isShellLine(invocation)) return shellLinePlan(command, args, host);

  const found = probe(command, host);
  const pe = isPeBinary(command, found);
  // A configured command line (`npx claude`, `npm run dev`, `node "C:\x\y.js"`)
  // rather than one program: nothing on PATH answers to the whole string, and
  // it either quotes a token or does not end in a program extension.
  if (!found && /\s/.test(command) && (command.includes("\"") || !/\.(exe|com|cmd|bat)$/i.test(command))) {
    return shellLinePlan(command, args, host);
  }
  const needsCmd = /\.(cmd|bat)$/i.test(command) || host.requiresWindowsShell(command) || (!/[\\/]/.test(command) && !pe);
  if (!needsCmd) return { via: "direct", command: found?.path ?? command };
  if (command.includes("\"")) throw new Error("A Windows executable path cannot contain a double quote");
  return {
    via: "cmd",
    line: [cmdProgramToken(command), ...args.map((a) => escapeCmdArg(a, !pe))].join(" "),
    program: command,
    batch: !pe,
  };
}

function limitOf(p: Plan, args: readonly string[]): WindowsShellLimitReason | undefined {
  if (p.via === "direct") {
    const all = [p.command, ...args];
    // bun-pty ends its NUL-separated strings there, so the launch would fail opaquely.
    if (all.some((a) => a.includes("\0"))) return "nul";
    // An upper bound on the line bun-pty builds: every element quoted and
    // spaced, every `"` and `\` escaped.
    const length = all.reduce((n, a) => n + a.length + 3 + (a.match(/["\\]/g)?.length ?? 0), 0);
    return length >= WINDOWS_PROCESS_LINE_LIMIT ? "length" : undefined;
  }
  // The carried line is one entry of a NUL-separated environment block, so a
  // NUL would end it early and turn the rest into environment entries.
  if (p.line.includes("\0")) return "nul";
  if (/[\r\n]/.test(p.line)) return "newline";
  const budget = WINDOWS_CMD_LINE_LIMIT - CARRIER_PREFIX_LENGTH - (p.batch ? BATCH_SHIM_HEADROOM : 0);
  if (p.line.length > budget) return "length";
  return undefined;
}

/** What stops Windows from carrying this launch, without throwing; undefined when nothing does. */
export function windowsShellLimit(
  invocation: TerminalInvocation,
  host: TerminalInvocationHost,
): WindowsShellLimitReason | undefined {
  if (host.platform !== "win32") return undefined;
  return limitOf(plan(invocation, host), invocation.args);
}

export function resolveTerminalInvocation(
  invocation: TerminalInvocation,
  host: TerminalInvocationHost,
): ResolvedTerminalInvocation {
  if (host.platform !== "win32") {
    return isShellLine(invocation)
      ? { command: host.shell, args: ["-c", invocation.command, ...invocation.args] }
      : { command: invocation.command, args: invocation.args };
  }
  const p = plan(invocation, host);
  const reason = limitOf(p, invocation.args);
  if (reason) throw new WindowsShellLimitError(reason, p.via === "direct" ? p.command : p.program);
  if (p.via === "direct") return { command: p.command, args: invocation.args };
  return {
    command: host.shell,
    args: [...WINDOWS_CMD_CARRIER_ARGS],
    env: { [WINDOWS_CMDLINE_ENV]: p.line },
    cmdLine: p.line,
  };
}
