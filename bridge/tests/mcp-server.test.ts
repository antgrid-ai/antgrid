import { afterEach, describe, expect, test } from "bun:test";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  SCHEDULER_TOOLS,
  SERVER_INSTRUCTIONS,
  SESSION_BUS_TOOLS,
  callSchedulerTool,
  callSessionBusTool,
  formatInZone,
  getApiUrl,
  getRunId,
  getTerminalId,
  isSchedulerTool,
  isSessionBusTool,
  scheduleBody,
} from "../src/mcp/server";
import { ReplyBodySchema, SendBodySchema } from "../src/session-bus/api";

const saved = {
  port: process.env.ANTGRID_API_PORT,
  dir: process.env.ANTGRID_DIR,
  terminal: process.env.ANTGRID_TERMINAL_ID,
  run: process.env.ANTGRID_RUN_ID,
};

function restore(
  key: "ANTGRID_API_PORT" | "ANTGRID_DIR" | "ANTGRID_TERMINAL_ID" | "ANTGRID_RUN_ID",
  value: string | undefined,
) {
  if (value === undefined) delete process.env[key];
  else process.env[key] = value;
}

const servers: { stop(closeActiveConnections?: boolean): void }[] = [];

afterEach(() => {
  for (const s of servers.splice(0)) s.stop(true);
  restore("ANTGRID_API_PORT", saved.port);
  restore("ANTGRID_DIR", saved.dir);
  restore("ANTGRID_TERMINAL_ID", saved.terminal);
  restore("ANTGRID_RUN_ID", saved.run);
});

