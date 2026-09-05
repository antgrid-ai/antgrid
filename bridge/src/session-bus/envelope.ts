// Spec 6.1's split: a FIXED envelope the bridge can route, cap and render, and
// an OPEN payload it never interprets. The bus needs to know who sent a message,
// which task it belongs to and how big it is; it never needs to know what a
// finding says.

import {
  BusEnvelopeSchema,
  BusPartSchema,
  type BusEnvelope,
  type BusPart,
  type SessionMemberRef,
} from "../protocol";
import { MAX_ENVELOPE_BYTES, MAX_LOGGED_PART_CHARS } from "./constants";

// The two schemas are declared in protocol.ts — they are wire schemas, and the
// message union needs them — and are re-exported here so a bus caller reaches
// the envelope and the helpers that operate on it through one import.
export { BusEnvelopeSchema, BusPartSchema, type BusEnvelope, type BusPart };

/** The agent-authored half of an envelope: everything an agent may name. What is
 *  missing from it is the point — `messageId`, `peer` and `timestamp` are minted
 *  or stamped by the bridge in {@link stampEnvelope}. */
export interface EnvelopeDraft {
  taskId: string | null;
  contextId: string;
  parts: BusPart[];
  summary: string;
  unexpected?: string;
}

/**
 * Build the envelope that goes on the wire, with every bridge-owned field
 * stamped here and every agent-supplied value for one of them DISCARDED rather
 * than merged.
 *
 * Discarding is the whole point: a merge would let an agent that guessed a field
 * name attribute its own message to another session. The draft type simply has
 * no slot for them.
 */
export function stampEnvelope(
  draft: EnvelopeDraft,
  stamp: { messageId: string; peer: SessionMemberRef; now: number },
): BusEnvelope {
  return {
    messageId: stamp.messageId,
    taskId: draft.taskId,
    contextId: draft.contextId,
    parts: draft.parts,
    metadata: {
      peer: stamp.peer,
      summary: draft.summary,
      timestamp: stamp.now,
      ...(draft.unexpected ? { unexpected: draft.unexpected } : {}),
    },
  };
}

/** Serialized size, which is the only size that matters: the cap bounds what
 *  crosses the relay, not what the object costs in memory. */
export function envelopeBytes(envelope: BusEnvelope): number {
  return Buffer.byteLength(JSON.stringify(envelope), "utf8");
}

/** `ENVELOPE_TOO_LARGE` when the serialized envelope exceeds the cap, else null.
 *  The caller refuses with a reason naming the cap and pointing at
 *  publish-artifact — a bigger cap is never the fix, because the cap is what
 *  keeps a result from becoming an unbounded prompt on the other machine. */
export function checkEnvelopeSize(envelope: BusEnvelope): "ENVELOPE_TOO_LARGE" | null {
  return envelopeBytes(envelope) > MAX_ENVELOPE_BYTES ? "ENVELOPE_TOO_LARGE" : null;
}

/** Trim an envelope's parts for the message log, which is a rendering aid: the
 *  full text already lives in the finding or the artifact it arrived with. */
export function trimEnvelopeForLog(envelope: BusEnvelope): BusEnvelope {
  return {
    ...envelope,
    parts: envelope.parts.map((p) =>
      p.kind === "text" && p.text.length > MAX_LOGGED_PART_CHARS
        ? { ...p, text: p.text.slice(0, MAX_LOGGED_PART_CHARS) }
        : p,
    ),
  };
}
