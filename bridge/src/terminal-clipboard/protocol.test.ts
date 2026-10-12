import { describe, expect, test } from "bun:test";
import { CLIPBOARD_INBOUND_TYPES, TerminalClipboardMessageSchema } from "./protocol";
import { BODY_REDACTED_MESSAGE_TYPES, CHECKOUT_VARIABLE_MESSAGE_TYPES, PREVIEW_CHANNEL_MESSAGE_TYPES, parseMessage, parseMessageFast } from "../protocol";

const id = "2a8c4135-1614-41e5-b26f-80f70a347f6d";
const context = { id, timestamp: 1, checkoutId: "main", terminalId: "shell", runId: id, attachmentId: id };
const grant = { claimId: id, epoch: 1, lifetimeMs: 5000 };
const examples = [
  { type: "terminal:clipboard:claim", requestId: id },
  { type: "terminal:clipboard:claimed", requestId: id, grant },
  { type: "terminal:clipboard:release", claimId: id, epoch: 1 },
  { type: "terminal:clipboard:revoked", claimId: id, epoch: 1, reason: "stale" },
  { type: "terminal:clipboard:write", claimId: id, epoch: 1, eventId: id, text: "YQ==" },
  { type: "terminal:clipboard:result", claimId: id, epoch: 1, eventId: id, outcome: "copied" },
  { type: "terminal:clipboard:read-host", requestId: id },
  { type: "terminal:clipboard:host-text", requestId: id, text: "YQ==" },
] as const;
describe("clipboard wire validation", () => {
  test("every record uses full validation on both parsing paths and the project control stream", () => {
    for (const example of examples) {
      const record = { ...context, ...example };
      for (const parse of [parseMessage, parseMessageFast]) {
        expect(parse(JSON.stringify(record))).toEqual(record);
        expect(parse(JSON.stringify({ ...record, attachmentId: "forged" }))).toBeNull();
        expect(parse(JSON.stringify({ ...record, checkoutId: "" }))).toBeNull();
      }
      expect(CHECKOUT_VARIABLE_MESSAGE_TYPES.has(example.type)).toBe(true);
      expect(PREVIEW_CHANNEL_MESSAGE_TYPES.has(example.type)).toBe(false);
      expect(BODY_REDACTED_MESSAGE_TYPES.has(example.type)).toBe(true);
    }
    expect([...CLIPBOARD_INBOUND_TYPES]).toEqual(["terminal:clipboard:claim", "terminal:clipboard:release", "terminal:clipboard:result", "terminal:clipboard:read-host"]);
  });
  test("host and claim results require one unambiguous outcome", () => {
    const claim = { ...context, type: "terminal:clipboard:claimed", requestId: id };
    const host = { ...context, type: "terminal:clipboard:host-text", requestId: id };
    for (const record of [claim, host, { ...claim, grant, reason: "conflict" }, { ...host, text: "YQ==", error: "failed" }]) {
      expect(TerminalClipboardMessageSchema.safeParse(record).success).toBe(false);
    }
    expect(TerminalClipboardMessageSchema.safeParse({ ...claim, reason: "conflict" }).success).toBe(true);
    expect(TerminalClipboardMessageSchema.safeParse({ ...host, error: "empty" }).success).toBe(true);
  });
  test("malformed text and oversized wire data are rejected by the fast path", () => {
    const record = { ...context, ...examples[4] };
    for (const text of ["", "YQ", "YR==", "AA==", "/w==", Buffer.alloc(100001, 65).toString("base64")]) {
      expect(parseMessageFast(JSON.stringify({ ...record, text }))).toBeNull();
    }
    for (const parse of [parseMessage, parseMessageFast]) {
      expect(parse(JSON.stringify({ ...record, ignored: "x".repeat(140 * 1024) }))).toBeNull();
    }
  });
});