describe("getApiUrl", () => {
  test("names the loopback core from the port the spawn stamped", () => {
    process.env.ANTGRID_API_PORT = "51423";
    expect(getApiUrl()).toBe("http://127.0.0.1:51423");
  });

  test("reports no core when the port is unset", () => {
    delete process.env.ANTGRID_API_PORT;
    expect(getApiUrl()).toBeNull();
  });

  // An injected entry declares the port as `${ANTGRID_API_PORT}`; an agent that
  // never expands it delivers that literal, which must read as absent rather
  // than as a host.
  test("reports no core for an unexpanded variable reference", () => {
    process.env.ANTGRID_API_PORT = "${ANTGRID_API_PORT}";
    expect(getApiUrl()).toBeNull();
  });

  // The regression this file exists for: the loopback API is unauthenticated
  // and antgrid_run_command executes antgrid.yaml commands, so a port-file
  // fallback would hand command execution against the most-recently-started
  // core to any local process able to spawn this subcommand.
  test("never falls back to the api.port file", () => {
    const dir = mkdtempSync(join(tmpdir(), "antgrid-mcp-port-"));
    try {
      writeFileSync(join(dir, "api.port"), "51423\n", "utf8");
      process.env.ANTGRID_DIR = dir;
      delete process.env.ANTGRID_API_PORT;
      expect(getApiUrl()).toBeNull();
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});

// The caller's session, and therefore its CHECKOUT: an isolated session shares
// its core's loopback API with main, so a tool call that names no terminal is
// answered out of main's tree.
describe("getTerminalId", () => {
  test("names the slot the spawn stamped", () => {
    process.env.ANTGRID_TERMINAL_ID = "term-7";
    expect(getTerminalId()).toBe("term-7");
  });

  test("names nothing when the slot is unset", () => {
    delete process.env.ANTGRID_TERMINAL_ID;
    expect(getTerminalId()).toBeUndefined();
  });

  test("names nothing for an unexpanded variable reference", () => {
    process.env.ANTGRID_TERMINAL_ID = "${ANTGRID_TERMINAL_ID}";
    expect(getTerminalId()).toBeUndefined();
  });
});

// A bus tool is dispatched by name and answered by the bridge, so what this
// process owes the agent is the bridge's refusal exactly as it was written, with
// the code the agent can act on, and a body carrying only what was actually said.
describe("the session-bus tools", () => {
  function stub(handler: (path: string, body: unknown, url: URL) => Response) {
    const server = Bun.serve({
      port: 0,
      hostname: "127.0.0.1",
      async fetch(req) {
        const url = new URL(req.url);
        const body = req.method === "POST" ? await req.json().catch(() => null) : null;
        return handler(url.pathname, body, url);
      },
    });
    servers.push(server);
    process.env.ANTGRID_API_PORT = String(server.port);
    process.env.ANTGRID_TERMINAL_ID = "term-1";
    return server;
  }

  // The boundary the call dispatch reads: a name this set does not hold is
  // answered locally as unknown, and one it does must reach the bridge.
  test("the bus tools are dispatched by name, and nothing else is", () => {
    expect(isSessionBusTool("antgrid_run_command")).toBe(false);
    expect(isSessionBusTool("antgrid_publish_artifact")).toBe(true);
    expect(isSessionBusTool("antgrid_list_artifacts")).toBe(true);
    expect(isSessionBusTool("antgrid_get_artifact")).toBe(true);
    expect(isSessionBusTool("antgrid_list_sessions")).toBe(true);
    expect(isSessionBusTool("antgrid_whoami")).toBe(true);
    expect(isSessionBusTool("antgrid_post")).toBe(true);
    expect(isSessionBusTool("antgrid_notify")).toBe(true);
    expect(isSessionBusTool("antgrid_reply")).toBe(true);
    expect(isSessionBusTool("antgrid_inbox")).toBe(true);
    expect(isSessionBusTool("antgrid_thread")).toBe(true);
  });

  // The bridge authored the refusal and owns the wording; this process appends
  // the code and changes nothing else, because the code is the part an agent
  // can act on without reading English.
  test("a refusal reaches the caller as the bridge wrote it, with its code", async () => {
    stub(() => Response.json(
      { error: "no artifact with that id here; artifact ids are local to where they were published", code: "UNKNOWN_ARTIFACT" },
      { status: 404 },
    ));
    const result = await callSessionBusTool("antgrid_get_artifact", { artifactId: "a-elsewhere" });
    expect(result.isError).toBe(true);
    expect(result.content[0]!.text).toBe(
      "no artifact with that id here; artifact ids are local to where they were published (UNKNOWN_ARTIFACT)",
    );
  });

  test("a refusal with no code is rendered unchanged", async () => {
    stub(() => Response.json({ error: "Invalid body" }, { status: 400 }));
    const result = await callSessionBusTool("antgrid_publish_artifact", { name: "diff.txt" });
    expect(result.isError).toBe(true);
    expect(result.content[0]!.text).toBe("Invalid body");
  });

  test("a tool call with no core reachable says so instead of failing silently", async () => {
    delete process.env.ANTGRID_API_PORT;
    const result = await callSessionBusTool("antgrid_list_artifacts", {});
    expect(result.isError).toBe(true);
    expect(result.content[0]!.text).toContain("Antgrid agent is not running");
  });

  test("a directory row leads with the address and says whether the peer can answer", async () => {
    stub(() => Response.json({
      sessions: [
        { machineId: "self", projectId: "p1", sessionId: "4f2ac1", title: "Wire identity wave 6", branch: "feat/wire-identity", activity: "running", lastActiveAt: 1, canReply: true },
        { machineId: "peer", machineLabel: "macbook-pro", projectId: "p2", sessionId: "9c11de", title: "Relay flow control", branch: "development", activity: "idle", lastActiveAt: 1, canReply: false },
      ],
      truncated: 0,
      machineId: "self",
      reach: { scope: "network", lastPushAgoMs: 12_000, machines: [{ machineId: "peer", machineLabel: "macbook-pro", status: "answered", rows: 1, droppedRows: 0, truncatedCard: 0, ageMs: 12_000 }], staleMachines: 0, notConnected: 0 },
    }));
    const result = await callSessionBusTool("antgrid_list_sessions", {});
    const text = result.content[0]!.text;
    expect(text).toContain('- [this machine] p1/4f2ac1 "Wire identity wave 6" — feat/wire-identity, running, can reply');
    expect(text).toContain('- [macbook-pro] peer/p2/9c11de "Relay flow control" — development, idle, receive-only');
  });

  // A local directory row prints no machine because it is read where it means
  // "here". This address is asked for in order to be given away, so the same
  // omission would name the READER's machine and address a session nobody meant.
  test("the self address carries its machine, where a row for the same session would not", async () => {
    stub(() => Response.json({
      machineId: "self", projectId: "p1", sessionId: "4f2ac1",
      projectLabel: "antgrid", sessionName: "Wire identity wave 6",
    }));
    const text = (await callSessionBusTool("antgrid_whoami", {})).content[0]!.text;
    expect(text).toContain('You are "Wire identity wave 6" in project "antgrid"');
    expect(text).toContain("self/p1/4f2ac1");
    expect(text).toContain("one without a machine means the machine of whoever reads it");
  });

  // Two thirds of an address is worse than none: copied off this machine it
  // resolves against the reader's own. The answer says so instead of printing
  // it bare.
  test("no relay identity is answered as an address that does not leave the machine", async () => {
    stub(() => Response.json({ machineId: null, projectId: "p1", sessionId: "4f2ac1" }));
    const text = (await callSessionBusTool("antgrid_whoami", {})).content[0]!.text;
    expect(text).toContain("p1/4f2ac1");
    expect(text).toContain("only a session on it can use that address");
  });

  // The address is real and the reach is not, so the machine id still prints:
  // blanking it would say "local mode" about a machine one switch away from
  // reachable, and a same-machine peer addresses it either way.
  test("remote access off says the address does not travel, without withdrawing it", async () => {
    stub(() => Response.json({
      machineId: "self", projectId: "p1", sessionId: "4f2ac1", remoteAccess: false,
    }));
    const text = (await callSessionBusTool("antgrid_whoami", {})).content[0]!.text;
    expect(text).toContain("self/p1/4f2ac1");
    expect(text).toContain("remote access is OFF");
    expect(text).toContain("cannot send to another machine");
    expect(text).not.toContain("the machine of whoever reads it");
  });

  // Strictly `=== false`, so a bridge that predates the field is still read as
  // reachable rather than silently told it is cut off.
  test("an answer with no remote-access field is read as reachable", async () => {
    stub(() => Response.json({ machineId: "self", projectId: "p1", sessionId: "4f2ac1" }));
    const text = (await callSessionBusTool("antgrid_whoami", {})).content[0]!.text;
    expect(text).toContain("one without a machine means the machine of whoever reads it");
    expect(text).not.toContain("remote access is OFF");
  });

  // The seam a live two-session test walked off: the row is the ONLY place a
  // caller is offered an address, and `to` is validated somewhere else, so a
  // field the schema demands and the row omits leaves an initiator guessing —
  // which is a hard block, because a reply resolves through its threadId and
  // never exercises this. Driven off `to.required` rather than spelled, so a
  // new required field that nothing prints fails here.
  test("a directory row prints every field a send's address requires", async () => {
    const row = {
      machineId: "self", projectId: "9f12d0f481b4a8a6", sessionId: "5f069fe3", title: "Bus B",
      branch: "master", activity: "running", lastActiveAt: 1, canReply: true,
    };
    stub(() => Response.json({
      sessions: [row],
      truncated: 0,
      machineId: "self",
      reach: { scope: "machine", lastPushAgoMs: 0, machines: [], staleMachines: 0, notConnected: 0 },
    }));
    const result = await callSessionBusTool("antgrid_list_sessions", {});
    const line = result.content[0]!.text.split("\n").find((l) => l.startsWith("- ["));
    expect(line).toBeDefined();
    const to = SESSION_BUS_TOOLS.find((t) => t.name === "antgrid_post")!.inputSchema.properties.to as any;
    for (const key of to.required as string[]) {
      expect(line).toContain(String(row[key as keyof typeof row]));
    }
  });

  // The one wrong answer a directory can give is "there is nobody else" when the
  // truth is "I could not ask", so the reach line prints even when every machine
  // answered — an agent that only ever saw it on failure would read its absence
  // as completeness.
  test("the reach line prints when the read fully succeeded", async () => {
    stub(() => Response.json({
      sessions: [],
      truncated: 0,
      machineId: "self",
      reach: { scope: "network", lastPushAgoMs: 3_000, machines: [{ machineId: "peer", machineLabel: "thinkpad", status: "answered", rows: 0, droppedRows: 0, truncatedCard: 0, ageMs: 3_000 }], staleMachines: 0, notConnected: 0 },
    }));
    const result = await callSessionBusTool("antgrid_list_sessions", {});
    expect(result.content[0]!.text).toContain("Reach: 1 other machine read 3s ago.");
    expect(result.content[0]!.text).toContain("thinkpad: nothing on this repository as of 3s ago");
  });

  test("a machine that could not be asked is named, never dropped from the report", async () => {
    stub(() => Response.json({
      sessions: [],
      truncated: 0,
      machineId: "self",
      reach: {
        scope: "network",
        lastPushAgoMs: 1_000,
        machines: [
          { machineId: "m1", machineLabel: "thinkpad", status: "refused", rows: 0, droppedRows: 0, truncatedCard: 0, ageMs: 1_000 },
          { machineId: "m2", machineLabel: "old-mini", status: "no-card", rows: 0, droppedRows: 0, truncatedCard: 0, ageMs: 1_000 },
          { machineId: "m3", machineLabel: "studio", status: "reach-refused", rows: 0, droppedRows: 0, truncatedCard: 0, ageMs: 1_000 },
        ],
        staleMachines: 0,
        notConnected: 2,
      },
    }));
    const text = (await callSessionBusTool("antgrid_list_sessions", {})).content[0]!.text;
    expect(text).toContain("thinkpad: remote access is off there");
    expect(text).toContain("old-mini: running a bridge older than this feature");
    // The two refusals name DIFFERENT switches. A machine that got as far as
    // the second one has remote access ON, so sending its user to that setting
    // is sending them somewhere they will find nothing to change.
    expect(text).toContain("studio: reachable by agents is off there");
    expect(text).toContain("2 machines in your account are not connected to this desktop and were not asked");
  });

  test("a machine-scope reach says which of the two reasons it was", async () => {
    stub(() => Response.json({
      sessions: [],
      truncated: 0,
      machineId: null,
      reach: { scope: "machine", why: "no-machine-id" },
    }));
    const text = (await callSessionBusTool("antgrid_list_sessions", {})).content[0]!.text;
    expect(text).toContain("Reach: this machine has no relay identity yet");
    expect(text).not.toContain("desktop app");
  });

  test("a directory refusal reaches the caller with its code, not re-worded", async () => {
    stub(() => Response.json(
      { error: "this project has no git remote, so no other session can name it and it can name none", code: "NOT_ADDRESSABLE" },
      { status: 409 },
    ));
    const result = await callSessionBusTool("antgrid_list_sessions", {});
    expect(result.isError).toBe(true);
    expect(result.content[0]!.text).toBe(
      "this project has no git remote, so no other session can name it and it can name none (NOT_ADDRESSABLE)",
    );
  });

  test("an unset optional argument is not sent, so a .strict() body still parses", async () => {
    let received: unknown = null;
    stub((path, body) => {
      received = body;
      return Response.json({ ok: true, artifact: { artifactId: "a-1", name: "diff.txt", bytes: 10 } });
    });
    await callSessionBusTool("antgrid_publish_artifact", {
      name: "diff.txt",
      summary: "the codec diff",
      content: "0123456789",
    });
    expect(received).toEqual({ name: "diff.txt", summary: "the codec diff", content: "0123456789" });
  });

  test("an argument the tool does not advertise is not forwarded into a .strict() body", async () => {
    let received: any = null;
    stub((path, body) => {
      received = body;
      return Response.json({ ok: true, artifact: { artifactId: "a-1", name: "diff.txt", bytes: 10 } });
    });
    // The route refuses an unknown field with a 400, so anything the tool sends
    // and the body schema does not name breaks the tool for every caller that
    // fills it in — including a field this table used to advertise.
    await callSessionBusTool("antgrid_publish_artifact", {
      name: "diff.txt",
      summary: "the codec diff",
      content: "0123456789",
      taskId: "t-1",
    });
    expect(received.taskId).toBeUndefined();
  });

  // The trap this whole block exists for: a key an MCP schema advertises and the
  // route's Zod body does not name produces a bare {error:"Invalid body"} 400 with
  // NO code, which busError renders exactly as the refusal test above pins as
  // correct behaviour. Nothing else in this suite can see the difference, so the
  // two tables are compared directly.
  describe("the send tools advertise the keys the routes parse", () => {
    // An optional field holds its object schema one level down, and the whole
    // point of this comparison is to reach that shape rather than to pass by
    // reading undefined off the wrapper.
    const unwrap = (schema: unknown): unknown => {
      const opt = schema as { unwrap?: () => unknown };
      return typeof opt.unwrap === "function" ? unwrap(opt.unwrap()) : schema;
    };
    const shapeOf = (schema: unknown) => (unwrap(schema) as { shape: Record<string, any> }).shape;
    const keysOf = (schema: unknown) => Object.keys(shapeOf(schema));
    const requiredOf = (schema: unknown) =>
      keysOf(schema).filter((k) => !shapeOf(schema)[k]!.safeParse(undefined).success);

    const pairs = [
      ["antgrid_post", SendBodySchema],
      ["antgrid_notify", SendBodySchema],
      ["antgrid_reply", ReplyBodySchema],
    ] as const;

    for (const [name, schema] of pairs) {
      test(`${name} names only fields its route parses, and every field the route demands`, () => {
        const tool = SESSION_BUS_TOOLS.find((t) => t.name === name);
        expect(tool).toBeDefined();
        for (const key of Object.keys(tool!.inputSchema.properties)) {
          expect(keysOf(schema)).toContain(key);
        }
        for (const key of requiredOf(schema)) {
          expect(tool!.inputSchema.required).toContain(key);
        }
      });
    }

    // The nested object is the easier half to get wrong, because nothing beside it
    // names the fields it has to match.
    test("the address a send carries is spelled the way the target schema spells it", () => {
      const to = SESSION_BUS_TOOLS.find((t) => t.name === "antgrid_post")!.inputSchema.properties.to as any;
      expect(Object.keys(to.properties)).toEqual(keysOf(shapeOf(SendBodySchema).to));
      expect(to.required).toEqual(requiredOf(shapeOf(SendBodySchema).to));
    });
  });

  // A message that crossed is a thread id and a claim about how far the frame got,
  // and nothing else: an agent not told the id cannot answer, and an agent told
  // "sent" about a held frame has been told the wrong thing.
  describe("the send verbs", () => {
    function sendStub(onBody?: (path: string, body: any, url: URL) => void) {
      stub((path, body, url) => {
        onBody?.(path, body, url);
        return Response.json({ ok: true, messageId: "m", threadId: "th", sent: true, held: false, opensThread: false });
      });
    }

    test("a send reports the thread it opened and that the frame left", async () => {
      stub(() => Response.json({ ok: true, messageId: "m-1", threadId: "th-9", sent: true, held: false, opensThread: true }));
      const result = await callSessionBusTool("antgrid_post", {
        to: { machineId: "peer", projectId: "p2", sessionId: "9c11de" },
        summary: "the codec diff broke",
      });
      expect(result.content[0]!.text).toBe(
        "Opened thread th-9 (message m-1). It left this machine; antgrid_thread shows a receipt once the peer's bridge accepts it. Use antgrid_reply with that thread id to answer.",
      );
    });

    test("a held frame is not reported as having left", async () => {
      stub(() => Response.json({ ok: true, messageId: "m-2", threadId: "th-9", sent: false, held: true, opensThread: false }));
      const result = await callSessionBusTool("antgrid_notify", {
        to: { projectId: "p2", sessionId: "9c11de" },
        summary: "the build is red",
      });
      expect(result.content[0]!.text).toBe(
        "On thread th-9 (message m-2). It is held on this machine and has not left yet; it goes when the link is back. Use antgrid_reply with that thread id to answer.",
      );
    });

    test("each verb reaches its own route", async () => {
      const paths: string[] = [];
      sendStub((path) => paths.push(path));
      const to = { projectId: "p2", sessionId: "9c11de" };
      await callSessionBusTool("antgrid_post", { to, summary: "s", text: "t" });
      await callSessionBusTool("antgrid_notify", { to, summary: "s", text: "t" });
      await callSessionBusTool("antgrid_reply", { threadId: "th-1", summary: "s", text: "t" });
      expect(paths).toEqual(["/session-bus/post", "/session-bus/notify", "/session-bus/reply"]);
    });

    // The address is strict too, so one key inside it that the route does not name
    // refuses the entire send with the codeless 400 above.
    test("the address is rebuilt from the fields the route names, not forwarded whole", async () => {
      let received: any = null;
      sendStub((path, body) => { received = body; });
      await callSessionBusTool("antgrid_post", {
        to: { machineId: "peer", projectId: "p2", sessionId: "9c11de", machineLabel: "macbook-pro" },
        summary: "s",
        text: "t",
        taskId: "t-1",
      });
      expect(received).toEqual({
        to: { machineId: "peer", projectId: "p2", sessionId: "9c11de" },
        summary: "s",
        text: "t",
      });
    });

    // A directory row on a machine with no relay identity carries a null machine,
    // which the route reads as this machine — the same answer an absent one gets,
    // but forwarding it keeps a row copyable verbatim.
    test("a null machine survives, and an absent one is simply not sent", async () => {
      const bodies: any[] = [];
      sendStub((path, body) => { bodies.push(body); });
      await callSessionBusTool("antgrid_post", { to: { machineId: null, projectId: "p1", sessionId: "s1" }, summary: "s", text: "t" });
      await callSessionBusTool("antgrid_post", { to: { projectId: "p1", sessionId: "s1" }, summary: "s", text: "t" });
      expect(bodies[0].to).toEqual({ machineId: null, projectId: "p1", sessionId: "s1" });
      expect(bodies[1].to).toEqual({ projectId: "p1", sessionId: "s1" });
    });

    // A reply carries the thread and no address at all: the bridge holds the peer,
    // and an agent respelling an address it was never given is how a reply
    // misroutes.
    test("a reply names a thread and nothing else", async () => {
      let received: any = null;
      sendStub((path, body) => { received = body; });
      await callSessionBusTool("antgrid_reply", { threadId: "th-1", summary: "answered", text: "the codec" });
      expect(received).toEqual({ threadId: "th-1", summary: "answered", text: "the codec" });
    });

    test("a send refusal reaches the caller with the code the bridge chose", async () => {
      stub(() => Response.json(
        { error: "that session is not running, so it will not reach the turn boundary a notify waits for; antgrid_post lands in its mailbox instead", code: "NOT_RUNNING" },
        { status: 409 },
      ));
      const result = await callSessionBusTool("antgrid_notify", { to: { projectId: "p2", sessionId: "9c11de" }, summary: "s", text: "t" });
      expect(result.isError).toBe(true);
      expect(result.content[0]!.text).toContain("antgrid_post lands in its mailbox instead (NOT_RUNNING)");
    });
  });

  describe("the mailbox and thread reads", () => {
    test("a post is rendered with the address that answers it and the body under it", async () => {
      stub(() => Response.json({
        posts: [{
          messageId: "m-1",
          threadId: "th-1",
          contextId: "c-1",
          at: Date.now(),
          from: { machineId: "peer", projectId: "p2", sessionId: "9c11de" },
          summary: "the codec diff broke",
          text: ["look at frame.ts"],
          unexpected: "your lockfile is stale",
          artifacts: [{ artifactId: "a-1", name: "diff.txt", mediaType: "text/plain", bytes: 120, sha256: "ab", summary: "the diff" }],
        }],
        dropped: 0,
      }));
      const text = (await callSessionBusTool("antgrid_inbox", {})).content[0]!.text;
      expect(text).toContain("Unread posts (1). Reading them here marks them read:");
      expect(text).toContain('- [peer/p2/9c11de] thread th-1 — the codec diff broke');
      expect(text).toContain("  look at frame.ts");
      expect(text).toContain("  Not asked about: your lockfile is stale");
      expect(text).toContain("  - a-1 diff.txt (text/plain, 120 bytes): the diff");
    });

    // A bounded mailbox drops its oldest, and a drop the reader is never told
    // about is a message that, as far as this session can tell, was never sent. It
    // rides the header even when there is nothing left to read.
    test("a dropped post is reported, including when the inbox is otherwise empty", async () => {
      stub(() => Response.json({ posts: [], dropped: 1 }));
      const text = (await callSessionBusTool("antgrid_inbox", {})).content[0]!.text;
      expect(text).toBe(
        "No unread posts; 1 post has been dropped unread from this mailbox since it was created.",
      );
    });

    test("an empty mailbox that lost nothing says exactly that", async () => {
      stub(() => Response.json({ posts: [], dropped: 0 }));
      expect((await callSessionBusTool("antgrid_inbox", {})).content[0]!.text).toBe("No unread posts.");
    });

    // The receipt is the only end-to-end witness in the design: an unacked message
    // is never retried, so the sender's whole knowledge of it is this stamp or its
    // absence.
    test("a thread reads in both directions, with the receipt on what this session sent", async () => {
      const now = Date.now();
      const peer = { machineId: "peer", projectId: "p2", sessionId: "9c11de" };
      let search = "";
      stub((path, body, url) => {
        search = url.search;
        return Response.json({
          threadId: "th-1",
          contextId: "c-1",
          entries: [
            { direction: "out", at: now - 300_000, peer, summary: "asked", text: ["what broke?"], deliveredAt: now - 240_000 },
            { direction: "in", at: now - 180_000, peer, summary: "answered", text: ["the codec"] },
            { direction: "out", at: now - 30_000, peer, summary: "thanks", text: ["ok"] },
          ],
        });
      });
      const text = (await callSessionBusTool("antgrid_thread", { threadId: "th-1" })).content[0]!.text;
      expect(search).toContain("threadId=th-1");
      expect(text).toContain("Thread th-1 (3 messages, oldest first):");
      expect(text).toContain("- -> you, 5m ago [peer bridge accepted it 4m ago] — asked");
      expect(text).toContain("  what broke?");
      expect(text).toContain("- <- peer/p2/9c11de, 3m ago — answered");
      expect(text).toContain("- -> you, 30s ago [no receipt yet] — thanks");
    });

    test("an unknown thread is refused by the bridge, not answered as empty", async () => {
      stub(() => Response.json(
        { error: 'no thread "th-gone" on this session; threads age out with the mailbox', code: "UNKNOWN_PEER" },
        { status: 404 },
      ));
      const result = await callSessionBusTool("antgrid_thread", { threadId: "th-gone" });
      expect(result.isError).toBe(true);
      expect(result.content[0]!.text).toContain("(UNKNOWN_PEER)");
    });

    test("a thread read with no id is refused before a request is made", async () => {
      delete process.env.ANTGRID_API_PORT;
      const result = await callSessionBusTool("antgrid_thread", {});
      expect(result.isError).toBe(true);
      expect(result.content[0]!.text).toBe("Missing required argument: threadId");
    });
  });
});

// The run id is what proves a call comes from this session's own process tree,
// so a value that is not one must read as absent rather than be sent.
describe("getRunId", () => {
  test("names the run the spawn stamped", () => {
    process.env.ANTGRID_RUN_ID = "run-abc";
    expect(getRunId()).toBe("run-abc");
  });

  test("names nothing when unset or empty", () => {
    delete process.env.ANTGRID_RUN_ID;
    expect(getRunId()).toBeUndefined();
    process.env.ANTGRID_RUN_ID = "";
    expect(getRunId()).toBeUndefined();
  });

  test("names nothing for an unexpanded variable reference", () => {
    process.env.ANTGRID_RUN_ID = "${ANTGRID_RUN_ID}";
    expect(getRunId()).toBeUndefined();
  });
});

describe("the server instructions", () => {
  test("fit the budget, with the scheduler paragraph second", () => {
    expect(SERVER_INSTRUCTIONS.length).toBeLessThanOrEqual(1900);
    const paragraphs = SERVER_INSTRUCTIONS.split("\n\n");
    expect(paragraphs[1]).toContain("antgrid_create_schedule");
    expect(paragraphs[1]).toContain("CronCreate");
    expect(paragraphs[1]).toContain("did not ask for");
  });

  test("still carry the bus rules", () => {
    for (const needle of ["antgrid_inbox", "antgrid_post", "antgrid_notify", "antgrid_reply", "not authority", "BRIDGE accepted", "remote access is off"]) {
      expect(SERVER_INSTRUCTIONS).toContain(needle);
    }
  });

  // Each clause here is a rule the budget trim once cut while the tool names
  // above still matched: when to re-check the inbox, that a post asks nothing,
  // and that a refused cross-machine send must not be routed around.
  test("keep every rule the trim to the budget could lose", () => {
    for (const needle of [
      "again before you report or hand off",
      "row titles suffice to judge",
      "never assemble one",
      "not how to get an answer",
      "idle or stopped session may never read it",
      "returns a handle to name in a message",
      "never retry or route around it",
    ]) {
      expect(SERVER_INSTRUCTIONS).toContain(needle);
    }
  });
});

describe("the scheduler tools", () => {
  const NOW = Date.UTC(2026, 9, 8, 12, 0, 0);

  function stub(handler: (path: string, body: any, url: URL) => Response) {
    const requests: { path: string; body: any; search: string }[] = [];
    const server = Bun.serve({
      port: 0,
      hostname: "127.0.0.1",
      async fetch(req) {
        const url = new URL(req.url);
        const body = req.method === "POST" ? await req.json().catch(() => null) : null;
        requests.push({ path: url.pathname, body, search: url.search });
        return handler(url.pathname, body, url);
      },
    });
    servers.push(server);
    process.env.ANTGRID_API_PORT = String(server.port);
    process.env.ANTGRID_TERMINAL_ID = "term-1";
    process.env.ANTGRID_RUN_ID = "run-9";
    return requests;
  }

  const SCHEDULE = {
    id: "sch-1", name: "Nightly review", enabled: true, cron: "0 2 * * *", timezone: "America/New_York",
    nextOccurrence: Date.UTC(2026, 9, 9, 6, 0, 0), agentId: "claude-code", mode: "terminal",
    workspace: "worktree", baseBranch: "main", approvalPolicy: "default", catchUp: "latest",
  };

  test("the scheduler tools are dispatched by name, and nothing else is", () => {
    expect(SCHEDULER_TOOLS.map((t) => t.name)).toEqual([
      "antgrid_list_schedules", "antgrid_schedule_runs", "antgrid_create_schedule",
      "antgrid_update_schedule", "antgrid_delete_schedule", "antgrid_run_schedule_now",
    ]);
    for (const tool of SCHEDULER_TOOLS) expect(isSchedulerTool(tool.name)).toBe(true);
    expect(isSchedulerTool("antgrid_post")).toBe(false);
    expect(isSchedulerTool("antgrid_run_command")).toBe(false);
  });

  test("every call carries the slot in the query and the run id in the body", async () => {
    const requests = stub(() => Response.json({ header: { timezone: "UTC", available: true, agents: [] }, schedules: [] }));
    await callSchedulerTool("antgrid_list_schedules", {}, NOW);
    expect(requests[0]).toEqual({ path: "/scheduler/list", body: { runId: "run-9" }, search: "?terminalId=term-1" });
  });

  test("a body carries only what was said, and keeps an explicit null base branch", () => {
    expect(scheduleBody({ name: "n", prompt: "p", cron: undefined })).toEqual({ name: "n", prompt: "p" });
    expect(scheduleBody({ baseBranch: null })).toEqual({ baseBranch: null });
    expect(scheduleBody({ baseBranch: "main", enabled: false })).toEqual({ baseBranch: "main", enabled: false });
    expect(scheduleBody({ id: "x", unknown: 1 })).toEqual({});
    expect(scheduleBody(undefined)).toEqual({});
  });

  test("update sends the id and only the changed fields; delete and run-now send the id", async () => {
    const requests = stub(() => Response.json({ schedule: SCHEDULE, deleted: "sch-1", run: { id: "run-q", status: "queued" } }));
    await callSchedulerTool("antgrid_update_schedule", { id: "sch-1", enabled: false }, NOW);
    await callSchedulerTool("antgrid_delete_schedule", { id: "sch-1" }, NOW);
    await callSchedulerTool("antgrid_run_schedule_now", { id: "sch-1" }, NOW);
    expect(requests.map((r) => [r.path, r.body])).toEqual([
      ["/scheduler/update", { runId: "run-9", id: "sch-1", enabled: false }],
      ["/scheduler/delete", { runId: "run-9", id: "sch-1" }],
      ["/scheduler/run-now", { runId: "run-9", id: "sch-1" }],
    ]);
  });

  test("a missing id is refused before a request is made", async () => {
    const requests = stub(() => Response.json({}));
    for (const name of ["antgrid_update_schedule", "antgrid_delete_schedule", "antgrid_run_schedule_now"]) {
      const result = await callSchedulerTool(name, {}, NOW);
      expect(result.isError).toBe(true);
      expect(result.content[0]!.text).toBe("Missing required argument: id");
    }
    expect(requests).toHaveLength(0);
  });

  test("a refusal reaches the caller as the bridge wrote it, with its code", async () => {
    stub(() => Response.json({ error: "A session the scheduler launched cannot change schedules.", code: "SCHEDULED_SESSION_READ_ONLY" }, { status: 403 }));
    const result = await callSchedulerTool("antgrid_delete_schedule", { id: "sch-1" }, NOW);
    expect(result.isError).toBe(true);
    expect(result.content[0]!.text).toBe("A session the scheduler launched cannot change schedules. (SCHEDULED_SESSION_READ_ONLY)");
  });

  test("times are shown in the schedule's own zone with the offset in force", () => {
    // 06:00 UTC is 02:00 EDT (UTC-4) on 2026-10-09.
    expect(formatInZone(Date.UTC(2026, 9, 9, 6, 0, 0), "America/New_York", NOW).replace(",", "")).toBe("Fri 9 Oct 02:00 America/New_York (UTC-4), in 18h");
  });

  test("the time of day alone leads when the instant is today in that zone", () => {
    expect(formatInZone(NOW + 3 * 3_600_000, "UTC", NOW)).toBe("15:00 UTC (UTC), in 3h");
  });

  test("the offset follows DST and can be fractional", () => {
    const winter = formatInZone(Date.UTC(2026, 11, 8, 7, 0, 0), "America/New_York", NOW);
    expect(winter).toContain("02:00 America/New_York (UTC-5)");
    expect(formatInZone(Date.UTC(2026, 9, 8, 13, 30, 0), "Asia/Kolkata", NOW)).toContain("(UTC+5:30)");
  });

  test("an unknown zone degrades to UTC rather than throwing", () => {
    expect(formatInZone(NOW + 3_600_000, "Not/AZone", NOW)).toBe("13:00 UTC (UTC), in 1h");
  });

  test("a listing shows the zone, cadence, next run and the machine's own time", async () => {
    stub(() => Response.json({
      header: { timezone: "Europe/London", available: true, agents: [{ agentId: "claude-code", modes: ["terminal", "chat"] }] },
      schedules: [{ ...SCHEDULE, authorSessionName: "Refactor auth", activeRun: { id: "run-1", status: "running", sessionName: "Nightly review" } }],
    }));
    const text = (await callSchedulerTool("antgrid_list_schedules", {}, NOW)).content[0]!.text;
    expect(text).toContain("Machine timezone: Europe/London.");
    expect(text).toContain("The scheduler can run now.");
    expect(text).toContain("claude-code (terminal, chat)");
    expect(text).toContain('- sch-1 "Nightly review" — enabled');
    expect(text).toContain('cron "0 2 * * *" in America/New_York');
    expect(text).toContain("02:00 America/New_York (UTC-4)");
    expect(text).toContain("on this machine (Europe/London)");
    expect(text).toContain('created by session "Refactor auth"');
    expect(text).toContain("active run run-1: running in session Nightly review");
  });

  test("a one-off row says which of its states it is in", async () => {
    const oneOff = (over: Record<string, unknown>) => ({
      name: "Once", enabled: true, runAt: NOW + 3 * 3_600_000, timezone: "UTC", agentId: "claude-code", mode: "terminal",
      workspace: "shared", approvalPolicy: "default", catchUp: "latest", ...over,
    });
    stub(() => Response.json({
      header: { timezone: "UTC", available: true, agents: [] },
      schedules: [
        oneOff({ id: "o-pending" }),
        oneOff({ id: "o-paused", enabled: false }),
        // Paused past its time: Resume would be refused by the 60-second floor,
        // so the row must not read as a plain pause.
        oneOff({ id: "o-passed", enabled: false, runAt: NOW - 3 * 3_600_000 }),
        oneOff({
          id: "o-ran", runAt: NOW - 2 * 3_600_000, firedRunId: "r-ran", firedAt: NOW - 2 * 3_600_000,
          firedRun: { id: "r-ran", trigger: "cron", status: "completed" },
        }),
        oneOff({
          id: "o-missed", catchUp: "skip", runAt: NOW - 5 * 3_600_000, firedRunId: "r-missed", firedAt: NOW - 3_600_000,
          firedRun: { id: "r-missed", trigger: "missed", status: "skipped" },
        }),
        // The fired run was pruned; enabled stays true because finishing never pauses.
        oneOff({ id: "o-gone", runAt: NOW - 3_600_000, firedRunId: "r-pruned", firedAt: NOW - 3_600_000 }),
      ],
    }));
    const text = (await callSchedulerTool("antgrid_list_schedules", {}, NOW)).content[0]!.text;
    const tail = "\n  runs: claude-code/terminal; workspace shared checkout; approval default; catch-up";
    expect(text).toContain(`- o-pending "Once" — pending\n  cadence: once at 15:00 UTC (UTC), in 3h${tail} latest\n  created in the app`);
    expect(text).toContain(`- o-paused "Once" — paused\n  cadence: once at 15:00 UTC (UTC), in 3h${tail} latest`);
    expect(text).toContain(`- o-passed "Once" — paused, time passed\n  cadence: once at 09:00 UTC (UTC), 3h ago${tail} latest`);
    expect(text).toContain(`- o-ran "Once" — finished: turn finished\n  cadence: once at 10:00 UTC (UTC), 2h ago\n  fired: 10:00 UTC (UTC), 2h ago${tail} latest`);
    expect(text).toContain(`- o-missed "Once" — finished: missed\n  cadence: once at 07:00 UTC (UTC), 5h ago\n  fired: 11:00 UTC (UTC), 1h ago${tail} skip`);
    expect(text).toContain(`- o-gone "Once" — finished\n  cadence: once at 11:00 UTC (UTC), 1h ago\n  fired: 11:00 UTC (UTC), 1h ago${tail} latest`);
    // A one-off has no next-occurrence line; its time is on the cadence line.
    expect(text).not.toContain("  next:");
  });

  test("a run waiting for input says later occurrences are skipped until it is answered", async () => {
    stub(() => Response.json({
      header: { timezone: "America/New_York", available: true, agents: [] },
      schedules: [{ ...SCHEDULE, activeRun: { id: "run-7", status: "needs-input", sessionId: "s-7", sessionName: "Nightly review" } }],
    }));
    const text = (await callSchedulerTool("antgrid_list_schedules", {}, NOW)).content[0]!.text;
    expect(text).toContain(
      "\n  active run run-7: waiting for input in session Nightly review; later occurrences are skipped until it is answered",
    );
  });

  test("a created one-off echoes its single time", async () => {
    const runAt = NOW + 3 * 3_600_000;
    stub(() => Response.json({
      schedule: { ...SCHEDULE, cron: undefined, runAt, timezone: "UTC" },
      saved: true,
      echo: { machineTimezone: "UTC", occurrences: [runAt] },
    }));
    const text = (await callSchedulerTool("antgrid_create_schedule", { name: "n", prompt: "p", runAt: "2026-10-08T15:00" }, NOW)).content[0]!.text;
    expect(text).toContain("Runs once at 15:00 UTC (UTC), in 3h.");
    expect(text).not.toContain("Next ");
  });

  test("a listing says when the scheduler cannot run and when there is nothing scheduled", async () => {
    stub(() => Response.json({ header: { timezone: "UTC", available: false, reason: "the desktop app is closed", agents: [] }, schedules: [] }));
    const text = (await callSchedulerTool("antgrid_list_schedules", {}, NOW)).content[0]!.text;
    expect(text).toContain("The scheduler cannot run now: the desktop app is closed.");
    expect(text).toContain("This project has no schedules.");
  });

  test("a run that ended its turn is not reported as a success", async () => {
    stub(() => Response.json({
      runs: [
        { id: "r1", scheduleId: "sch-1", scheduleName: "Nightly", trigger: "cron", status: "completed", occurrenceAt: NOW - 3_600_000, timezone: "UTC", sessionId: "s1" },
        { id: "r2", scheduleId: "sch-1", scheduleName: "Nightly", trigger: "missed", status: "skipped", occurrenceAt: NOW - 7_200_000, timezone: "UTC", missedCount: 2, reason: "app closed" },
        { id: "r3", scheduleId: "sch-1", scheduleName: "Nightly", trigger: "cron", status: "failed", occurrenceAt: NOW - 9_000_000, timezone: "UTC" },
      ],
      more: 4,
    }));
    const text = (await callSchedulerTool("antgrid_schedule_runs", { scheduleId: "sch-1" }, NOW)).content[0]!.text;
    expect(text).toContain("r1 · scheduled · turn finished · Nightly");
    expect(text).toContain("r3 · scheduled · turn failed");
    expect(text).toContain("r2 · missed · skipped");
    expect(text).toContain("2 missed");
    expect(text).not.toMatch(/succe/i);
    expect(text).toContain("4 more not shown.");
  });

  test("a created schedule echoes the next runs and the stored worktree base", async () => {
    stub(() => Response.json({
      schedule: SCHEDULE,
      saved: true,
      echo: {
        machineTimezone: "America/New_York",
        occurrences: [Date.UTC(2026, 9, 9, 6, 0, 0), Date.UTC(2026, 9, 10, 6, 0, 0)],
        perDay: 1,
        resolvedBaseBranch: "main",
      },
    }));
    const text = (await callSchedulerTool("antgrid_create_schedule", { name: "Nightly review", prompt: "review" }, NOW)).content[0]!.text;
    expect(text).toContain("Created schedule sch-1.");
    expect(text).toContain("Next 2 runs:");
    expect(text).toContain("That is about 1 runs a day.");
    expect(text).toContain("Worktree base: main, resolved now and stored");
  });

  test("a dry run says nothing was saved", async () => {
    stub(() => Response.json({ schedule: SCHEDULE, saved: false, echo: {} }));
    const text = (await callSchedulerTool("antgrid_create_schedule", { name: "n", prompt: "p", dryRun: true }, NOW)).content[0]!.text;
    expect(text).toContain("Dry run: nothing was saved.");
  });

  test("run-now reports queued, and a skipped claim as skipped", async () => {
    stub(() => Response.json({ run: { id: "run-q", status: "queued" } }));
    expect((await callSchedulerTool("antgrid_run_schedule_now", { id: "sch-1" }, NOW)).content[0]!.text)
      .toBe("Queued as run run-q; check antgrid_schedule_runs.");
    stub(() => Response.json({ run: { id: "run-q", status: "skipped" } }));
    expect((await callSchedulerTool("antgrid_run_schedule_now", { id: "sch-1" }, NOW)).content[0]!.text)
      .toContain("Skipped");
  });
});
