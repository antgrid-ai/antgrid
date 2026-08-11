import { describe, it, expect } from "bun:test";
import { createMessage, parseMessage } from "../src/protocol";

describe("agent:background-tasks protocol", () => {
  it("round-trips a background-tasks frame through parseMessage", () => {
    const msg = createMessage("agent:background-tasks", {
      sessionId: "s1",
      tasks: [{
        taskId: "task-1", kind: "shell", title: "bun dev",
        status: "running", itemId: "tool:tu1", startedAt: 1735730000000,
      }],
    });
    const parsed = parseMessage(JSON.stringify(msg));
    expect(parsed?.type).toBe("agent:background-tasks");
    if (parsed?.type === "agent:background-tasks") {
      expect(parsed.tasks[0]?.taskId).toBe("task-1");
      expect(parsed.tasks[0]?.title).toBe("bun dev");
      // The only item↔task link on the wire — it badges the row as "bg".
      expect(parsed.tasks[0]?.itemId).toBe("tool:tu1");
    }
  });

  it("round-trips an empty task list (the 'all done' frame)", () => {
    const msg = createMessage("agent:background-tasks", { sessionId: "s1", tasks: [] });
    const parsed = parseMessage(JSON.stringify(msg));
    expect(parsed?.type).toBe("agent:background-tasks");
  });

  it("round-trips agent:task-stop", () => {
    const msg = createMessage("agent:task-stop", { sessionId: "s1", taskId: "task-1" });
    const parsed = parseMessage(JSON.stringify(msg));
    expect(parsed?.type).toBe("agent:task-stop");
    if (parsed?.type === "agent:task-stop") expect(parsed.taskId).toBe("task-1");
  });

});
