import { describe, it, expect } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { SESSION_FRAME_TYPES } from "antgrid-wire";
import {
  parseMessage, createMessage, AbMessageSchema, parseMessageFast,
  SessionHelloFrame, SessionHelloCapabilities, SessionEstablishedFrame,
} from "../src/protocol";

describe("agent:status shape", () => {
  it("accepts services + ports in place of terminals/proxies/layout", () => {
    const msg = {
      id: "00000000-0000-0000-0000-000000000000",
      timestamp: Date.now(),
      type: "agent:status",
      projectId: "demo",
      agent: { tool: "claude-code", version: "2.1.0" },
      terminals: [],
      services: [
        { id: "svc-1", name: "dev", running: true, command: "npm run dev" },
      ],
      commands: [{ name: "Test", confirm: false }],
      ports: [
        { port: 3000, url: "http://localhost:3000/", onDetect: "notify", source: "process" },
      ],
    };
    const parsed = parseMessage(JSON.stringify(msg));
    expect(parsed?.type).toBe("agent:status");
  });
});

describe("agent:hello", () => {
  it("parses a minimal hello", () => {
    const msg = { id: "00000000-0000-0000-0000-000000000000", timestamp: Date.now(), type: "agent:hello", tool: "claude-code", version: "2.1.0", flags: [] };
    const parsed = parseMessage(JSON.stringify(msg));
    expect(parsed?.type).toBe("agent:hello");
  });
});

describe("buildAgentHello", () => {
  it("returns a well-formed agent:hello from config + version", async () => {
    const { buildAgentHello } = await import("../src/index");
    const msg = buildAgentHello({ agent: { tool: "claude-code", flags: ["--x"] } }, "0.1.0");
    expect(msg.type).toBe("agent:hello");
    if (msg.type !== "agent:hello") throw new Error("unreachable");
    expect(msg.tool).toBe("claude-code");
    expect(msg.flags).toEqual(["--x"]);
    expect(msg.version).toBe("0.1.0");
  });
});

describe("port:detected", () => {
  it("parses a port detection event", () => {
    const msg = {
      id: "00000000-0000-0000-0000-000000000000",
      timestamp: Date.now(),
      type: "port:detected",
      port: 3000,
      url: "http://localhost:3000/",
      scheme: "http",
      source: "output",
      sourceSessionId: "term-1",
      attributes: { name: "dev", onDetect: "notify" },
    };
    const parsed = parseMessage(JSON.stringify(msg));
    expect(parsed?.type).toBe("port:detected");
  });
});

describe("config protocol", () => {
  it("round-trips config:write with full payload", () => {
    const msg = createMessage("config:write", {
      config: {
        agent: { tool: "claude-code", flags: ["--yes"] },
        services: [{ name: "dev", command: "npm run dev" }],
        commands: [{ name: "Test", command: "bun test", confirm: false }],
        ports: [{ port: 3000, onDetect: "notify" }],
      },
    });
    const parsed = parseMessage(JSON.stringify(msg));
    expect(parsed?.type).toBe("config:write");
    if (parsed?.type === "config:write") {
      expect(parsed.config.agent?.tool).toBe("claude-code");
      expect(parsed.config.services?.[0].name).toBe("dev");
    }
  });

  it("accepts config:detect-tools as a valid message type", () => {
    const ok = parseMessage(JSON.stringify(createMessage("config:detect-tools", {})));
    expect(ok?.type).toBe("config:detect-tools");
  });
});

