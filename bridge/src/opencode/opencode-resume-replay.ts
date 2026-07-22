import { createMessage, type AbMessage } from "../protocol";
import { mapPart, mapTokens } from "./opencode-mapping";

// opencode carries a per-message time (info.time.created, epoch ms — both user
// and assistant); parts inherit their message's time. We stamp each item's
// AbMessage envelope with it so per-message timestamps read correctly on resume
// instead of the replay moment.
function messageCreatedMs(msg: any): number | undefined {
  const created = msg?.info?.time?.created;
  return typeof created === "number" && Number.isFinite(created) ? created : undefined;
}

// createMessage stamps Date.now(); override it with the historical time when
// present, else leave the frame as-is.
function stamped(m: AbMessage, at: number | undefined): AbMessage {
  if (at !== undefined) m.timestamp = at;
  return m;
}

interface ReplayTurn {
  turnId: string;
  items: AbMessage[];
  firstMs?: number;
  lastMs?: number;
}

// opencode persists sessions server-side; on resume we read the message history
// (client.session.messages) and synthesize the same agent:* frames the live
// part stream would have produced — one synthetic turn PER USER MESSAGE, since
// the history carries no turn ids of its own. Not one turn for all history: the
// app folds a settled turn to its prompt plus trailing answer (deriveRows), so
// a single all-history turn hid every assistant message behind one fold row.
export function opencodeResumeReplay(
  sessionId: string,
  messages: any[],
  contextWindowFor?: (providerID: string, modelID: string) => number | undefined,
): AbMessage[] {
  const turns: ReplayTurn[] = [];
  let current: ReplayTurn | null = null;
  // Anything before the first user message (or after one we skipped) lands in a
  // leading turn rather than being dropped.
  const turnFor = (at: number | undefined): ReplayTurn => {
    if (!current) {
      current = { turnId: `resumed:${turns.length}`, items: [] };
      turns.push(current);
    }
    if (at !== undefined) {
      current.firstMs ??= at;
      current.lastMs = at;
    }
    return current;
  };

  for (const msg of Array.isArray(messages) ? messages : []) {
    const role = msg?.info?.role === "user" ? "user" : "assistant";
    const at = messageCreatedMs(msg);
    if (role === "user") current = null; // close the open turn; this prompt starts the next
    const turn = turnFor(at);
    let firstTextItemId: string | undefined;
    for (const part of Array.isArray(msg?.parts) ? msg.parts : []) {
      const item = mapPart({ ...part, messageID: part?.messageID ?? msg?.info?.id }, role);
      if (!item) continue;
      if (firstTextItemId === undefined && item.kind === "message" && part?.type === "text") {
        firstTextItemId = item.itemId;
      }
      turn.items.push(stamped(createMessage("agent:item-added", {
        sessionId, turnId: turn.turnId, itemId: item.itemId, item,
      }), at));
    }
    // Per-message usage footer data. Anchor to the first text part; a
    // tool-only assistant message has nothing user-visible to hang it on.
    const info = msg?.info;
    if (role === "assistant" && info?.tokens && firstTextItemId) {
      const cw = info.providerID && info.modelID ? contextWindowFor?.(info.providerID, info.modelID) : undefined;
      turn.items.push(stamped(createMessage("agent:usage", {
        sessionId, turnId: turn.turnId, itemId: firstTextItemId,
        total: {},
        last: mapTokens(info.tokens),
        ...(cw !== undefined ? { contextWindow: cw } : {}),
      }), at));
    }
  }

  const out: AbMessage[] = [];
  for (const turn of turns) {
    if (turn.items.length === 0) continue; // a message whose parts all mapped to nothing
    out.push(stamped(createMessage("agent:turn-start", { sessionId, turnId: turn.turnId }), turn.firstMs));
    out.push(...turn.items);
    out.push(stamped(createMessage("agent:turn-end", { sessionId, turnId: turn.turnId, stopReason: "end_turn" }), turn.lastMs));
  }
  return out;
}
