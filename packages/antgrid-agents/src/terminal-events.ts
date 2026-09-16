import { z } from "zod";

export const TerminalAgentEventSchema = z.discriminatedUnion("type", [
  z.object({ type: z.literal("session-identity"), nativeId: z.string().min(1), transcriptPath: z.string().optional() }),
  z.object({ type: z.literal("title"), title: z.string(), kind: z.enum(["manual", "first-message"]) }),
  z.object({ type: z.literal("notification"), notificationType: z.enum(["task_complete", "permission_request", "awaiting_input", "idle", "error"]), message: z.string() }),
  z.object({ type: z.literal("turn-start") }),
  z.object({ type: z.literal("ready") }),
  z.object({ type: z.literal("handler"), event: z.enum(["turn_end", "awaiting_input", "limit_hit", "limit_cleared", "turn_failed"]), resetsAt: z.number().optional(), errorClass: z.string().optional() }),
]);
export type TerminalAgentEvent = z.infer<typeof TerminalAgentEventSchema>;
