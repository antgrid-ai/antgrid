// bridge/tests/session-bus-project-reads.test.ts
//
// The app's own reads of its bridge's session bus — directory, inbox, thread —
// and the unread push that moves a badge nobody asked. All four ride the
// PROJECT STREAM, because the object that answers them (`SessionBusApi`) is
// built inside the project core with the machine-level directory injected into
// it: machine-scoped state never implied machine-scoped transport
// (`docs/session-messaging.md` §5.4, "The transport did not move with it").
//
// Every case here is driven through `bus.dispatchInbound` rather than by calling
// the api directly, because the wiring is what fails silently: `handleAbMessage`
// has no exhaustiveness check and a `void` return, so a type that reached
// `KNOWN_TYPES` and never reached the switch is green in `bun test`, green in
// `tsc`, and answers nothing until the app's own 15s timeout fires.
import { afterEach, beforeEach, expect, test } from "bun:test";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { buildAgentCore, type AgentCore } from "../src/agent-core";
import { MessageBus } from "../src/message-bus";
import { createMessage, type AbMessage, type SessionMemberRef } from "../src/protocol";
import { setLogLevel } from "../src/logger";
import { createSessionBusApi, type SessionBusApi } from "../src/session-bus/api";
import { SessionBusCoordinator } from "../src/session-bus/coordinator";
import { SessionDirectory } from "../src/session-bus/directory";
import { SessionBusSessionIndex } from "../src/session-bus/session-index";

setLogLevel("error");

const MACHINE_ID = "m1";
const REPO_KEY = "github.com/antgrid/session-bus-reads";
const REMOTE: SessionMemberRef = { machineId: "m-remote", projectId: "p-remote", sessionId: "s-remote" };
/** A terminal id that names no session, which is what a service PTY — or a
 *  caller guessing — resolves to. */
const NO_SESSION = "terminal-naming-no-session";

// process.env.ANTGRID_DIR is a process-wide override (antgrid-dir.ts) — every
// bridge test file that touches it restores the previous value in afterEach.
let prevAbDir: string | undefined;
let abDir: string;
let cores: AgentCore[] = [];
let coordinator: SessionBusCoordinator | null = null;

beforeEach(() => {
  prevAbDir = process.env.ANTGRID_DIR;
  abDir = mkdtempSync(join(tmpdir(), "antgrid-bus-reads-"));
  process.env.ANTGRID_DIR = abDir;
  cores = [];
  coordinator = null;
});

afterEach(async () => {
  for (const core of cores) {
    try { await core.shutdown(); } catch { /* best effort */ }
  }
  // `AgentCore.shutdown()` never stops an INJECTED coordinator — its lifetime is
  // the host's — so this harness, standing in for HostServer, stops it here.
  coordinator?.stop();
  if (prevAbDir === undefined) delete process.env.ANTGRID_DIR;
  else process.env.ANTGRID_DIR = prevAbDir;
  try { rmSync(abDir, { recursive: true, force: true }); } catch { /* Windows watcher handle */ }
});

async function waitFor(predicate: () => boolean, what: string, timeoutMs = 20_000): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (predicate()) return;
    await new Promise((r) => setTimeout(r, 20));
  }
  throw new Error(`timed out waiting for ${what}`);
}

function tempFolder(): string {
  const folder = mkdtempSync(join(tmpdir(), "antgrid-bus-reads-project-"));
  writeFileSync(join(folder, "antgrid.yaml"), "name: bus-reads\n");
  return folder;
}

interface Fixture {
  bus: MessageBus;
  /** Everything the core published on the control tier — the app's whole view. */
  sent: AbMessage[];
  sessionA: string;
  sessionB: string;
  /** The AGENT's own api over the SAME coordinator the core answers from, so
   *  `inbox()` here is the marking read an MCP tool call makes. Built beside the
   *  core rather than reached through it: the core hands its api to the loopback
   *  route table alone, and only the peek-does-not-mark case needs the other
   *  half. */
  agent: SessionBusApi;
}

/** A non-isolated session: `session:create` alone registers the `SessionEntry`
 *  — no PTY spawn, no git — so it is deliberately never followed by a start. */
