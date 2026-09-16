import type { RelayClient } from "../../helpers/relay-client";
import { AbMessageSchema, createMessage, type TerminalFrame } from "../../../bridge/src/protocol";
import { TERMINAL_PROTOCOL_VERSION } from "../../../bridge/src/terminal-frames/protocol";

export async function frameContaining(app: RelayClient, streamId: string, terminalId: string,
  marker: string, timeoutMs = 10_000): Promise<TerminalFrame> {
  const requestId = crypto.randomUUID();
  const deadline = performance.now() + timeoutMs;
  const remaining = () => Math.max(1, deadline - performance.now());
  app.sendOnStream(streamId, createMessage("terminal:subscribe", {
    terminalId, version: TERMINAL_PROTOCOL_VERSION, requestId,
  }));
  const attachment = AbMessageSchema.parse(await app.waitFor((message) =>
    message.type === "terminal:subscribed" && message._streamId === streamId && message.requestId === requestId,
  remaining()));
  if (attachment.type !== "terminal:subscribed" || attachment.terminalId !== terminalId) {
    throw new Error("Terminal subscription identity mismatch");
  }
  try {
    while (performance.now() < deadline) {
      const frame = AbMessageSchema.parse(await app.waitFor((message) =>
        message.type === "terminal:frame" && message._streamId === streamId && message.terminalId === terminalId &&
        message.runId === attachment.runId && message.attachmentId === attachment.attachmentId,
      remaining()));
      if (frame.type !== "terminal:frame") throw new Error("Expected terminal frame");
      app.sendOnStream(streamId, createMessage("terminal:ack", {
        terminalId, runId: frame.runId, attachmentId: frame.attachmentId, sequence: frame.sequence,
      }));
      if (frame.ansi.includes(marker)) return frame;
    }
    throw new Error(`Terminal ${terminalId} did not render the expected output`);
  } finally {
    app.sendOnStream(streamId, createMessage("terminal:unsubscribe", {
      terminalId, runId: attachment.runId, attachmentId: attachment.attachmentId,
    }));
  }
}
