import { describe, it, expect } from "bun:test";
import { StructuredAgentManager, type StructuredDriver } from "../src/structured/structured-manager";
import { createMessage, type AbMessage } from "../src/protocol";

function makeManager(opts?: { withStopTask?: boolean }) {
  const stopped: string[] = [];
  const driver: StructuredDriver = {
    start: async () => "agent-1",
    prompt: async () => {},
    cancel: async () => false,
    compact: async () => {},
    revert: async () => {},
    setConfig: () => {},
    resolvePermission: () => {},
    resolveQuestion: () => {},
    dispose: () => {},
    ...(opts?.withStopTask === false
      ? {}
      : { stopTask: async (taskId: string) => { stopped.push(taskId); } }),
  };
  const sent: AbMessage[] = [];
  const manager = new StructuredAgentManager({
    driverFactory: () => driver,
    sendMessage: (m) => sent.push(m),
    onAgentSession: () => {},
  });
  return { manager, stopped, sent };
}

describe("agent:task-stop routing", () => {
  it("routes agent:task-stop to the session driver's stopTask", async () => {
    const { manager, stopped } = makeManager();
    await manager.startChat({ sessionId: "s1", tool: "codex" });
    await manager.handleAgentMessage(createMessage("agent:task-stop", { sessionId: "s1", taskId: "task-7" }));
    expect(stopped).toEqual(["task-7"]);
  });

  it("is a silent no-op for an unknown session (no agent:error)", async () => {
    const { manager, sent } = makeManager();
    await manager.handleAgentMessage(createMessage("agent:task-stop", { sessionId: "nope", taskId: "task-7" }));
    expect(sent.filter((m) => m.type === "agent:error")).toHaveLength(0);
  });

  // stopTask is optional because presence IS the capability (see its doc in
  // structured-manager.ts). A driver that implements nothing must swallow the
  // verb, not answer it with an error the app has no way to act on.
  it("is a silent no-op for a driver that implements no stopTask", async () => {
    const { manager, sent } = makeManager({ withStopTask: false });
    await manager.startChat({ sessionId: "s1", tool: "opencode" });
    await manager.handleAgentMessage(createMessage("agent:task-stop", { sessionId: "s1", taskId: "task-7" }));
    expect(sent.filter((m) => m.type === "agent:error")).toHaveLength(0);
  });
});
