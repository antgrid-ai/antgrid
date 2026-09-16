// The loopback API is per CORE while an isolated session runs in a managed
// worktree, so every checkout-variable route here has to answer the CALLER's
// checkout — named by the terminal id the MCP server was spawned with. Getting
// this wrong runs an isolated agent's build against main's uncommitted tree and
// hands it another session's scrollback.
import { afterAll, describe, expect, test } from "bun:test";
import { mkdtempSync, realpathSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { startApiServer, type AgentContext, type CallerCheckout } from "../src/api-server";
import type { AbMessage } from "../src/protocol";
import type { TerminalManager } from "../src/terminal-manager";

const dirs: string[] = [];
function tempDir(prefix: string): string {
  const dir = realpathSync(mkdtempSync(join(tmpdir(), prefix)));
  dirs.push(dir);
  return dir;
}

afterAll(() => {
  for (const dir of dirs) rmSync(dir, { recursive: true, force: true });
});

// Prints its own working directory through the same `shell: true` spawn a real
// antgrid.yaml command takes (cmd.exe's `cd` with no argument, sh's `pwd`).
const PRINT_CWD = process.platform === "win32" ? "cd" : "pwd";

const MAIN_DIR = tempDir("scope-main-");
const ISO_DIR = tempDir("scope-iso-");

const MAIN: CallerCheckout = {
  id: "main",
  path: MAIN_DIR,
  config: { commands: [{ name: "build", command: PRINT_CWD }] } as any,
};
const ISO: CallerCheckout = {
  id: "wt-1",
  path: ISO_DIR,
  config: {
    commands: [
      { name: "build", command: PRINT_CWD },
      { name: "iso-only", command: PRINT_CWD },
    ],
  } as any,
};

const ISO_TERMINALS = new Set(["iso-agent", "iso-svc"]);
function checkoutFor(terminalId?: string): CallerCheckout {
  return terminalId && ISO_TERMINALS.has(terminalId) ? ISO : MAIN;
}

const manager = {
  getStatus: () => [
    { terminalId: "main-svc", name: "dev", running: true, shell: "sh", cols: 80, rows: 24, type: "service" },
    { terminalId: "iso-svc", name: "dev", running: true, shell: "sh", cols: 80, rows: 24, type: "service" },
  ],
  getScrollback: (terminalId: string) => ({ text: `output of ${terminalId}` }),
} as unknown as TerminalManager;

function ctx(over: Partial<AgentContext> = {}): AgentContext {
  return {
    manager: () => manager,
    config: () => MAIN.config,
    project: () => ({ id: "p1", path: MAIN.path } as any),
    sendAb: () => {},
    checkoutFor,
    ...over,
  };
}

function url(port: number, path: string, terminalId?: string): string {
  const base = `http://127.0.0.1:${port}${path}`;
  return terminalId ? `${base}${path.includes("?") ? "&" : "?"}terminalId=${terminalId}` : base;
}

describe("checkout-scoped loopback routes", () => {
  test("a command runs in the caller's checkout, not the project path", async () => {
    const sent: AbMessage[] = [];
    const srv = startApiServer(ctx({ sendAb: (m) => sent.push(m) }));
    try {
      const res = await fetch(url(srv.port, "/commands/build/run", "iso-agent"), { method: "POST" });
      const body = await res.json() as { exitCode: number; output: string };
      expect(body.exitCode).toBe(0);
      expect(realpathSync(body.output.trim())).toBe(ISO_DIR);
      // The frames say which checkout the run belongs to, so an app watching
      // an isolated session does not read it as main's.
      expect(sent.length).toBeGreaterThan(0);
      expect(sent.every((m) => (m as any).checkoutId === "wt-1")).toBe(true);
    } finally { srv.stop(); }
  });

  test("a caller that names no terminal still gets the project's own checkout", async () => {
    const srv = startApiServer(ctx());
    try {
      const res = await fetch(url(srv.port, "/commands/build/run"), { method: "POST" });
      const body = await res.json() as { output: string };
      expect(realpathSync(body.output.trim())).toBe(MAIN_DIR);
    } finally { srv.stop(); }
  });

  test("the command list is the caller's checkout's antgrid.yaml", async () => {
    const srv = startApiServer(ctx());
    try {
      const iso = await (await fetch(url(srv.port, "/config", "iso-agent"))).json() as { commands: { name: string }[] };
      expect(iso.commands.map((c) => c.name)).toEqual(["build", "iso-only"]);
      const main = await (await fetch(url(srv.port, "/config"))).json() as { commands: { name: string }[] };
      expect(main.commands.map((c) => c.name)).toEqual(["build"]);
    } finally { srv.stop(); }
  });

  test("a command the caller's checkout does not define is unknown to it", async () => {
    const srv = startApiServer(ctx());
    try {
      const res = await fetch(url(srv.port, "/commands/iso-only/run"), { method: "POST" });
      expect(res.status).toBe(404);
    } finally { srv.stop(); }
  });

  test("the terminal list holds only the caller's checkout", async () => {
    const srv = startApiServer(ctx());
    try {
      const iso = await (await fetch(url(srv.port, "/terminals?all=true", "iso-agent"))).json() as { terminalId: string }[];
      expect(iso.map((t) => t.terminalId)).toEqual(["iso-svc"]);
      const main = await (await fetch(url(srv.port, "/terminals?all=true"))).json() as { terminalId: string }[];
      expect(main.map((t) => t.terminalId)).toEqual(["main-svc"]);
    } finally { srv.stop(); }
  });

  test("another checkout's scrollback answers as not found, never as content", async () => {
    const srv = startApiServer(ctx());
    try {
      const crossing = await fetch(url(srv.port, "/terminals/main-svc/scrollback", "iso-agent"));
      expect(crossing.status).toBe(404);
      const own = await fetch(url(srv.port, "/terminals/iso-svc/scrollback", "iso-agent"));
      expect(await own.text()).toBe("output of iso-svc");
    } finally { srv.stop(); }
  });

  test("a core with no checkout wiring answers exactly as it did before", async () => {
    const srv = startApiServer(ctx({ checkoutFor: undefined }));
    try {
      const terminals = await (await fetch(url(srv.port, "/terminals?all=true", "iso-agent"))).json() as { terminalId: string }[];
      expect(terminals.map((t) => t.terminalId)).toEqual(["main-svc", "iso-svc"]);
      const scrollback = await fetch(url(srv.port, "/terminals/main-svc/scrollback", "iso-agent"));
      expect(await scrollback.text()).toBe("output of main-svc");
    } finally { srv.stop(); }
  });
});
