import { ClaudeDriver } from "./chat-backend";
import { spawnClaude } from "./spawn";
import type { StructuredDriver } from "../../structured/structured-manager";
import type { DriverCtx } from "../types";

/**
 * The plugin directory out of a merged launch augmentation, or nothing when
 * this spawn carries none.
 *
 * Index-CHECKED, and that is the whole point: the augmentation merges two
 * profiles that fail independently, so a spawn whose plugin write failed still
 * carries the MCP pair. `args[indexOf(...) + 1]` reads `args[0]` on a miss and
 * hands claude the literal `--mcp-config` as a directory — a launch failure,
 * where the augmenter's contract is a session that starts without the plugin.
 */
export function pluginDirArg(args: string[]): string | undefined {
  const at = args.indexOf("--plugin-dir");
  return at >= 0 ? args[at + 1] : undefined;
}

export function createDriver(ctx: DriverCtx): StructuredDriver {
  // Bounded tail of the subprocess's stderr: startup failures (bad auth,
  // corrupted install) otherwise vanish silently — the SDK only invokes
  // this callback, it never surfaces stderr any other way.
  const stderrLines: string[] = [];
  let stderrBytes = 0;
  const pushStderr = (chunk: string) => {
    for (const line of chunk.split("\n")) {
      if (!line) continue;
      stderrLines.push(line);
      stderrBytes += line.length;
    }
    while (stderrLines.length > 40 || stderrBytes > 8_192) {
      stderrBytes -= stderrLines.shift()?.length ?? 0;
    }
  };
  // Reuse the terminal-mode title plugin in chat mode so /session-title
  // auto-names the session from the conversation. Only the plugin dir is
  // lifted out of the augmentation and mapped to the SDK's extraArgs shape:
  // the MCP `--mcp-config` flag riding alongside it has no verified form
  // here, so chat sessions get no Antgrid tools.
  const chatAug = ctx.chatAugment();
  const pluginDir = pluginDirArg(chatAug.args);
  // `claude update` is install-method-sensitive, but this is detection
  // only; the run itself is fail-soft (see the agent:update handler).
  ctx.emitUpdateCheck();
  return new ClaudeDriver({
    sessionId: ctx.sessionId,
    sendMessage: ctx.send,
    cwd: ctx.projectPath,
    spawn: ({ canUseTool, abort, resume }) =>
      spawnClaude({ cwd: ctx.projectPath, canUseTool, resume,
        approvalPolicy: ctx.approvalPolicy,
        onStderr: pushStderr, abortController: abort,
        ...(pluginDir ? { extraArgs: { "plugin-dir": pluginDir } } : {}),
        extraEnv: chatAug.env }),
    onSessionId: ctx.onAgentSession,
    stderrTail: () => stderrLines.join("\n"),
  });
}
