import { describe, it, expect } from "bun:test";
import {
  sendTaskRun,
  taskRunObservations,
  TaskRunReporter,
  type TaskRunCredentials,
  type TaskRunObservation,
} from "../src/task-run";
import { createMessage, type SessionEntry, type WorkStatus } from "../src/protocol";
import { ProjectCore } from "../src/project-core";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { randomUUID } from "node:crypto";

interface Call {
  url: string;
  init?: RequestInit;
}

function recordingFetch(calls: Call[], status: () => number = () => 200): typeof fetch {
  return (async (input: Parameters<typeof fetch>[0], init?: Parameters<typeof fetch>[1]) => {
    calls.push({ url: input as string, init: init as RequestInit });
    return new Response(null, { status: status() });
  }) as typeof fetch;
}

function bodyOf(call: Call): Record<string, unknown> {
  return JSON.parse(call.init?.body as string);
}

// observe() is fire-and-forget, so the outcome handling (the 409 block) lands a
// microtask later than the caller returns.
const settle = () => new Promise((r) => setTimeout(r, 0));

const creds: TaskRunCredentials = {
  licenseApiUrl: "https://api.example.com",
  getToken: () => "tok",
  deviceUuid: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
};

function observation(over: Partial<TaskRunObservation> = {}): TaskRunObservation {
  return {
    sessionId: "sess-1",
    taskNumber: 14,
    status: "working",
    checkoutId: "main",
    tool: "claude-code",
    ...over,
  };
}

function entry(over: Partial<SessionEntry> = {}): SessionEntry {
  return {
    id: "sess-1",
    name: "Session 1",
    createdAt: 1,
    lastUsedAt: 2,
    archived: false,
    running: true,
    deleting: false,
    forkSupported: false,
    mode: "terminal",
    approvalPolicy: "default",
    agentSessionResumable: true,
    checkoutId: "main",
    checkoutKind: "main",
    checkoutState: "ready",
    sharedWorkspace: false,
    workspaceMemberCount: 1,
    ...over,
  };
}

describe("taskRunObservations", () => {
  const statuses = (pairs: Record<string, WorkStatus>) => new Map(Object.entries(pairs));

  it("never reports a session with no taskRef", () => {
    const live = taskRunObservations(
      [entry({ id: "a" }), entry({ id: "b", taskRef: { taskId: "t", number: 7 } })],
      statuses({ a: "working", b: "working" }),
      "claude-code",
    );
    expect(live.map((s) => s.sessionId)).toEqual(["b"]);
  });

  it("drops a task-bound session the reduction no longer calls live", () => {
    const live = taskRunObservations(
      [entry({ id: "a", running: false, taskRef: { taskId: "t", number: 7 } })],
      statuses({}),
      "claude-code",
    );
    expect(live).toEqual([]);
  });

  it("falls back to the project's default tool for a session that never overrode it", () => {
    const [only] = taskRunObservations(
      [entry({ taskRef: { taskId: "t", number: 7 } })],
      statuses({ "sess-1": "attention" }),
      "codex",
    );
    expect(only).toEqual({
      sessionId: "sess-1",
      taskNumber: 7,
      status: "attention",
      checkoutId: "main",
      tool: "codex",
    });
  });

  it("carries an isolated session's checkout and branch, and no branch for a main one", () => {
    const [isolated] = taskRunObservations(
      [entry({
        taskRef: { taskId: "t", number: 7 },
        tool: "cursor",
        checkoutId: "ck-1",
        checkoutKind: "managed-worktree",
        checkoutBranch: "antgrid/fix-thing-a1b2c3d4",
      })],
      statuses({ "sess-1": "working" }),
      "claude-code",
    );
    expect(isolated).toEqual({
      sessionId: "sess-1",
      taskNumber: 7,
      status: "working",
      checkoutId: "ck-1",
      tool: "cursor",
      branch: "antgrid/fix-thing-a1b2c3d4",
    });

    const [main] = taskRunObservations(
      [entry({ taskRef: { taskId: "t", number: 7 }, checkoutBranch: null })],
      statuses({ "sess-1": "working" }),
      "claude-code",
    );
    expect(main).not.toHaveProperty("branch");
  });
});

