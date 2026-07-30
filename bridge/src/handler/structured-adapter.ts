// bridge/src/handler/structured-adapter.ts
import type { AbMessage } from "../protocol";
import type { SessionAdapter } from "./session-adapter";
import { PLAN_MAX_CHARS } from "./context";

// Flatten a driver transcript snapshot into judge-readable plain text.
// Snapshots arrive as agent:item-added/updated frames (claude nests them inside
// one agent:transcript-replay). Keyed by itemId so an item-updated (e.g. a tool
// call completing) replaces its item-added line instead of duplicating it.
// The default cap is the LARGEST context budget any caller uses (plan), not the
// decide budget: assembleContext trims to the per-purpose budget afterwards, so a
// tighter ceiling here can only subtract from it — capping at the decide budget
// meant a `plan` call on a chat slot could never see more than decide-sized history.
export function renderSnapshotText(frames: AbMessage[], maxChars = PLAN_MAX_CHARS): string {
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
  prompt: (sessionId: string, text: string) => void;
  getTranscriptPath: (sessionId: string) => string | undefined;
  getSnapshot: (sessionId: string) => Promise<AbMessage[]>;
}): SessionAdapter {
  return {
    // Auto-replies ride the same driver prompt path as an app-sent agent:prompt.
    // NEVER resolvePermission/resolveQuestion here: approving a pending tool
    // call is a human-only act — the destructive floor inspects reply text and
    // cannot see structured tool calls (see engine's forced-escalation events).
    injectReply: (id, text) => deps.prompt(id, text),
    recentOutput: async (id) => {
      // Fail closed: a dead driver yields empty context, and the judge's own
      // unavailable/low-confidence path escalates — never throw from the seam.
      try { return renderSnapshotText(await deps.getSnapshot(id)); }
      catch { return ""; }
    },
    outputKind: () => "rendered",
    transcriptPath: (id) => deps.getTranscriptPath(id),
    supportsSlashCommands: () => false,
  };
}