describe("session:* messages", () => {
  it("session:list roundtrips", () => {
    const msg = createMessage("session:list", { requestId: "r1", includeArchived: false });
    const json = JSON.stringify(msg);
    const parsed = AbMessageSchema.safeParse(JSON.parse(json));
    expect(parsed.success).toBe(true);
  });

  it("session:list:result roundtrips", () => {
    const msg = createMessage("session:list:result", {
      requestId: "r1",
      sessions: [{
        id: "s1", name: "Session 1",
        createdAt: 1, lastUsedAt: 2, archived: false, running: true, deleting: false, mode: "terminal" as const, approvalPolicy: "default" as const,
        agentSessionResumable: true, forkSupported: false, sharedWorkspace: false, workspaceMemberCount: 1,
        checkoutId: "main", checkoutKind: "main" as const, checkoutState: "ready" as const,
      }],
    });
    const parsed = AbMessageSchema.safeParse(JSON.parse(JSON.stringify(msg)));
    expect(parsed.success).toBe(true);
  });

  it("session:create / start / stop / rename / archive / unarchive / delete / focus roundtrip", () => {
    const types = [
      ["session:create", { requestId: "r", name: "Foo" }],
      ["session:start", { requestId: "r", sessionId: "s" }],
      ["session:stop", { requestId: "r", sessionId: "s" }],
      ["session:rename", { requestId: "r", sessionId: "s", name: "Bar" }],
      ["session:archive", { requestId: "r", sessionId: "s" }],
      ["session:unarchive", { requestId: "r", sessionId: "s" }],
      ["session:delete", { requestId: "r", sessionId: "s" }],
      ["session:set-mode", { requestId: "r", sessionId: "s", mode: "chat" }],
      ["session:focus", { sessionId: "s" }],
    ] as const;
    for (const [type, payload] of types) {
      const msg = createMessage(type as any, payload as any);
      const parsed = AbMessageSchema.safeParse(JSON.parse(JSON.stringify(msg)));
      expect(parsed.success).toBe(true);
    }
  });

  it("session:result and session:updated roundtrip", () => {
    const result = createMessage("session:result", {
      requestId: "r", ok: true,
      session: { id: "s", name: "S", createdAt: 1, lastUsedAt: 2, archived: false, running: false, deleting: false, mode: "terminal" as const, approvalPolicy: "default" as const, agentSessionResumable: true, forkSupported: false, sharedWorkspace: false, workspaceMemberCount: 1, checkoutId: "main", checkoutKind: "main" as const, checkoutState: "ready" as const },
    });
    const updated = createMessage("session:updated", {
      sessions: [{ id: "s", name: "S", createdAt: 1, lastUsedAt: 2, archived: false, running: false, deleting: false, mode: "terminal" as const, approvalPolicy: "default" as const, agentSessionResumable: true, forkSupported: false, sharedWorkspace: false, workspaceMemberCount: 1, checkoutId: "main", checkoutKind: "main" as const, checkoutState: "ready" as const }],
    });
    expect(AbMessageSchema.safeParse(JSON.parse(JSON.stringify(result))).success).toBe(true);
    expect(AbMessageSchema.safeParse(JSON.parse(JSON.stringify(updated))).success).toBe(true);
  });

  it("parseMessageFast recognises new types", () => {
    const msg = createMessage("session:updated", { sessions: [] });
    const parsed = parseMessageFast(JSON.stringify(msg));
    expect(parsed?.type).toBe("session:updated");
  });

  it("session:create round-trips optional tool/command/args", () => {
    const msg = createMessage("session:create", {
      requestId: "r1",
      name: "auth",
      tool: "claude-code",
      args: "--model opus",
    });
    const parsed = parseMessage(JSON.stringify(msg));
    expect(parsed?.type).toBe("session:create");
    if (parsed?.type === "session:create") {
      expect(parsed.tool).toBe("claude-code");
      expect(parsed.args).toBe("--model opus");
      expect(parsed.command).toBeUndefined();
    }
  });

  it("session:create round-trips bypass and defaults old session rows", () => {
    const created = parseMessage(JSON.stringify(createMessage("session:create", {
      requestId: "r1", tool: "codex", approvalPolicy: "bypass",
    })));
    expect(created?.type).toBe("session:create");
    if (created?.type === "session:create") expect(created.approvalPolicy).toBe("bypass");

    const oldRow = {
      id: "s1", name: "old", createdAt: 1, lastUsedAt: 1,
      archived: false, running: false, mode: "terminal",
    };
    const parsed = parseMessage(JSON.stringify({
      ...createMessage("session:list:result", { requestId: "r", sessions: [] }),
      sessions: [oldRow],
    }));
    expect(parsed?.type).toBe("session:list:result");
    if (parsed?.type === "session:list:result") {
      expect(parsed.sessions[0]?.approvalPolicy).toBe("default");
    }
  });

  it("session entry schema accepts an optional command", () => {
    const entry = {
      id: "s1", name: "n", createdAt: 1, lastUsedAt: 1,
      archived: false, running: false, deleting: false, command: "my-agent --serve", mode: "terminal" as const, approvalPolicy: "default" as const,
      agentSessionResumable: true, forkSupported: false, sharedWorkspace: false, workspaceMemberCount: 1,
      checkoutId: "main", checkoutKind: "main" as const, checkoutState: "ready" as const,
    };
    const msg = createMessage("session:list:result", { requestId: "r", sessions: [entry] });
    const parsed = parseMessage(JSON.stringify(msg));
    expect(parsed?.type).toBe("session:list:result");
    if (parsed?.type === "session:list:result") {
      expect(parsed.sessions[0]?.command).toBe("my-agent --serve");
    }
  });

  it("session entry schema accepts optional native agent metadata", () => {
    const entry = {
      id: "s1", name: "n", createdAt: 1, lastUsedAt: 1,
      archived: false, running: false, deleting: false, mode: "terminal" as const, approvalPolicy: "default" as const,
      agentSessionResumable: true, forkSupported: false, sharedWorkspace: false, workspaceMemberCount: 1,
      agentSessionId: "cop-1",
      agentTranscriptPath: "/tmp/copilot-transcript.json",
      checkoutId: "main", checkoutKind: "main" as const, checkoutState: "ready" as const,
    };
    const msg = createMessage("session:list:result", { requestId: "r", sessions: [entry] });
    const parsed = parseMessage(JSON.stringify(msg));
    expect(parsed?.type).toBe("session:list:result");
    if (parsed?.type === "session:list:result") {
      expect(parsed.sessions[0]?.agentSessionId).toBe("cop-1");
      expect(parsed.sessions[0]?.agentTranscriptPath).toBe("/tmp/copilot-transcript.json");
    }
  });

  it("session:set-mode carries the target mode", () => {
    const msg = createMessage("session:set-mode", {
      requestId: "r1", sessionId: "s1", mode: "chat",
    });
    const parsed = parseMessage(JSON.stringify(msg));
    expect(parsed?.type).toBe("session:set-mode");
    if (parsed?.type === "session:set-mode") {
      expect(parsed.sessionId).toBe("s1");
      expect(parsed.mode).toBe("chat");
    }
    expect(parseMessageFast(JSON.stringify(msg))?.type).toBe("session:set-mode");
  });

  it("session:set-mode rejects a mode outside the enum", () => {
    const msg = { ...createMessage("session:set-mode", { requestId: "r", sessionId: "s", mode: "chat" }), mode: "voice" };
    expect(parseMessage(JSON.stringify(msg))).toBeNull();
  });

  // Older bridges omit the field; a peer must read those rows as resumable
  // rather than silently hiding the mode control on every one of them.
  it("agentSessionResumable defaults to true when absent", () => {
    const entry = {
      id: "s1", name: "n", createdAt: 1, lastUsedAt: 1,
      archived: false, running: false, mode: "terminal" as const,
    };
    const raw = {
      id: "b5d1ef96-81da-4862-a058-86b7fad995c7", timestamp: Date.now(),
      type: "session:list:result", requestId: "r", sessions: [entry],
    };
    const parsed = parseMessage(JSON.stringify(raw));
    expect(parsed?.type).toBe("session:list:result");
    if (parsed?.type === "session:list:result") {
      expect(parsed.sessions[0]?.agentSessionResumable).toBe(true);
    }
  });

  // An older bridge omits the field entirely. Reading that as "not deleting" is
  // the only safe direction: the opposite leaves every row from such a bridge
  // showing a pending affordance nothing will ever clear.
  it("deleting defaults to false when absent", () => {
    const entry = {
      id: "s1", name: "n", createdAt: 1, lastUsedAt: 1,
      archived: false, running: false, mode: "terminal" as const,
    };
    const raw = {
      id: "0f4b2a1c-9d3e-4f7a-8b6c-1e2d3f4a5b6c", timestamp: Date.now(),
      type: "session:list:result", requestId: "r", sessions: [entry],
    };
    const parsed = parseMessage(JSON.stringify(raw));
    expect(parsed?.type).toBe("session:list:result");
    if (parsed?.type === "session:list:result") {
      expect(parsed.sessions[0]?.deleting).toBe(false);
    }
  });

  it("deleting survives the roundtrip when the bridge sets it", () => {
    const entry = {
      id: "s1", name: "n", createdAt: 1, lastUsedAt: 1,
      archived: false, running: false, deleting: true, mode: "terminal" as const, approvalPolicy: "default" as const,
      agentSessionResumable: true, forkSupported: false, sharedWorkspace: false, workspaceMemberCount: 1,
      checkoutId: "c1", checkoutKind: "managed-worktree" as const, checkoutState: "ready" as const,
    };
    const msg = createMessage("session:list:result", { requestId: "r", sessions: [entry] });
    const parsed = parseMessage(JSON.stringify(msg));
    if (parsed?.type !== "session:list:result") throw new Error("expected session:list:result");
    expect(parsed.sessions[0]?.deleting).toBe(true);
  });
});

