// bridge/src/handler/structured-adapter.ts
import type { AbMessage } from "../protocol";
import type { SessionAdapter } from "./session-adapter";
import type { CapCommand } from "../structured/chat-session";
import { DECIDE_MAX_CHARS } from "./context";

// Flatten a driver transcript snapshot into judge-readable plain text.
// Snapshots arrive as agent:item-added/updated frames (claude nests them inside
// one agent:transcript-replay). Keyed by itemId so an item-updated (e.g. a tool
// call completing) replaces its item-added line instead of duplicating it.
// The default cap must stay at or above the LARGEST per-purpose budget in
// context.ts, and tracks it — assembleContext trims to the caller's budget after
// this returns, so a ceiling below it silently subtracts history no caller can ask
// back. `decide` is currently the only tier; a larger one has to move this too.
export function renderSnapshotText(frames: AbMessage[], maxChars = DECIDE_MAX_CHARS): string {
  const byItem = new Map<string, string>();
  const walk = (frame: Record<string, unknown>) => {
    if (frame.type === "agent:transcript-replay") {
      for (const f of (frame.frames as Array<Record<string, unknown>> | undefined) ?? []) walk(f);
      return;
    }
    if (frame.type !== "agent:item-added" && frame.type !== "agent:item-updated") return;
    const itemId = typeof frame.itemId === "string" ? frame.itemId : undefined;
    const item = frame.item as Record<string, unknown> | undefined;
    if (!itemId || !item) return;
    if ((item.kind === "message" || item.kind === "reasoning") && typeof item.text === "string" && item.text) {
      byItem.set(itemId, `${typeof item.role === "string" ? item.role : "assistant"}: ${item.text}`);
    } else if (item.kind === "tool_call" && typeof item.title === "string") {
      byItem.set(itemId, `[tool: ${item.title}]`);
    }
  };
  for (const f of frames) walk(f as unknown as Record<string, unknown>);
  return [...byItem.values()].join("\n").slice(-maxChars);
}

export function createStructuredAdapter(deps: {
  prompt: (sessionId: string, text: string, commandId?: string) => void;
  getTranscriptPath: (sessionId: string) => string | undefined;
  getSnapshot: (sessionId: string) => Promise<AbMessage[]>;
  commandCatalog: (sessionId: string) => CapCommand[] | undefined;
}): SessionAdapter {
  return {
    // Auto-replies ride the same driver prompt path as an app-sent agent:prompt.
    // NEVER resolvePermission/resolveQuestion here: approving a pending tool
    // call is a human-only act — the destructive floor inspects reply text and
    // cannot see structured tool calls (see engine's forced-escalation events).
    //
    // No command => a plain prompt of the WHOLE text, slash and all. Handing a
    // driver a commandId it does not recognize is strictly worse than handing
    // it none: every backend drops the verb and sends the bare args.
    injectReply: (id, text, command) => deps.prompt(id, command ? command.args : text, command?.id),
    recentOutput: async (id) => {
      // Fail closed: a dead driver yields empty context, and the judge's own
      // unavailable/low-confidence path escalates — never throw from the seam.
      try { return renderSnapshotText(await deps.getSnapshot(id)); }
      catch { return ""; }
    },
    outputKind: () => "rendered",
    transcriptPath: (id) => deps.getTranscriptPath(id),
    commandCatalog: (id) => deps.commandCatalog(id),
  };
}