async function createSession(bus: MessageBus, sent: AbMessage[], name: string): Promise<string> {
  const requestId = crypto.randomUUID();
  bus.dispatchInbound(createMessage("session:create", { requestId, name }), "control", "loopback");
  await waitFor(
    () => sent.some((m) => m.type === "session:result" && (m as { requestId?: string }).requestId === requestId),
    `${name}'s session:create result`,
  );
  const result = sent.find((m) => m.type === "session:result" && (m as { requestId?: string }).requestId === requestId);
  if (result?.type !== "session:result" || !result.ok || !result.session) {
    throw new Error(`session:create failed for ${name}: ${JSON.stringify(result)}`);
  }
  return result.session.id;
}

async function setUp(): Promise<Fixture> {
  const sessionIndex = new SessionBusSessionIndex({
    liveSessions: (projectId) => cores.find((c) => c.projectId === projectId)?.listSessions(true) ?? null,
  });
  coordinator = new SessionBusCoordinator({
    abDir,
    projectIdFor: (sessionId) => sessionIndex.lookup(sessionId)?.projectId ?? null,
    self: (sessionId) => {
      const entry = sessionIndex.lookup(sessionId);
      if (!entry) return null;
      return {
        key: { machineId: MACHINE_ID, projectId: entry.projectId, sessionId },
        ref: { machineId: MACHINE_ID, projectId: entry.projectId, sessionId, sessionName: entry.sessionName },
      };
    },
    addressable: () => true,
    // Delivery is not what this file is about: every send is accepted so an
    // outbound entry exists to be acked and read back on a thread.
    send: () => true,
  });
  const directory = new SessionDirectory({
    repoKeys: {
      keyFor: () => REPO_KEY,
      probed: () => true,
      projectsSharing: () => cores.map((c) => c.projectId),
    },
    sessionIndex,
    // No path for any project, so the row's branch stays null and this suite
    // costs no git spawn: branch is a ranking hint, never part of an address.
    projectPath: () => undefined,
    machineId: () => MACHINE_ID,
  });

  const core = await buildAgentCore({
    folder: tempFolder(),
    mode: "local",
    identity: { deviceId: "agent-reads", deviceName: "reads", createdAt: new Date().toISOString() },
    machineId: () => MACHINE_ID,
    sessionBus: coordinator,
    sessionDirectory: directory,
  });
  cores.push(core);

  const bus = new MessageBus();
  const sent: AbMessage[] = [];
  bus.subscribe({ deliver: (m) => sent.push(m) });
  core.attachTransport(bus);
  core.onHandshakeComplete();
  await waitFor(() => sent.some((m) => m.type === "agent:status"), "the first agent:status");

  // The label registration `startCore` does on every project open — without it
  // `lookup` never iterates this project at all.
  sessionIndex.noteProject(core.projectId, "Bus Reads", null);
  const sessionA = await createSession(bus, sent, "session-a");
  const sessionB = await createSession(bus, sent, "session-b");

  const agent = createSessionBusApi({
    coordinator,
    abDir,
    projectId: core.projectId,
    machineId: () => MACHINE_ID,
    // The terminal id IS the session id for an agent session, which is exactly
    // the assumption the frame handlers rely on when they hand a `sessionId` to
    // an api that takes a terminal id.
    membership: (terminalId) =>
      terminalId === sessionA || terminalId === sessionB ? { sessionId: terminalId } : null,
    carrierPresent: () => true,
    remoteAccessEnabled: () => true,
  });

  return { bus, sent, sessionA, sessionB, agent };
}

/** Drive one read and hand back the frame that answered it. */
async function ask(
  fx: Fixture,
  request: AbMessage,
  resultType: string,
  requestId: string,
): Promise<Record<string, unknown>> {
  fx.bus.dispatchInbound(request, "control", "loopback");
  await waitFor(
    () => fx.sent.some((m) => m.type === resultType && (m as { requestId?: string }).requestId === requestId),
    `${resultType} for ${requestId}`,
  );
  return fx.sent.find(
    (m) => m.type === resultType && (m as { requestId?: string }).requestId === requestId,
  ) as unknown as Record<string, unknown>;
}

