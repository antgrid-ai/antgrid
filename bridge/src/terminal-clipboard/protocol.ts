import { z } from "zod";
import { CLIPBOARD_MAX_BASE64, decodeClipboardText } from "./limits";

const context = z.object({
  id: z.string().uuid(), timestamp: z.number(),
  checkoutId: z.string().min(1).max(256), terminalId: z.string().min(1).max(256),
  runId: z.string().uuid(), attachmentId: z.string().uuid(),
});
const claim = { claimId: z.string().uuid(), epoch: z.number().int().nonnegative() };
const text = z.string().max(CLIPBOARD_MAX_BASE64).refine((value) => decodeClipboardText(value) !== undefined);
const refusal = z.enum(["unavailable", "conflict", "stale", "denied"]);
export const TerminalClipboardClaimMessage = context.extend({
  type: z.literal("terminal:clipboard:claim"), requestId: z.string().uuid(),
});
export const TerminalClipboardClaimedMessage = context.extend({
  type: z.literal("terminal:clipboard:claimed"), requestId: z.string().uuid(),
  grant: z.object({ ...claim, lifetimeMs: z.number().int().min(1).max(5000) }).optional(),
  reason: refusal.optional(),
}).refine((value) => (value.grant === undefined) !== (value.reason === undefined));
export const TerminalClipboardReleaseMessage = context.extend({ type: z.literal("terminal:clipboard:release"), ...claim });
export const TerminalClipboardRevokedMessage = context.extend({
  type: z.literal("terminal:clipboard:revoked"), ...claim, reason: refusal,
});
export const TerminalClipboardWriteMessage = context.extend({
  type: z.literal("terminal:clipboard:write"), ...claim, eventId: z.string().uuid(), text,
});
export const TerminalClipboardResultMessage = context.extend({
  type: z.literal("terminal:clipboard:result"), ...claim, eventId: z.string().uuid(),
  outcome: z.enum(["copied", "denied", "stale", "failed"]),
});
export const TerminalClipboardReadHostMessage = context.extend({
  type: z.literal("terminal:clipboard:read-host"), requestId: z.string().uuid(),
});
export const TerminalClipboardHostTextMessage = context.extend({
  type: z.literal("terminal:clipboard:host-text"), requestId: z.string().uuid(), text: text.optional(),
  error: z.enum(["unsupported", "empty", "too-large", "unavailable", "failed"]).optional(),
}).refine((value) => (value.text === undefined) !== (value.error === undefined));
export const clipboardMessages = [
  TerminalClipboardClaimMessage, TerminalClipboardClaimedMessage, TerminalClipboardReleaseMessage,
  TerminalClipboardRevokedMessage, TerminalClipboardWriteMessage, TerminalClipboardResultMessage,
  TerminalClipboardReadHostMessage, TerminalClipboardHostTextMessage,
] as const;
export const TerminalClipboardMessageSchema = z.discriminatedUnion("type", clipboardMessages);
export type TerminalClipboardMessage = z.infer<typeof TerminalClipboardMessageSchema>;
export type ClipboardContext = Pick<TerminalClipboardMessage, "checkoutId" | "terminalId" | "runId" | "attachmentId">;
export const CLIPBOARD_MESSAGE_TYPES = clipboardMessages.map((schema) => schema.shape.type.value);
export const CLIPBOARD_INBOUND_TYPES = new Set<string>([
  "terminal:clipboard:claim", "terminal:clipboard:release", "terminal:clipboard:result", "terminal:clipboard:read-host",
]);
