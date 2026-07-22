import { createMessage, type AbMessage } from "../protocol";
import { mapAssistantContent, mapToolKind, mapUsage } from "./claude-mapping";

// Claude Code stamps each transcript entry with an ISO-8601 `timestamp`. Carry
// it onto the emitted frame's envelope (overriding createMessage's Date.now())
// so a resumed message shows its ORIGINAL time, not the replay moment — same
// contract codex-resume-replay honors. Live/in-memory entries that carry a
// timestamp (see the driver's pushHistory) get it too; anything without one
// degrades to current behavior.
function parseTs(v: unknown): number | undefined {
  if (typeof v !== "string") return undefined;
  const ms = Date.parse(v);
  return Number.isFinite(ms) ? ms : undefined;
}

function stamped(m: AbMessage, at: number | undefined): AbMessage {
  if (at !== undefined) m.timestamp = at;
  return m;
}

interface ReplayTurn {
  turnId: string;
  items: AbMessage[];
  firstTs?: number;
  lastTs?: number;
}

// Is this entry a user prompt, and what does it render as? Claude writes a
// prompt either as a plain string or as content blocks (attachments, images) —
// both start an exchange, so both must be recognized here or the turn boundary
// is missed and the answer folds into the previous turn. A tool_result rides on
// a type:"user" entry too, but it's the agent's own tool output echoed back, not
// a prompt; it folds into its tool item instead. `text` may be empty (an
// image-only prompt): the turn still opens, there's just nothing to render.
function userPrompt(h: any): { text: string } | undefined {
  if (h?.type !== "user") return undefined;
  const c = h?.message?.content;
  if (typeof c === "string") return { text: c };
  if (!Array.isArray(c)) return undefined;
  if (c.some((b: any) => b?.type === "tool_result")) return undefined;
  let text = "";
  for (const b of c) if (b?.type === "text" && typeof b.text === "string") text += b.text;
  return { text };
}

// Replay history as one turn PER USER PROMPT. Claude's transcript carries no
// turn ids of its own (unlike codex, which replays per real turn), so the
// prompt boundary is what we have to synthesize from. Not one turn for the whole
// conversation: the app folds a settled turn down to its prompt plus trailing
// answer (deriveRows), so a single all-history turn hid every assistant message
// and tool call behind one fold row. User-visible history only; tool_result
// content is folded into its tool item. Best-effort — unknown shapes are skipped.
export function claudeResumeReplay(sessionId: string, history: any[]): AbMessage[] {
  const turns: ReplayTurn[] = [];
  let current: ReplayTurn | null = null;
  // A prompt always starts a turn; anything before the first prompt (or after a
  // shape we skipped) lands in a leading turn rather than being dropped.
  const openTurn = (): ReplayTurn => {
    current = { turnId: `resumed:${turns.length}`, items: [] };
    turns.push(current);
    return current;
  };
  const turnFor = (at: number | undefined): ReplayTurn => {
    const t = current ?? openTurn();
    if (at !== undefined) {
      t.firstTs ??= at;
      t.lastTs = at;
    }
    return t;
  };

  // Claude persists one API response as multiple content-block entries that
  // repeat message.id and usage. Emit usage once, under its visible text item.
  const usageEmitted = new Set<string>();
  for (const h of Array.isArray(history) ? history : []) {
    const at = parseTs(h?.timestamp);
    const prompt = userPrompt(h);
    if (prompt) {
      current = null; // close the open turn; this prompt starts the next
      const t = turnFor(at);
      if (prompt.text) {
        const itemId = `umsg:${h.uuid ?? t.items.length}`;
        t.items.push(stamped(createMessage("agent:item-added", { sessionId, turnId: t.turnId, itemId,
          item: { itemId, kind: "message", role: "user", text: prompt.text } }), at));
      }
    } else if (h?.type === "assistant") {
      const { text, toolUses } = mapAssistantContent(h?.message?.content ?? []);
      if (!text && toolUses.length === 0) continue;
      const t = turnFor(at);
      if (text) {
        const itemId = `msg:${h.uuid ?? t.items.length}`;
        t.items.push(stamped(createMessage("agent:item-added", { sessionId, turnId: t.turnId, itemId,
          item: { itemId, kind: "message", role: "assistant", text } }), at));
        const msgKey = h?.message?.id ?? h?.uuid;
        if (h?.message?.usage && msgKey != null && !usageEmitted.has(String(msgKey))) {
          usageEmitted.add(String(msgKey));
          t.items.push(stamped(createMessage("agent:usage", {
            sessionId, turnId: t.turnId, itemId,
            // History does not expose a reconstructible cumulative total.
            total: {},
            last: mapUsage(h.message.usage),
          }), at));
        }
      }
      for (const tu of toolUses) {
        const itemId = `tool:${tu.id}`;
        t.items.push(stamped(createMessage("agent:item-added", { sessionId, turnId: t.turnId, itemId,
          item: { itemId, kind: "tool_call", status: "completed", toolKind: mapToolKind(tu.name), title: tu.name } }), at));
      }
    }
  }

  const out: AbMessage[] = [];
  for (const t of turns) {
    if (t.items.length === 0) continue; // a prompt whose entries were all skipped
    out.push(stamped(createMessage("agent:turn-start", { sessionId, turnId: t.turnId }), t.firstTs));
    out.push(...t.items);
    out.push(stamped(createMessage("agent:turn-end", { sessionId, turnId: t.turnId, stopReason: "end_turn" }), t.lastTs));
  }
  return out;
}
