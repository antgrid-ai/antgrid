import { z } from "zod";
import * as payloads from "./payloads";
const EventMetadata = { id: z.string().uuid(), timestamp: z.number() };
export const AgentErrorSchema = payloads.AgentErrorSchema;
export const ToolContentSchema = payloads.ToolContentSchema;
export const AgentItemSchema = payloads.AgentItemSchema;
export const AgentUsageSchema = payloads.AgentUsageSchema;
export const AgentTurnStartMessage = payloads.AgentTurnStartMessage.extend(EventMetadata);
export const AgentSessionResetMessage = payloads.AgentSessionResetMessage.extend(EventMetadata);
export const AgentTurnEndMessage = payloads.AgentTurnEndMessage.extend(EventMetadata);
export const AgentTranscriptReplayMessage = payloads.AgentTranscriptReplayMessage.extend(EventMetadata);
export const AgentItemAddedMessage = payloads.AgentItemAddedMessage.extend(EventMetadata);
export const AgentItemDeltaMessage = payloads.AgentItemDeltaMessage.extend(EventMetadata);
export const AgentItemUpdatedMessage = payloads.AgentItemUpdatedMessage.extend(EventMetadata);
export const AgentSnapshotMessage = payloads.AgentSnapshotMessage.extend(EventMetadata);
export const AgentCapabilitiesMessage = payloads.AgentCapabilitiesMessage.extend(EventMetadata);
export const AgentUpdateAvailableMessage = payloads.AgentUpdateAvailableMessage.extend(EventMetadata);
export const AgentUpdateMessage = payloads.AgentUpdateMessage.extend(EventMetadata);
export const AgentUpdateResultMessage = payloads.AgentUpdateResultMessage.extend(EventMetadata);
export const AgentPermissionRequestMessage = payloads.AgentPermissionRequestMessage.extend(EventMetadata);
export const AgentQuestionMessage = payloads.AgentQuestionMessage.extend(EventMetadata);
export const AgentRequestRetractedMessage = payloads.AgentRequestRetractedMessage.extend(EventMetadata);
export const AgentErrorMessage = payloads.AgentErrorMessage.extend(EventMetadata);
export const AgentUsageMessage = payloads.AgentUsageMessage.extend(EventMetadata);
export const AgentBackgroundTaskSchema = payloads.AgentBackgroundTaskSchema;
export const AgentBackgroundTasksMessage = payloads.AgentBackgroundTasksMessage.extend(EventMetadata);
export const AgentTaskStopMessage = payloads.AgentTaskStopMessage.extend(EventMetadata);
export const AgentPromptMessage = payloads.AgentPromptMessage.extend(EventMetadata);
export const AgentCancelMessage = payloads.AgentCancelMessage.extend(EventMetadata);
export const AgentSetConfigMessage = payloads.AgentSetConfigMessage.extend(EventMetadata);
export const AgentSessionActionMessage = payloads.AgentSessionActionMessage.extend(EventMetadata);
export const AgentPermissionResolveMessage = payloads.AgentPermissionResolveMessage.extend(EventMetadata);
export const AgentQuestionResolveMessage = payloads.AgentQuestionResolveMessage.extend(EventMetadata);
export const AgentMessageSchema = z.discriminatedUnion("type", [
  AgentTurnStartMessage,
  AgentSessionResetMessage,
  AgentTurnEndMessage,
  AgentTranscriptReplayMessage,
  AgentItemAddedMessage,
  AgentItemDeltaMessage,
  AgentItemUpdatedMessage,
  AgentSnapshotMessage,
  AgentCapabilitiesMessage,
  AgentUpdateAvailableMessage,
  AgentUpdateMessage,
  AgentUpdateResultMessage,
  AgentPermissionRequestMessage,
  AgentQuestionMessage,
  AgentRequestRetractedMessage,
  AgentErrorMessage,
  AgentUsageMessage,
  AgentBackgroundTasksMessage,
  AgentTaskStopMessage,
  AgentPromptMessage,
  AgentCancelMessage,
  AgentSetConfigMessage,
  AgentSessionActionMessage,
  AgentPermissionResolveMessage,
  AgentQuestionResolveMessage,
]);
export type AgentMessage = z.infer<typeof AgentMessageSchema>;
export type AbMessage = AgentMessage;
export type AgentItem = z.infer<typeof AgentItemSchema>;
export type AgentError = z.infer<typeof AgentErrorSchema>;
export type ToolContent = z.infer<typeof ToolContentSchema>;
export type AgentUsage = z.infer<typeof AgentUsageSchema>;
export type AgentBackgroundTask = z.infer<typeof AgentBackgroundTaskSchema>;

export function createMessage<T extends AgentMessage["type"]>(
  type: T,
  payload: Omit<Extract<AgentMessage, { type: T }>, "type" | "id" | "timestamp">,
): Extract<AgentMessage, { type: T }> {
  return {
    id: crypto.randomUUID(), timestamp: Date.now(), type, ...payload,
  } as Extract<AgentMessage, { type: T }>;
}

export function createTranscriptReplay(sessionId: string, frames: AgentMessage[]): AgentMessage | null {
  if (!frames.length) return null;
  return createMessage("agent:transcript-replay", {
    sessionId, frames: frames as unknown as Record<string, unknown>[],
  });
}