/** One inbound post, as the carrier hands it to this bridge. */
function inboundPost(sessionId: string, messageId: string, text: string): AbMessage {
  return createMessage("session-bus:post", {
    from: REMOTE,
    to: { machineId: MACHINE_ID, projectId: cores[0]!.projectId, sessionId },
    contextId: REMOTE.sessionId,
    threadId: null,
    envelope: {
      messageId,
      threadId: null,
      contextId: REMOTE.sessionId,
      parts: [{ kind: "text", text }],
      metadata: { peer: REMOTE, summary: text, timestamp: Date.now() },
    },
  });
}

test(
  "the directory read answers a member session with the rows it can address",
  async () => {
    const fx = await setUp();
    const requestId = crypto.randomUUID();

    const result = await ask(
      fx,
      createMessage("session-bus:directory", { requestId, sessionId: fx.sessionA }),
      "session-bus:directory:result",
      requestId,
    );

    expect(result.error).toBeUndefined();
    expect(result.machineId).toBe(MACHINE_ID);
    expect(result.truncated).toBe(0);
    // The caller's own row is excluded, so the sibling session is the answer.
    const sessions = result.sessions as { sessionId: string }[];
    expect(sessions.map((r) => r.sessionId)).toEqual([fx.sessionB]);
    expect(result.reach).toBeDefined();
  },
  30_000,
);

test(
  "the inbox read answers a member session with its unread posts",
  async () => {
    const fx = await setUp();
    fx.bus.dispatchInbound(inboundPost(fx.sessionA, "msg-inbox-1", "look at this"), "control", "loopback");
    await waitFor(() => coordinator!.mailbox(fx.sessionA).posts.length === 1, "the post to land in the mailbox");

    const requestId = crypto.randomUUID();
    const result = await ask(
      fx,
      createMessage("session-bus:inbox", { requestId, sessionId: fx.sessionA }),
      "session-bus:inbox:result",
      requestId,
    );

    expect(result.error).toBeUndefined();
    expect(result.unread).toBe(1);
    expect(result.dropped).toBe(0);
    const posts = result.posts as { messageId: string; text: string[] }[];
    expect(posts).toHaveLength(1);
    expect(posts[0]!.messageId).toBe("msg-inbox-1");
    expect(posts[0]!.text).toEqual(["look at this"]);
  },
  30_000,
);

test(
  "the inbox read does not spend the agent's unread flag",
  async () => {
    const fx = await setUp();
    fx.bus.dispatchInbound(inboundPost(fx.sessionA, "msg-peek-1", "the agent must still see this"), "control", "loopback");
    await waitFor(() => coordinator!.mailbox(fx.sessionA).posts.length === 1, "the post to land in the mailbox");

    // The human looks — twice, because a badge is read on every rebuild and one
    // that consumed mail would empty the inbox by being watched.
    for (let i = 0; i < 2; i += 1) {
      const requestId = crypto.randomUUID();
      const result = await ask(
        fx,
        createMessage("session-bus:inbox", { requestId, sessionId: fx.sessionA }),
        "session-bus:inbox:result",
        requestId,
      );
      expect((result.posts as unknown[]).length).toBe(1);
    }

    // ...and the AGENT's own read still finds the post waiting for it. Without
    // the peek/mark split this is where a real message has already vanished,
    // unseen by the one party it was addressed to, with nothing reporting it.
    const agentView = fx.agent.inbox(fx.sessionA);
    expect("posts" in agentView).toBe(true);
    if (!("posts" in agentView)) return;
    expect(agentView.posts.map((p) => p.messageId)).toEqual(["msg-peek-1"]);
    // And the agent's read DID mark, so a second one is empty: the flag belongs
    // to it, and this asserts the human's read never touched it rather than
    // merely that both reads answer.
    const second = fx.agent.inbox(fx.sessionA);
    expect("posts" in second && second.posts).toEqual([]);
  },
  30_000,
);