describe("sendTaskRun", () => {
  it("POSTs the task's runs URL with bearer auth and the contract body", async () => {
    const calls: Call[] = [];

    const outcome = await sendTaskRun({
      ...creds,
      number: 14,
      body: {
        localProjectId: "abc123",
        sessionId: "sess-1",
        status: "working",
        checkoutId: "ck-1",
        tool: "claude-code",
        branch: "antgrid/thing-a1b2c3d4",
      },
      fetchFn: recordingFetch(calls),
    });

    expect(outcome).toBe("ok");
    expect(calls).toHaveLength(1);
    expect(calls[0]!.url).toBe("https://api.example.com/tasks/14/runs");
    expect(calls[0]!.init?.method).toBe("POST");
    const headers = calls[0]!.init?.headers as Record<string, string>;
    expect(headers["authorization"]).toBe("Bearer tok");
    expect(headers["content-type"]).toBe("application/json");

    expect(bodyOf(calls[0]!)).toEqual({
      deviceUuid: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
      localProjectId: "abc123",
      sessionId: "sess-1",
      status: "working",
      checkoutId: "ck-1",
      tool: "claude-code",
      branch: "antgrid/thing-a1b2c3d4",
    });
  });

  it("separates the two unretryable refusals from a transient failure", async () => {
    const send = (status: number) =>
      sendTaskRun({
        ...creds,
        number: 14,
        body: { localProjectId: "abc123", sessionId: "sess-1", status: "working" },
        fetchFn: (async (
          _input: Parameters<typeof fetch>[0],
          _init?: Parameters<typeof fetch>[1],
        ) => new Response(null, { status })) as typeof fetch,
      });

    expect(await send(200)).toBe("ok");
    expect(await send(409)).toBe("conflict");
    expect(await send(401)).toBe("denied");
    expect(await send(403)).toBe("denied");
    expect(await send(404)).toBe("failed");
    expect(await send(500)).toBe("failed");
  });

  it("returns failed on a network error rather than throwing", async () => {
    const outcome = await sendTaskRun({
      ...creds,
      number: 14,
      body: { localProjectId: "abc123", sessionId: "sess-1", status: "working" },
      fetchFn: (async (
        _input: Parameters<typeof fetch>[0],
        _init?: Parameters<typeof fetch>[1],
      ): Promise<Response> => {
        throw new Error("network failure");
      }) as typeof fetch,
    });
    expect(outcome).toBe("failed");
  });
});

describe("TaskRunReporter", () => {
  it("reports the first status and does not re-POST unchanged values", async () => {
    const calls: Call[] = [];
    const reporter = new TaskRunReporter({ credentials: () => creds, fetchFn: recordingFetch(calls) });

    reporter.observe("proj-1", [observation()]);
    await settle();
    reporter.observe("proj-1", [observation()]);
    reporter.observe("proj-1", [observation()]);
    await settle();

    expect(calls).toHaveLength(1);
    expect(bodyOf(calls[0]!).status).toBe("working");
  });

  it("re-POSTs when the status moves", async () => {
    const calls: Call[] = [];
    const reporter = new TaskRunReporter({ credentials: () => creds, fetchFn: recordingFetch(calls) });

    reporter.observe("proj-1", [observation()]);
    await settle();
    reporter.observe("proj-1", [observation({ status: "attention" })]);
    await settle();
    reporter.observe("proj-1", [observation({ status: "done" })]);
    await settle();

    expect(calls.map((c) => bodyOf(c).status)).toEqual(["working", "attention", "done"]);
  });

  it("re-POSTs when the branch appears, and never sends resultSummary", async () => {
    const calls: Call[] = [];
    const reporter = new TaskRunReporter({ credentials: () => creds, fetchFn: recordingFetch(calls) });

    reporter.observe("proj-1", [observation({ checkoutId: "ck-1" })]);
    await settle();
    reporter.observe("proj-1", [observation({ checkoutId: "ck-1", branch: "antgrid/x-a1b2c3d4" })]);
    await settle();

    expect(calls).toHaveLength(2);
    expect(bodyOf(calls[1]!).branch).toBe("antgrid/x-a1b2c3d4");
    for (const call of calls) expect(bodyOf(call)).not.toHaveProperty("resultSummary");
  });

  it("sends nothing when the machine has no account credentials", async () => {
    const calls: Call[] = [];
    const reporter = new TaskRunReporter({ credentials: () => null, fetchFn: recordingFetch(calls) });

    reporter.observe("proj-1", [observation()]);
    await settle();

    expect(calls).toHaveLength(0);
  });

  it("ends a run once when the session leaves the live set, and never again", async () => {
    const calls: Call[] = [];
    const reporter = new TaskRunReporter({ credentials: () => creds, fetchFn: recordingFetch(calls) });

    reporter.observe("proj-1", [observation()]);
    await settle();
    reporter.observe("proj-1", []);
    await settle();
    reporter.observe("proj-1", []);
    reporter.observe("proj-1", []);
    await settle();

    expect(calls).toHaveLength(2);
    // The end carries the last reported values, not a fabricated terminal state:
    // WorkStatus.done means "no turn open", never "the work finished".
    expect(bodyOf(calls[1]!)).toMatchObject({
      sessionId: "sess-1",
      status: "working",
      ended: true,
    });
    expect(bodyOf(calls[0]!)).not.toHaveProperty("ended");
  });

  it("ends only the sessions that went away, and only on their own project", async () => {
    const calls: Call[] = [];
    const reporter = new TaskRunReporter({ credentials: () => creds, fetchFn: recordingFetch(calls) });

    reporter.observe("proj-1", [observation(), observation({ sessionId: "sess-2", taskNumber: 15 })]);
    await settle();
    calls.length = 0;

    reporter.observe("proj-2", []);
    await settle();
    expect(calls).toHaveLength(0);

    reporter.observe("proj-1", [observation()]);
    await settle();
    expect(calls).toHaveLength(1);
    expect(bodyOf(calls[0]!)).toMatchObject({ sessionId: "sess-2", ended: true });
    expect(calls[0]!.url).toBe("https://api.example.com/tasks/15/runs");
  });

  it("stops reporting a session the account answered 409 for", async () => {
    const calls: Call[] = [];
    const reporter = new TaskRunReporter({ credentials: () => creds, fetchFn: recordingFetch(calls, () => 409) });

    reporter.observe("proj-1", [observation()]);
    await settle();
    reporter.observe("proj-1", [observation({ status: "attention" })]);
    await settle();
    reporter.observe("proj-1", []);
    await settle();

    expect(calls).toHaveLength(1);
  });

  it("survives a throwing fetch and retries on the next status change", async () => {
    const calls: Call[] = [];
    let fail = true;
    const reporter = new TaskRunReporter({
      credentials: () => creds,
      fetchFn: (async (input: Parameters<typeof fetch>[0], init?: Parameters<typeof fetch>[1]) => {
        calls.push({ url: input as string, init: init as RequestInit });
        if (fail) throw new Error("offline");
        return new Response(null, { status: 200 });
      }) as typeof fetch,
    });

    expect(() => reporter.observe("proj-1", [observation()])).not.toThrow();
    await settle();
    expect(calls).toHaveLength(1);

    fail = false;
    reporter.observe("proj-1", [observation({ status: "attention" })]);
    await settle();
    expect(calls).toHaveLength(2);
    expect(bodyOf(calls[1]!).status).toBe("attention");
  });

  it("costs nothing for a project that has never had a task-bound session", () => {
    let reads = 0;
    const reporter = new TaskRunReporter({
      credentials: () => {
        reads += 1;
        return creds;
      },
      fetchFn: recordingFetch([]),
    });

    reporter.observe("proj-1", []);
    expect(reads).toBe(0);
  });
});

