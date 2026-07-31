import { join } from "node:path";
import { z } from "zod";
import { atomicWriteFile } from "../../discovery";
import { hookShellCommand, type HookCommand } from "../../hook-command";
import { logger } from "../../logger";
import { hasFiles, NO_INJECTION } from "../launch-inject";
import { compact, parseOrEmpty, titlePost, type HookInvocation, type HookPost } from "../hook-posts";
import type { HookInjectCtx, HookPostCtx, LaunchAugmentation } from "../types";

const log = logger.child({ component: "agent-launch" });

function materializeCopilotPlugin(
  abDir: string,
  command: HookCommand,
): string | null {
  const targetDir = join(abDir, "plugin", "copilot");
  const manifestPath = join(targetDir, "plugin.json");
  const manifest = {
    name: "antgrid-copilot",
    version: "0.1.0",
    description: "Antgrid bundled GitHub Copilot plugin",
    hooks: {
      sessionStart: [
        {
          type: "command",
          command: hookShellCommand(command, "github-copilot", "session-start"),
          timeoutSec: 5,
        },
      ],
      agentStop: [
        {
          type: "command",
          command: hookShellCommand(command, "github-copilot", "agent-stop"),
          timeoutSec: 5,
        },
      ],
    },
  };
  try {
    atomicWriteFile(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`);
  } catch (err) {
    log.warn("failed to materialize bundled Copilot plugin: %s", err);
  }
  return hasFiles([manifestPath]) ? targetDir : null;
}

export function inject({ abDir, hookCommand }: HookInjectCtx): LaunchAugmentation {
  const pluginDir = materializeCopilotPlugin(abDir, hookCommand);
  return pluginDir ? { args: ["--plugin-dir", pluginDir], env: {} } : NO_INJECTION;
}

// Copilot has shipped the session id under all of these spellings; the nested
// `session` object is `.nullish()` for the same serde-null reason as its fields.
const CopilotPayloadSchema = z.object({
  sessionId: z.string().nullish(),
  session_id: z.string().nullish(),
  conversationId: z.string().nullish(),
  conversation_id: z.string().nullish(),
  session: z
    .object({
      id: z.string().nullish(),
      sessionId: z.string().nullish(),
    })
    .nullish(),
});

export const events = ["session-start", "agent-stop"] as const;

export async function toPosts(
  invocation: HookInvocation,
  { port, terminalId, readStdin }: HookPostCtx,
): Promise<HookPost[]> {
  const posts: Array<HookPost | null> = [];
  const input = parseOrEmpty(CopilotPayloadSchema, await readStdin());
  if (!input) return [];
  const sessionId =
    input.sessionId ??
    input.session_id ??
    input.session?.id ??
    input.session?.sessionId ??
    input.conversationId ??
    input.conversation_id;
  posts.push(
    titlePost(port, terminalId, sessionId, "github-copilot", {
      // The resume id was already captured at session-start, so the stop post is
      // title resolution only — /session-title skips setAgentSession on it.
      ...(invocation.event === "agent-stop" ? { titleOnly: true } : {}),
    }),
  );

  return compact(posts);
}