test(
  "the thread read carries the delivery receipt on an outbound entry",
  async () => {
    const fx = await setUp();
    const sendResult = coordinator!.message({
      sessionId: fx.sessionA,
      verb: "post",
      threadId: null,
      to: REMOTE,
      summary: "opening an exchange",
      parts: [{ kind: "text", text: "opening an exchange" }],
    });
    if (!("ok" in sendResult) || !sendResult.ok) throw new Error(`send refused: ${JSON.stringify(sendResult)}`);

    // The far side's receipt, which is the only honest witness that the message
    // arrived — everything this side of the relay reports only that it left.
    fx.bus.dispatchInbound(
      createMessage("session-bus:ack", {
        from: REMOTE,
        to: { machineId: MACHINE_ID, projectId: cores[0]!.projectId, sessionId: fx.sessionA },
        contextId: fx.sessionA,
        messageId: sendResult.messageId,
        ok: true,
      }),
      "control",
      "loopback",
    );
    await waitFor(
      () => coordinator!.messages(fx.sessionA).entries.some((e) => e.deliveredAt !== undefined),
      "the receipt to be stamped",
    );

    const requestId = crypto.randomUUID();
    const result = await ask(
      fx,
      createMessage("session-bus:thread", { requestId, sessionId: fx.sessionA, threadId: sendResult.threadId }),
      "session-bus:thread:result",
      requestId,
    );

    expect(result.error).toBeUndefined();
    expect(result.threadId).toBe(sendResult.threadId);
    expect(result.contextId).toBe(fx.sessionA);
    const entries = result.entries as { direction: string; deliveredAt?: number }[];
    const outbound = entries.filter((e) => e.direction === "out");
    expect(outbound).toHaveLength(1);
    expect(typeof outbound[0]!.deliveredAt).toBe("number");
  },
  30_000,
);

test(
  "every read refuses a terminal that names no session, with a code",
  async () => {
    const fx = await setUp();
    const directoryId = crypto.randomUUID();
    const inboxId = crypto.randomUUID();
    const threadId = crypto.randomUUID();

    const directory = await ask(
      fx,
      createMessage("session-bus:directory", { requestId: directoryId, sessionId: NO_SESSION }),
      "session-bus:directory:result",
      directoryId,
    );
    const inbox = await ask(
      fx,
      createMessage("session-bus:inbox", { requestId: inboxId, sessionId: NO_SESSION }),
      "session-bus:inbox:result",
      inboxId,
    );
    const thread = await ask(
      fx,
      createMessage("session-bus:thread", { requestId: threadId, sessionId: NO_SESSION, threadId: "thread-1" }),
      "session-bus:thread:result",
      threadId,
    );

    for (const result of [directory, inbox, thread]) {
      expect(result.code).toBe("NOT_MEMBER");
      expect(typeof result.error).toBe("string");
    }
    // A refusal carries no answer fields at all: an empty list beside an error
    // is what renders "this terminal names no session" as "nobody wrote to you".
    expect(directory.sessions).toBeUndefined();
    expect(inbox.posts).toBeUndefined();
    expect(thread.entries).toBeUndefined();
    // ...but the thread the caller asked about is still named, since a surface
    // holding several open threads cannot tell from a requestId alone.
    expect(thread.threadId).toBe("thread-1");
  },
  30_000,
);

test(
  "a burst of posts is one unread push, not one per post",
  async () => {
    const fx = await setUp();
    for (let i = 0; i < 4; i += 1) {
      fx.bus.dispatchInbound(inboundPost(fx.sessionA, `msg-burst-${i}`, `burst ${i}`), "control", "loopback");
    }

    await waitFor(() => fx.sent.some((m) => m.type === "session-bus:unread"), "the unread push");
    // Well past the coalescing window: a per-post implementation has published
    // all four by now, so this fails on count rather than on timing.
    await new Promise((r) => setTimeout(r, 500));

    const pushes = fx.sent.filter((m) => m.type === "session-bus:unread") as unknown as {
      sessionId: string; unread: number; dropped: number;
    }[];
    expect(pushes).toHaveLength(1);
    expect(pushes[0]!.sessionId).toBe(fx.sessionA);
    // The count is read when the window flushes, so the one push says where the
    // mailbox ended up rather than what the first arrival saw.
    expect(pushes[0]!.unread).toBe(4);
    expect(pushes[0]!.dropped).toBe(0);
  },
  30_000,
);
