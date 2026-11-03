import type { OpenCodeEvent, SessionMessageInfo } from "@opencode/client";
import type { OpencodeEvent } from "./chat-backend";

const failure = (error: any) => ({ name: error?.type, data: { ...error, statusCode: error?.status } });
const outputText = (content: any[] | undefined) => (content ?? [])
  .map((item) => item.type === "text" ? item.text : JSON.stringify(item)).join("\n");

export function normalizeMessage(message: SessionMessageInfo) {
  const info = { ...message, role: message.type === "user" ? "user" : "assistant",
    ...(message.type === "assistant" ? { modelID: message.model.id, providerID: message.model.providerID } : {}),
  };
  const parts = message.type === "user"
    ? [{ id: `${message.id}:0`, messageID: message.id, type: "text", text: message.text }]
    : message.type === "assistant" ? message.content.map((content, ordinal) => {
      if (content.type !== "tool") return { ...content, id: `${message.id}:${ordinal}`, messageID: message.id };
      return { ...content, id: `${message.id}:${content.id}`, messageID: message.id, tool: content.name,
        state: { ...content.state,
          ...("metadata" in content.state && content.state.metadata?.title ? { title: content.state.metadata.title } : {}),
          ...("content" in content.state ? { output: outputText(content.state.content) } : {}),
          ...("error" in content.state ? { error: failure(content.state.error) } : {}),
        },
      };
    }) : message.type === "compaction" ? [{ id: message.id, messageID: message.id, type: "compaction" }] : [];
  return { info, parts };
}

// The driver and transcript renderer share one part model. Translate native V2
// events at the transport boundary so live and replayed items have identical IDs.
export class OpencodeV2Events {
  private tools = new Map<string, any>();
  private models = new Map<string, { id: string; providerID: string }>();

  normalize(event: OpenCodeEvent): OpencodeEvent[] {
    const p: any = "data" in event ? event.data : {};
    const emit = (type: string, properties: any): OpencodeEvent[] => [{ type, properties }];
    const messageID = p.assistantMessageID;
    const part = (value: Record<string, unknown>) => emit("message.part.updated", {
      part: { sessionID: p.sessionID, messageID, ...value },
    });
    switch (event.type) {
      case "session.created": return emit("session.created", { info: { ...p, id: p.sessionID } });
      case "session.step.started":
        this.models.set(messageID, p.model);
        return emit("message.updated", { info: { id: messageID, sessionID: p.sessionID, role: "assistant",
          providerID: p.model.providerID, modelID: p.model.id } });
      case "session.step.ended": {
        const model = this.models.get(messageID);
        this.models.delete(messageID);
        return emit("message.updated", { info: { id: messageID, sessionID: p.sessionID, role: "assistant",
          providerID: model?.providerID, modelID: model?.id, tokens: p.tokens } });
      }
      case "session.text.started":
      case "session.text.ended":
      case "session.reasoning.started":
      case "session.reasoning.ended":
        return part({ id: `${messageID}:${p.ordinal}`, type: event.type.includes("reasoning") ? "reasoning" : "text", text: p.text ?? "" });
      case "session.text.delta":
      case "session.reasoning.delta":
        return emit("message.part.delta", { sessionID: p.sessionID, partID: `${messageID}:${p.ordinal}`, field: "text", delta: p.delta });
      case "session.tool.input.started": {
        const tool = { id: `${messageID}:${p.id}`, type: "tool", tool: p.name, state: { status: "pending" } };
        this.tools.set(tool.id, tool);
        return part(tool);
      }
      case "session.tool.called":
      case "session.tool.progress":
      case "session.tool.success":
      case "session.tool.failed": {
        const id = `${messageID}:${p.id}`;
        const tool = this.tools.get(id) ?? { id, type: "tool", tool: p.id, state: {} };
        const terminal = event.type === "session.tool.success" || event.type === "session.tool.failed";
        tool.state = { ...tool.state, ...(p.input ? { input: p.input } : {}),
          status: event.type === "session.tool.failed" ? "error" : terminal ? "completed" : "running",
          ...(p.content ? { output: outputText(p.content) } : {}),
          ...(p.error ? { error: failure(p.error) } : {}),
          ...(p.metadata?.title ? { title: p.metadata.title } : {}),
        };
        if (terminal) this.tools.delete(id); else this.tools.set(id, tool);
        return part(tool);
      }
      case "permission.asked": return emit("permission.asked", { ...p, permission: p.action, patterns: p.resources });
      case "form.created": return emit("form.created", p.form);
      case "form.cancelled":
      case "form.replied": return emit(event.type, p);
      case "session.status":
      case "session.idle": return emit(event.type, p);
      case "session.compaction.started": return part({ id: p.inputID ?? event.id.replace(/^evt_/, "msg_"), type: "compaction" });
      case "session.execution.started": return emit("session.status", { sessionID: p.sessionID, status: { type: "busy" } });
      case "session.execution.succeeded": return emit("session.idle", { sessionID: p.sessionID });
      case "session.execution.failed": return emit("session.error", { sessionID: p.sessionID, error: failure(p.error) });
      case "session.execution.interrupted": return emit("session.error", {
        sessionID: p.sessionID, error: { name: "MessageAbortedError", data: { message: "OpenCode execution interrupted" } },
      });
      case "session.retry.scheduled": return emit("session.status", {
        sessionID: p.sessionID, status: { type: "retry", next: p.at, attempt: p.attempt },
      });
      default: return [];
    }
  }
}