describe("client:focus-state", () => {
  it("parses paused=true", () => {
    const msg = {
      id: "b5d1ef96-81da-4862-a058-86b7fad995c7",
      timestamp: Date.now(),
      type: "client:focus-state",
      paused: true,
    };
    const parsed = parseMessage(JSON.stringify(msg));
    expect(parsed?.type).toBe("client:focus-state");
    if (parsed?.type !== "client:focus-state") throw new Error("unreachable");
    expect(parsed.paused).toBe(true);
  });

  it("rejects missing paused field", () => {
    const msg = {
      id: "853f69c6-9d5c-451e-a2a7-cd1efef0c9aa",
      timestamp: Date.now(),
      type: "client:focus-state",
    };
    expect(parseMessage(JSON.stringify(msg))).toBeNull();
  });
});

describe("terminal:snapshot", () => {
  it("request shape", () => {
    const msg = {
      id: "1306bde2-9272-4ee7-8ed3-c037fc179b46",
      timestamp: Date.now(),
      type: "terminal:snapshot:request",
      terminalId: "t1",
    };
    expect(parseMessage(JSON.stringify(msg))?.type).toBe("terminal:snapshot:request");
  });

  it("reply shape carries seq", () => {
    const msg = {
      id: "0cc738bf-c838-4a2e-8af0-47a6bdb19a88",
      timestamp: Date.now(),
      type: "terminal:snapshot",
      terminalId: "t1",
      scrollback: "hello\nworld\n",
      seq: 42,
    };
    const parsed = parseMessage(JSON.stringify(msg));
    expect(parsed?.type).toBe("terminal:snapshot");
    if (parsed?.type !== "terminal:snapshot") throw new Error("unreachable");
    expect(parsed.seq).toBe(42);
    expect(parsed.scrollback).toBe("hello\nworld\n");
    // An older bridge sends no flag at all, and the client must read that as a
    // mode prelude plus a byte tail it has to erase around itself.
    expect(parsed.composed).toBeUndefined();
  });

  it("carries the composed flag through the parse hop", () => {
    const msg = {
      id: "b0a1f5c9-4b28-4f0e-8b3b-9c4b1c2d3e4f",
      timestamp: Date.now(),
      type: "terminal:snapshot",
      terminalId: "t1",
      scrollback: "\u001b[?1049l\u001b[3J\u001b[2J\u001b[H\u001b[0mscreen",
      seq: 7,
      composed: true,
    };
    const parsed = parseMessage(JSON.stringify(msg));
    if (parsed?.type !== "terminal:snapshot") throw new Error("unreachable");
    expect(parsed.composed).toBe(true);
  });
});

