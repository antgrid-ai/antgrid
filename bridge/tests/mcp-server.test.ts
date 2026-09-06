import { afterEach, describe, expect, test } from "bun:test";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  ROLE_CACHE_MS,
  callSessionBusTool,
  createBusRoleCache,
  getApiUrl,
  getTerminalId,
  isSessionBusTool,
  sessionBusTools,
  type BusRoleView,
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

// The tool table an agent is shown is the whole of what it knows the bus can
// do, so the role that resolves it is a capability boundary and not a
// convenience: a session in no bus session must be offered nothing, or the
// agent spends turns calling tools the bridge can only refuse.
describe("the session-bus tool table", () => {
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

  function roleStub(role: { lead: boolean; peer: boolean }) {
    return stub((path) =>
      path === "/session-bus/role"
        ? Response.json({ role: role.lead ? "lead" : role.peer ? "peer" : null, ...role })
        : Response.json({ error: "not stubbed", code: "NOT_MEMBER" }, { status: 403 }),
    );
  }

  const names = (role: BusRoleView) => sessionBusTools(role).map((t) => t.name);

  test("a lead is offered the lead table and the shared tools, and no peer tool", () => {
    const listed = names({ lead: true, peer: false });
    expect(listed).toContain("antgrid_assign_task");
    expect(listed).toContain("antgrid_answer_peer");
    expect(listed).toContain("antgrid_publish_artifact");
    expect(listed).not.toContain("antgrid_report_complete");
    expect(listed).not.toContain("antgrid_get_brief");
  });

  test("a peer is offered the peer table and the shared tools, and no lead tool", () => {
    const listed = names({ lead: false, peer: true });
    expect(listed).toContain("antgrid_get_brief");
    expect(listed).toContain("antgrid_report_complete");
    expect(listed).toContain("antgrid_ask_lead");
    expect(listed).toContain("antgrid_get_artifact");
    expect(listed).not.toContain("antgrid_assign_task");
    expect(listed).not.toContain("antgrid_answer_peer");
  });

  // A machine can lead one session and work another at the same time, and the
  // tables are disjoint apart from the shared block — listing it twice would
  // put a duplicate tool name in front of the agent.
  test("both roles get both tables, each tool once", () => {
    const listed = names({ lead: true, peer: true });
    expect(listed).toContain("antgrid_assign_task");
    expect(listed).toContain("antgrid_report_complete");
    expect(new Set(listed).size).toBe(listed.length);
  });

  test("a session in no bus session is offered nothing", () => {
    expect(sessionBusTools({ lead: false, peer: false })).toEqual([]);
    // The base tools are unaffected, so a plain session keeps its own.
    expect(isSessionBusTool("antgrid_run_command")).toBe(false);
    expect(isSessionBusTool("antgrid_assign_task")).toBe(true);
  });

  test("the role is read from the loopback bridge", async () => {
    roleStub({ lead: false, peer: true });
    expect(await createBusRoleCache().get()).toEqual({ lead: false, peer: true });
  });

  // An unreachable bridge and a member-less terminal must land on the same
  // answer: absence is never read as a role.
  test("an unreachable bridge resolves to no role rather than to a guess", async () => {
    delete process.env.ANTGRID_API_PORT;
    expect(await createBusRoleCache().get()).toEqual({ lead: false, peer: false });
  });

  // The watcher that tells a client its tool list moved is the one caller whose
  // whole job is noticing a change, so the cache must not answer it.
  test("refresh re-reads inside the window the cache would have served", async () => {
    let role = { lead: false, peer: false };
    let asked = 0;
    stub((path) => {
      if (path !== "/session-bus/role") return new Response("no", { status: 404 });
      asked += 1;
      return Response.json({ lead: role.lead, peer: role.peer });
    });
    let clock = 1_000;
    const cache = createBusRoleCache(() => clock);
    expect(await cache.get()).toEqual({ lead: false, peer: false });
    // The machine is added here — inside the window a plain get() would serve
    // from cache, which is exactly when a lead needs to be told.
    role = { lead: true, peer: false };
    expect(await cache.refresh()).toEqual({ lead: true, peer: false });
    expect(asked).toBe(2);
    // And the refreshed answer becomes the cached one, so the list the client
    // asks for next matches the notification it was just sent.
    expect(await cache.get()).toEqual({ lead: true, peer: false });
    expect(asked).toBe(2);
  });

  test("a resolved role is reused inside its window and re-read after it", async () => {
    let asked = 0;
    stub((path) => {
      if (path !== "/session-bus/role") return new Response("no", { status: 404 });
      asked += 1;
      return Response.json({ role: "lead", lead: true, peer: false });
    });
    let clock = 1_000;
    const cache = createBusRoleCache(() => clock);
    await cache.get();
    clock += ROLE_CACHE_MS - 1;
    await cache.get();
    expect(asked).toBe(1);
    clock += 1;
    await cache.get();
    expect(asked).toBe(2);
  });

  // The bridge authored the refusal and owns the wording; this process appends
  // the code and changes nothing else, because the code is the part an agent
  // can act on without reading English.
  test("a refusal reaches the caller as the bridge wrote it, with its code", async () => {
    stub(() => Response.json(
      { error: "no session named \"gateway\" has joined this session; list them with antgrid_list_peers", code: "UNKNOWN_PEER" },
      { status: 404 },
    ));
    const result = await callSessionBusTool("antgrid_assign_task", {
      peer: "gateway",
      summary: "wire the codec",
      instruction: "do the thing",
    });
    expect(result.isError).toBe(true);
    expect(result.content[0]!.text).toBe(
      "no session named \"gateway\" has joined this session; list them with antgrid_list_peers (UNKNOWN_PEER)",
    );
  });

  test("a refusal with no code is rendered unchanged", async () => {
    stub(() => Response.json({ error: "Invalid body" }, { status: 400 }));
    const result = await callSessionBusTool("antgrid_report_finding", { taskId: "t-1", finding: "x" });
    expect(result.isError).toBe(true);
    expect(result.content[0]!.text).toBe("Invalid body");
  });

  test("a tool call with no core reachable says so instead of failing silently", async () => {
    delete process.env.ANTGRID_API_PORT;
    const result = await callSessionBusTool("antgrid_list_peers", {});
    expect(result.isError).toBe(true);
    expect(result.content[0]!.text).toContain("Antgrid agent is not running");
  });

  // What an agent is TOLD is the whole interface here: it cannot see the outbox,
  // so a sentence that overstates delivery is the only thing standing between a
  // lost report and a retry it would otherwise have made.
  test("a finding that did not leave and has no task to carry it is an error", async () => {
    stub(() => Response.json({ ok: true, sent: false }));
    const result = await callSessionBusTool("antgrid_report_finding", {
      summary: "the codec is little-endian",
      text: "checked against the fixtures",
    });
    expect(result.isError).toBe(true);
    expect(result.content[0]!.text).toContain("not delivered");
    expect(result.content[0]!.text).not.toContain("travels with the next report");
  });

  test("a finding held on a task still says it travels", async () => {
    stub(() => Response.json({ ok: true, sent: false }));
    const result = await callSessionBusTool("antgrid_report_finding", {
      taskId: "t-1",
      summary: "s",
      text: "t",
    });
    expect(result.isError).toBeUndefined();
    expect(result.content[0]!.text).toBe("Finding recorded on the task. It travels with the next report.");
  });

  test("an assignment that has not reached the peer says so, and says not to repeat it", async () => {
    stub(() => Response.json({ ok: true, taskId: "t-9", delivered: false }));
    const result = await callSessionBusTool("antgrid_assign_task", {
      peer: "gateway",
      summary: "s",
      instruction: "i",
    });
    expect(result.isError).toBeUndefined();
    expect(result.content[0]!.text).toContain("has not reached that machine yet");
    expect(result.content[0]!.text).toContain("Do not assign it again");
  });

  // A peer leads nobody, so `members` is empty on every status it reads. Without
  // the lead line it is told nothing about the one session it is attached to —
  // and this is the peer's ONLY view of the lead's machine, because a Capability
  // Card may not ride in a brief that an armed Handler would authorize.
  test("a peer's status names the lead it answers to, with that machine's card", async () => {
    stub(() => Response.json({
      role: "peer",
      lead: false,
      peer: true,
      sessionId: "peer-1",
      contextId: "lead-1",
      self: { machineId: "m2", projectId: "p2", sessionId: "peer-1" },
      memberOf: {
        machineId: "m1",
        projectId: "p1",
        sessionId: "lead-1",
        sessionName: "lead session",
        machineLabel: "Studio",
        projectLabel: "antgrid",
        role: "lead",
        joinedAt: 1,
        state: "active",
        card: {
          os: { name: "Windows", version: "11", arch: "x64" },
          repo: { label: "antgrid", remote: "github.com/acme/antgrid", branch: "main" },
        },
      },
      members: [],
      scope: [],
      budget: { tasksRemaining: 5, hourlyRemaining: 5, halted: false },
      openTaskIds: [],
    }));
    const result = await callSessionBusTool("antgrid_session_status", {});
    const text = result.content[0]!.text;
    expect(text).toContain('Leader: lead session [active] id=lead-1 machine=Studio project=antgrid');
    expect(text).toContain("os: Windows, 11, x64");
    expect(text).toContain("repo: antgrid, github.com/acme/antgrid, main");
    expect(text).toContain("Members: none");
  });

  test("a lead's status carries no lead line", async () => {
    stub(() => Response.json({
      role: "lead",
      lead: true,
      peer: false,
      sessionId: "lead-1",
      contextId: "lead-1",
      self: { machineId: "m1", projectId: "p1", sessionId: "lead-1" },
      members: [],
      scope: [],
      budget: { tasksRemaining: 5, hourlyRemaining: 5, halted: false },
      openTaskIds: [],
    }));
    const result = await callSessionBusTool("antgrid_session_status", {});
    expect(result.content[0]!.text).not.toContain("Leader:");
  });

  test("an unset optional argument is not sent, so a .strict() body still parses", async () => {
    let received: unknown = null;
    stub((path, body) => {
      received = body;
      return Response.json({ ok: true, taskId: "t-9" });
    });
    await callSessionBusTool("antgrid_assign_task", { peer: "gateway", summary: "s", instruction: "i" });
    expect(received).toEqual({ peer: "gateway", summary: "s", instruction: "i" });
  });
});