// The bus→reporter wire itself: the pure halves above cannot catch a subscriber
// that stops calling the observer, and this feature has no user-visible symptom
// on the machine that would surface it.
describe("ProjectCore wiring", () => {
  it("hands every session-list move to the run observer under this project's id", async () => {
    const folder = mkdtempSync(join(tmpdir(), "antgrid-taskrun-"));
    writeFileSync(join(folder, "antgrid.yaml"), "name: test\n");
    const seen: Array<{ projectId: string; live: readonly TaskRunObservation[] }> = [];
    const core = new ProjectCore({
      folder,
      mode: "local",
      identity: { deviceId: randomUUID(), deviceName: "local", createdAt: new Date().toISOString() },
      taskRuns: { observe: (projectId, live) => seen.push({ projectId, live }) },
    });
    try {
      await core.start();
      const connect = core.localConnectInfo;
      expect(connect).not.toBeNull();
      const ws = new WebSocket(`ws://127.0.0.1:${connect!.port}`);
      await new Promise<void>((resolve, reject) => {
        ws.onopen = () => resolve();
        ws.onerror = () => reject(new Error("loopback socket failed"));
      });
      ws.send(JSON.stringify({ type: "hello", token: connect!.token, capabilities: { checkoutRouting: true } }));
      ws.send(JSON.stringify(createMessage("session:create", {
        requestId: "r1",
        name: "Task session",
        taskRef: { taskId: "task-abc", number: 14 },
      })));

      const deadline = Date.now() + 5000;
      while (seen.length === 0 && Date.now() < deadline) {
        await new Promise((r) => setTimeout(r, 20));
      }
      ws.close();
      expect(seen.length).toBeGreaterThan(0);
      expect(seen[0]!.projectId).toBe(core.projectId);
      // A created-but-not-started session is not live, so nothing is reported
      // for it — a run must not open before its agent does.
      expect(seen[0]!.live).toEqual([]);
    } finally {
      await core.shutdown();
      // Windows holds the watcher's directory handle briefly past shutdown, so a
      // single rm races it — the folder is a temp dir either way.
      for (let i = 0; i < 20; i++) {
        try { rmSync(folder, { recursive: true, force: true }); break; }
        catch { await new Promise((r) => setTimeout(r, 25)); }
      }
    }
  });
});