describe("file:tree:snapshot", () => {
  it("request shape (no params)", () => {
    const msg = {
      id: "015d4fbe-076e-4968-81b4-3cd6172805f1",
      timestamp: Date.now(),
      type: "file:tree:snapshot:request",
    };
    expect(parseMessage(JSON.stringify(msg))?.type).toBe("file:tree:snapshot:request");
  });

  it("reply carries tree and seq", () => {
    const msg = {
      id: "263a9c68-db7d-4b17-a919-6c62f1331b50",
      timestamp: Date.now(),
      type: "file:tree:snapshot",
      tree: { name: "root", path: "", type: "directory", children: [] },
      seq: 7,
    };
    const parsed = parseMessage(JSON.stringify(msg));
    expect(parsed?.type).toBe("file:tree:snapshot");
    if (parsed?.type !== "file:tree:snapshot") throw new Error("unreachable");
    expect(parsed.seq).toBe(7);
  });
});

describe("preview:snapshot", () => {
  it("request shape", () => {
    const msg = {
      id: "2f197194-c46f-4751-b536-7f923b41427d",
      timestamp: Date.now(),
      type: "preview:snapshot:request",
    };
    expect(parseMessage(JSON.stringify(msg))?.type).toBe("preview:snapshot:request");
  });

  it("reply carries urls array", () => {
    const msg = {
      id: "3055204f-750a-464a-acbe-606ae3f61c97",
      timestamp: Date.now(),
      type: "preview:snapshot",
      urls: [{ port: 3000, url: "http://relay/preview/3000/", label: "web" }],
    };
    const parsed = parseMessage(JSON.stringify(msg));
    expect(parsed?.type).toBe("preview:snapshot");
    if (parsed?.type !== "preview:snapshot") throw new Error("unreachable");
    expect(parsed.urls).toHaveLength(1);
    expect(parsed.urls[0]?.port).toBe(3000);
  });
});

