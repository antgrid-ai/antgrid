import { execFile } from "node:child_process";
import { z } from "zod";
import { CLIPBOARD_MAX_BYTES } from "./limits";

export type HostClipboardResult = { text: string } | { error: "unsupported" | "empty" | "too-large" | "unavailable" | "failed" };
export interface ClipboardCommand {
  file: string; args: string[]; env?: NodeJS.ProcessEnv;
  plainTextProbe?: Pick<ClipboardCommand, "file" | "args">;
}

const pasteboardState = z.object({ plainText: z.boolean(), empty: z.boolean(), changeCount: z.number().int().nonnegative() });
const macPlainTextProbe = {
  file: "/usr/bin/osascript", args: ["-l", "JavaScript", "-e",
    "ObjC.import('AppKit'); var p = $.NSPasteboard.generalPasteboard; var t = p.types; JSON.stringify({plainText: !!(t.containsObject($.NSPasteboardTypeString) || t.containsObject('NSStringPboardType')), empty: Number(t.count) === 0, changeCount: Number(p.changeCount)});"],
};

export function hostClipboardCommands(platform = process.platform, env = process.env): ClipboardCommand[] {
  if (platform === "darwin") return [{
    file: "/usr/bin/pbpaste", args: ["-Prefer", "txt"], env: { LC_ALL: "en_US.UTF-8" }, plainTextProbe: macPlainTextProbe,
  }];
  if (platform === "win32") return [{
    file: "powershell.exe", args: ["-NoProfile", "-NonInteractive", "-STA", "-WindowStyle", "Hidden", "-Command",
      "Add-Type -AssemblyName System.Windows.Forms; [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false); if ([System.Windows.Forms.Clipboard]::ContainsText()) { [Console]::Write([System.Windows.Forms.Clipboard]::GetText()) }"],
  }];
  if (platform !== "linux") return [];
  return [
    ...(env.WAYLAND_DISPLAY ? [
      { file: "wl-paste", args: ["--no-newline", "--type", "text/plain;charset=utf-8"] },
      { file: "wl-paste", args: ["--no-newline", "--type", "text/plain"] },
    ] : []),
    ...(env.DISPLAY ? [
      { file: "xclip", args: ["-selection", "clipboard", "-out", "-target", "UTF8_STRING"] },
      { file: "xsel", args: ["--clipboard", "--output"] },
    ] : []),
  ];
}

export type ClipboardCommandRunner = (command: ClipboardCommand, timeout: number, signal?: AbortSignal) => Promise<Buffer | "too-large" | "failed">;
const run: ClipboardCommandRunner = (command, timeout, signal) => new Promise((resolve) => {
  execFile(command.file, command.args, {
    encoding: "buffer", timeout, maxBuffer: CLIPBOARD_MAX_BYTES, windowsHide: true, signal,
    ...(command.env ? { env: { ...process.env, ...command.env } } : {}),
  }, (error, stdout) => {
    if (error) resolve((error as NodeJS.ErrnoException).code === "ERR_CHILD_PROCESS_STDIO_MAXBUFFER" ? "too-large" : "failed");
    else resolve(stdout);
  });
});

export async function readHostClipboard(options: {
  commands?: ClipboardCommand[]; run?: ClipboardCommandRunner; now?: () => number; signal?: AbortSignal;
} = {}): Promise<HostClipboardResult> {
  const commands = options.commands ?? hostClipboardCommands();
  if (!commands.length) return { error: "unsupported" };
  const now = options.now ?? (() => performance.now());
  const deadline = now() + 2000;
  async function execute(command: ClipboardCommand): ReturnType<ClipboardCommandRunner> {
    const remaining = Math.floor(deadline - now());
    if (remaining <= 0 || options.signal?.aborted) return "failed";
    try { return await (options.run ?? run)(command, remaining, options.signal); }
    catch { return "failed"; }
  }
  async function probe(command: ClipboardCommand) {
    const result = await execute(command);
    if (!Buffer.isBuffer(result) || result.length > 1024 || options.signal?.aborted || now() >= deadline) return;
    try { return pasteboardState.parse(JSON.parse(result.toString("utf8"))); } catch { return; }
  }
  for (const command of commands) {
    const before = command.plainTextProbe ? await probe(command.plainTextProbe) : undefined;
    if (command.plainTextProbe) {
      if (!before) return { error: "unavailable" };
      if (!before.plainText) return { error: before.empty ? "empty" : "unsupported" };
    }
    const result = await execute(command);
    if (options.signal?.aborted || now() >= deadline) return { error: "unavailable" };
    if (result === "too-large") return { error: "too-large" };
    if (result === "failed") continue;
    if (!result.length) return { error: "empty" };
    if (result.length > CLIPBOARD_MAX_BYTES) return { error: "too-large" };
    if (command.plainTextProbe) {
      // pbpaste may fall back to RTF/EPS; verify its plain-text type and reject
      // a clipboard replacement between the format check and the actual read.
      const after = await probe(command.plainTextProbe);
      if (!after?.plainText || after.changeCount !== before?.changeCount) return { error: "unavailable" };
    }
    try {
      const text = new TextDecoder("utf-8", { fatal: true }).decode(result);
      return text.includes("\0") ? { error: "failed" } : { text };
    } catch { return { error: "failed" }; }
  }
  return { error: "unavailable" };
}
