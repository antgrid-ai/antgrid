import { ClaudeDriver } from "./chat-backend";
import { spawnClaude } from "./spawn";
import type { StructuredDriver } from "../../structured/structured-manager";
import type { DriverCtx } from "../types";

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
  // auto-names the session from the conversation. chatAug.args is
  // ["--plugin-dir", <dir>]; map it to the SDK's extraArgs shape.
  const chatAug = ctx.chatAugment();
  const pluginDir = chatAug.args[chatAug.args.indexOf("--plugin-dir") + 1];
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