// Stage B: the native peer session opens on one plaintext `session:hello` /
// `established` pair — no transcript, no confirm tag. These frames carry no
// id/timestamp envelope (see the comment above their definition in
// protocol.ts), so they are validated directly, never through parseMessage.
describe("session:hello / established frame schemas", () => {
  it("session:hello requires a non-empty attemptId", () => {
    expect(SessionHelloFrame.safeParse({ type: "session:hello" }).success).toBe(false);
    expect(SessionHelloFrame.safeParse({ type: "session:hello", attemptId: "" }).success).toBe(false);
    expect(SessionHelloFrame.safeParse({ type: "session:hello", attemptId: "a1" }).success).toBe(true);
  });

  it("accepts optional capabilities", () => {
    const parsed = SessionHelloFrame.safeParse({
      type: "session:hello", attemptId: "a1",
      capabilities: { pullsTree: true, terminalFramesV1: true },
    });
    expect(parsed.success).toBe(true);
  });

  it("a capability is true-only — false is a parse failure, not a signal", () => {
    // The read side treats an unknown/absent capability as false already;
    // accepting `false` here would invite a caller to treat it as a value
    // that round-trips rather than one the schema refuses outright.
    expect(SessionHelloCapabilities.safeParse({ pullsTree: false }).success).toBe(false);
  });

  it("session:established requires the matching attemptId and rejects the old bare name", () => {
    expect(SessionEstablishedFrame.safeParse({ type: "session:established" }).success).toBe(false);
    expect(SessionEstablishedFrame.safeParse({ type: "session:established", attemptId: "a1" }).success).toBe(true);
    expect(SessionEstablishedFrame.safeParse({ type: "established", attemptId: "a1" }).success).toBe(false);
  });

  it("neither frame is a member of AbMessageSchema", () => {
    expect(parseMessage(JSON.stringify({
      id: "a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d", timestamp: Date.now(),
      type: "session:hello", attemptId: "a1",
    }))).toBeNull();
    expect(parseMessage(JSON.stringify({
      id: "b2c3d4e5-f6a7-4b8c-9d0e-1f2a3b4c5d6e", timestamp: Date.now(),
      type: "session:established", attemptId: "a1",
    }))).toBeNull();
  });
});

