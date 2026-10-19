// A session's raw args string, turned into the argv a `cmd.exe /c` launch would
// have handed the agent. The agent is then exec'd directly, or behind a shim
// with every element escaped, so its paths and a multi-line prompt reach it
// verbatim and the raw args are never parsed as cmd syntax.
//
// Only two shell steps are reproduced: `%NAME%` expansion (defined names only,
// as on cmd's own command line) against the bridge and launch environment, and
// the child's CommandLineToArgvW split. Everything else cmd would have done is
// lost: names only the PTY receives (ANTGRID_*), cmd's dynamic variables (%CD%,
// %RANDOM%, %DATE%, %TIME%, %ERRORLEVEL%), the %NAME:~a,b% and %NAME:x=y%
// forms, and operators and redirections (`&`, `|`, `2>NUL`), which stay
// literal text.

/** cmd.exe expands `%ANTGRID_CMDLINE%` once and never rescans what it held. */
export const WINDOWS_CMDLINE_ENV = "ANTGRID_CMDLINE";

/**
 * cmd.exe argv that runs the line held in WINDOWS_CMDLINE_ENV. The line cannot
 * ride in argv: spawners quote every element with MSVC rules (`"` -> `\"`),
 * which cmd.exe does not honour. Every token here is free of spaces and quotes,
 * so that quoting leaves them alone; `set` clears the variable so the program
 * never sees it; `/v:off` overrides a registry DelayedExpansion=1, whose `!`
 * pass would undo the caret escaping.
 */
export const WINDOWS_CMD_CARRIER_ARGS = ["/d", "/v:off", "/s", "/c", "set", `${WINDOWS_CMDLINE_ENV}=&`, `%${WINDOWS_CMDLINE_ENV}%`] as const;

const CMD_META = /([()\][%!^"`<>&|;, *?])/g;

/** cross-spawn's escaping. `batch` doubles it because a batch file's `%*` is parsed by cmd a second time. */
export function escapeCmdArg(arg: string, batch: boolean): string {
  let a = arg.replace(/(\\*)"/g, "$1$1\\\"").replace(/(\\*)$/, "$1$1");
  a = `"${a}"`.replace(CMD_META, "^$1");
  return batch ? a.replace(CMD_META, "^$1") : a;
}

/** Quote only when cmd would otherwise split the path: a batch file found on
 * PATH under a QUOTED bare name sees its own %~dp0 as the working directory,
 * which breaks every npm shim (they locate their script through %~dp0). */
export function cmdProgramToken(program: string): string {
  return /[\s()\[\]%!^`<>&|;,=*?]/.test(program) ? `"${program}"` : program;
}

export function windowsRawArgv(raw: string, env: Record<string, string | undefined>): string[] {
  return splitWindowsCommandLine(expandWindowsEnv(raw, env));
}

export function expandWindowsEnv(text: string, env: Record<string, string | undefined>): string {
  const byName = new Map<string, string>();
  for (const [name, value] of Object.entries(env)) if (value !== undefined) byName.set(name.toUpperCase(), value);
  let out = "";
  let i = 0;
  while (i < text.length) {
    const close = text[i] === "%" ? text.indexOf("%", i + 1) : -1;
    const value = close > i + 1 ? byName.get(text.slice(i + 1, close).toUpperCase()) : undefined;
    if (value !== undefined) {
      out += value;
      i = close + 1;
    } else {
      // An undefined name leaves its opening `%` literal and rescans from the
      // next character, so `100% of %USERPROFILE%` still expands the second.
      out += text[i];
      i++;
    }
  }
  return out;
}

/** CommandLineToArgvW / MSVC CRT rules, the parse every Windows agent CLI applies to its own command line. */
export function splitWindowsCommandLine(line: string): string[] {
  const argv: string[] = [];
  let current = "";
  let started = false;
  let quoted = false;
  let i = 0;
  while (i < line.length) {
    const c = line[i];
    if (!quoted && (c === " " || c === "\t")) {
      if (started) argv.push(current);
      current = "";
      started = false;
      i++;
      continue;
    }
    started = true;
    if (c === "\\") {
      let run = 0;
      while (line[i] === "\\") { run++; i++; }
      if (line[i] !== "\"") {
        current += "\\".repeat(run);
      } else {
        // 2n backslashes + quote: n backslashes, and the quote delimits.
        // 2n+1: n backslashes and a literal quote.
        current += "\\".repeat(run >> 1);
        if (run % 2 === 1) { current += "\""; i++; }
      }
      continue;
    }
    if (c === "\"") {
      if (quoted && line[i + 1] === "\"") {
        current += "\"";
        i += 2;
      } else {
        quoted = !quoted;
        i++;
      }
      continue;
    }
    current += c;
    i++;
  }
  if (started) argv.push(current);
  return argv;
}
