import { afterEach, describe, expect, test } from "bun:test";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  callSessionBusTool,
  getApiUrl,
  getTerminalId,
  isSessionBusTool,
} from "../src/mcp/server";

const saved = {
  port: process.env.ANTGRID_API_PORT,
  dir: process.env.ANTGRID_DIR,
  terminal: process.env.ANTGRID_TERMINAL_ID,
};

function restore(
  key: "ANTGRID_API_PORT" | "ANTGRID_DIR" | "ANTGRID_TERMINAL_ID",
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
  function stub(handler: (path: string, body: unknown) => Response) {
    const server = Bun.serve({
      port: 0,
      hostname: "127.0.0.1",
      async fetch(req) {
        const url = new URL(req.url);
        const body = req.method === "POST" ? await req.json().catch(() => null) : null;
        return handler(url.pathname, body);
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
    expect(text).toContain('- [this machine] 4f2ac1 "Wire identity wave 6" — feat/wire-identity, running, can reply');
    expect(text).toContain('- [macbook-pro] 9c11de "Relay flow control" — development, idle, receive-only');
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

  test("a machine-scope reach says which of the three reasons it was", async () => {
    stub(() => Response.json({
      sessions: [],
      truncated: 0,
      machineId: null,
      reach: { scope: "machine", why: "remote-access-off" },
    }));
    const text = (await callSessionBusTool("antgrid_list_sessions", {})).content[0]!.text;
    expect(text).toContain("Reach: remote access is off on this machine");
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
});