// D-A9-2: none of the five session-frame names is an AbMessage literal or a
// KNOWN_TYPES entry — proved here rather than by review, since the two lists
// are hand-maintained and can drift silently.
describe("session-frame types are disjoint from the control plane (D-A9-2)", () => {
  it("no AbMessageSchema option's type literal is a SESSION_FRAME_TYPES name, and none parses", () => {
    expect(AbMessageSchema.options.length).toBeGreaterThan(0);
    const controlPlaneTypes = AbMessageSchema.options.map((option) => option.shape.type.value);
    // The loop below would pass vacuously against an empty or wrongly-scoped
    // list, so pin that it actually holds ordinary control-plane types.
    expect(controlPlaneTypes).toContain("ping");
    for (const sessionType of SESSION_FRAME_TYPES) {
      expect(controlPlaneTypes).not.toContain(sessionType);
      expect(parseMessageFast(JSON.stringify({ type: sessionType }))).toBeNull();
    }
  });
});

describe("terminal:output carries optional seq", () => {
  it("accepts seq when present", () => {
    const msg = {
      id: "cab77071-51d9-49f5-8a03-ff17e00e17c8",
      timestamp: Date.now(),
      type: "terminal:output",
      terminalId: "t1",
      data: "hi",
      seq: 5,
    };
    const parsed = parseMessage(JSON.stringify(msg));
    expect(parsed?.type).toBe("terminal:output");
    if (parsed?.type !== "terminal:output") throw new Error("unreachable");
    expect(parsed.seq).toBe(5);
  });

  it("still accepts legacy frames without seq", () => {
    const msg = {
      id: "41ba8520-1312-4e66-8429-565f6024967d",
      timestamp: Date.now(),
      type: "terminal:output",
      terminalId: "t1",
      data: "hi",
    };
    expect(parseMessage(JSON.stringify(msg))?.type).toBe("terminal:output");
  });

  it("defaults legacy checkout-variable frames to main", () => {
    const msg = {
      id: "01d5e166-6d4e-4e0d-a9e9-d4a6d57496b4",
      timestamp: Date.now(),
      type: "file:search",
      projectId: "p1",
      query: "needle",
      caseSensitive: false,
      regex: false,
      wholeWord: false,
      requestId: "r1",
    };
    const parsed = parseMessage(JSON.stringify(msg));
    expect(parsed?.type).toBe("file:search");
    if (parsed?.type !== "file:search") throw new Error("unreachable");
    expect(parsed.checkoutId).toBe("main");
  });
});

describe("handler:status carries the park's attribution beside its policy", () => {
  const frame = (session: Record<string, unknown>) => JSON.stringify({
    id: "6b1e0a2c-3c2f-4c5a-9a5e-2f0f0a3b7c11",
    timestamp: Date.now(),
    type: "handler:status",
    projectId: "p1",
    sessions: [{
      terminalId: "t1",
      state: "parked",
      pendingEscalations: 0,
      armedAt: 1,
      goal: "migrate auth",
      backlog: [],
      escalations: [],
      ...session,
    }],
    snapshots: [],
  });

  it("accepts parkCause", () => {
    // The app is the first reader that PARSES this frame, so a field missing from
    // the schema is a silent strip rather than an error: the attribution would be
    // gone and a judge call of ours timing out would read on the PA bar as the
    // AGENT's provider being down, which is the whole reason cause is separate
    // from kind.
    const parsed = parseMessage(frame({ parkKind: "outage", parkCause: "judge_failure" }));
    expect(parsed?.type).toBe("handler:status");
    if (parsed?.type !== "handler:status") throw new Error("unreachable");
    expect(parsed.sessions[0]!.parkCause).toBe("judge_failure");
  });

  it("still accepts a park with no cause", () => {
    // A park written by an older bridge, or rehydrated off a record predating the
    // field, is honestly unattributed — the app falls back to parkKind's copy.
    const parsed = parseMessage(frame({ parkKind: "limit" }));
    expect(parsed?.type).toBe("handler:status");
    if (parsed?.type !== "handler:status") throw new Error("unreachable");
    expect(parsed.sessions[0]!.parkCause).toBeUndefined();
  });
});

describe("the session object is unchanged and unextended", () => {
  const envelope = { id: "3f2a0f5e-1c3b-4c2b-9f2e-2b7c1d4e5a60", timestamp: 1_700_000_000_000 };
  const address = { machineId: "m1", projectId: "p1", sessionId: "s1" };

  // `docs/session-messaging.md` §4.1: the bus addresses a session by its id and
  // adds nothing to it. Asserted on the wire rather than left to review, because
  // re-growing a field here costs nothing at the schema and is invisible
  // afterwards — a wave that wants one has to delete this test to get it.
  it("carries no membership half on a session entry", () => {
    const msg = {
      ...envelope, type: "session:updated",
      sessions: [{
        id: "s1", name: "Solo", createdAt: 1, lastUsedAt: 1, archived: false, running: false,
        members: [{ ...address, joinedAt: 2 }],
        memberOf: { ...address, joinedAt: 2 },
      }],
    };
    const parsed = parseMessage(JSON.stringify(msg));
    expect(parsed?.type).toBe("session:updated");
    if (parsed?.type !== "session:updated") throw new Error("unreachable");
    expect(parsed.sessions[0]!).not.toHaveProperty("members");
    expect(parsed.sessions[0]!).not.toHaveProperty("memberOf");
  });

  it("takes no membership fields on session:create", () => {
    const msg = {
      ...envelope, type: "session:create", requestId: "r1",
      memberOf: address, brief: "Own the backend.",
    };
    const parsed = parseMessage(JSON.stringify(msg));
    expect(parsed?.type).toBe("session:create");
    expect(parsed).not.toHaveProperty("memberOf");
    expect(parsed).not.toHaveProperty("brief");
  });
});

// The app's hello literal lives in Dart and is mirrored here by hand. Zod
// strips an undeclared key, so a capability the app sends but this schema
// forgot is silently read as false; nothing else spans both sides.
describe("session:hello capabilities mirror the app's literal", () => {
  const dartSource = (file: string) => readFileSync(
    join(import.meta.dir, "..", "..", "packages", "antgrid_relay_client", "lib", "src", file), "utf8");

  function dartHelloKeys(): string[] {
    const body = dartSource("connection_handshake.dart")
      .match(/const Map<String, bool> kSessionHelloCapabilities = \{([^}]*)\};/)?.[1];
    if (body === undefined) throw new Error("kSessionHelloCapabilities not found in connection_handshake.dart");
    return [...body.matchAll(/'([A-Za-z0-9]+)'\s*:\s*true/g)].map((m) => m[1]!).sort();
  }

  it("names exactly the keys SessionHelloCapabilities declares", () => {
    expect(dartHelloKeys()).toEqual(Object.keys(SessionHelloCapabilities.shape).sort());
  });

  it("keeps the loopback-only sessionBusCarrier out of the native hello on both sides", () => {
    expect(dartHelloKeys()).not.toContain("sessionBusCarrier");
    expect(Object.keys(SessionHelloCapabilities.shape)).not.toContain("sessionBusCarrier");
  });

  it("is the loopback transport's default capability set too", () => {
    expect(dartSource("local_transport.dart")).toMatch(/this\.capabilities = kSessionHelloCapabilities,/);
  });
});
