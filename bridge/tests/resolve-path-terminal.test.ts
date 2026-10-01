import { afterEach, beforeEach, describe, expect, spyOn, test } from "bun:test";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { buildAgentCore, type AgentCore } from "../src/agent-core";
import { TerminalManager, closeTerminalHistoryStore } from "../src/terminal-manager";
import { MessageBus } from "../src/message-bus";
import { createMessage, type AbMessage } from "../src/protocol";
import { setLogLevel } from "../src/logger";
import { TERMINAL_PROTOCOL_VERSION } from "../src/terminal-frames/protocol";

setLogLevel("error");

type ResolveReply = Extract<AbMessage, { type: "file:resolve-path-result" }>;
interface Delivery { message: AbMessage; peerId?: string }

let root: string;
let previousAbDir: string | undefined;
let core: AgentCore | null;

beforeEach(() => {
  previousAbDir = process.env.ANTGRID_DIR;
  root = mkdtempSync(join(tmpdir(), "antgrid-resolve-path-"));
  process.env.ANTGRID_DIR = join(root, "state");
  process.env.ANTGRID_TERMINAL_HISTORY_TEST = "1";
  writeFileSync(join(root, "antgrid.yaml"), "name: resolve-path-terminal\n");
  mkdirSync(join(root, "sub"));
  writeFileSync(join(root, "sub", "only-here.ts"), "x");
  writeFileSync(join(root, "top.ts"), "x");
});

afterEach(async () => {
  const dying = core;
  const dir = root;
  const restore = previousAbDir;
  core = null;
  if (restore === undefined) delete process.env.ANTGRID_DIR;
  else process.env.ANTGRID_DIR = restore;
  delete process.env.ANTGRID_TERMINAL_HISTORY_TEST;
  try {
    await dying?.shutdown();
  } finally {
    closeTerminalHistoryStore();
    rmSync(dir, { recursive: true, force: true });
  }
}, 30_000);

async function waitFor(
  sent: Delivery[],
  predicate: (message: AbMessage) => boolean,
  what: string,
  timeoutMs = 5000,
): Promise<AbMessage> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const found = sent.find((d) => predicate(d.message));
    if (found) return found.message;
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
  throw new Error(`timed out waiting for ${what}`);
}

async function boot(): Promise<{ bus: MessageBus; loopback: Delivery[]; relay: Delivery[] }> {
  core = await buildAgentCore({
    folder: root,
    mode: "local",
    identity: { deviceId: "agent", deviceName: "agent", createdAt: new Date().toISOString() },
  });
  const bus = new MessageBus();
  const loopback: Delivery[] = [];
  const relay: Delivery[] = [];
  bus.subscribe({ audience: "loopback", deliver: (message) => loopback.push({ message }) });
  bus.subscribe({ audience: "relay", deliver: (message, _channel, _signal, peerId) => relay.push({ message, peerId }) });
  core.attachTransport(bus);
  core.onHandshakeComplete();
  await waitFor(loopback, (m) => m.type === "agent:status", "agent:status");
  return { bus, loopback, relay };
}

async function startTerminal(bus: MessageBus, loopback: Delivery[], terminalId: string, cwd: string): Promise<void> {
  bus.dispatchInbound(createMessage("terminal:start", { terminalId, cwd }), "control", "loopback");
  await waitFor(loopback, (m) => m.type === "terminal:started" && m.terminalId === terminalId, "terminal:started");
}

function resolveRequest(
  requestId: string,
  path: string,
  extra: { terminalId?: string; base?: "a" | "l" | "s" | "r" } = {},
): AbMessage {
  return createMessage("file:resolve-path", { projectId: core!.projectId, requestId, path, ...extra });
}

async function reply(sent: Delivery[], requestId: string): Promise<ResolveReply> {
  const found = await waitFor(sent, (m) => m.type === "file:resolve-path-result" && m.requestId === requestId, `reply ${requestId}`);
  return found as ResolveReply;
}

describe("file:resolve-path against a terminal", () => {
  test("the spawn directory of the named terminal is the base, and only that base", async () => {
    const { bus, loopback } = await boot();
    await startTerminal(bus, loopback, "work", join(root, "sub"));

    bus.dispatchInbound(resolveRequest("in-spawn", "only-here.ts", { terminalId: "work", base: "s" }), "control", "loopback");
    bus.dispatchInbound(resolveRequest("no-fallthrough", "top.ts", { terminalId: "work", base: "s" }), "control", "loopback");

    const found = await reply(loopback, "in-spawn");
    const missing = await reply(loopback, "no-fallthrough");
    expect(found.relPath).toBe("sub/only-here.ts");
    expect(found.exists).toBe(true);
    expect(missing.relPath).toBe("sub/top.ts");
    expect(missing.exists).toBe(false);
  });

  test("a terminal outside the checkout contributes no base", async () => {
    const { bus, loopback } = await boot();
    await startTerminal(bus, loopback, "elsewhere", tmpdir());

    bus.dispatchInbound(resolveRequest("outside", "top.ts", { terminalId: "elsewhere", base: "s" }), "control", "loopback");

    const answer = await reply(loopback, "outside");
    expect(answer.relPath).toBeNull();
    expect(answer.exists).toBe(false);
  });

  test("a terminal id that names nothing gives no base", async () => {
    const { bus, loopback } = await boot();

    bus.dispatchInbound(resolveRequest("ghost", "top.ts", { terminalId: "ghost-1", base: "s" }), "control", "loopback");

    const answer = await reply(loopback, "ghost");
    expect(answer.relPath).toBeNull();
    expect(answer.exists).toBe(false);
  });

  test("without a terminal or base the checkout root is the only base", async () => {
    const { bus, loopback } = await boot();

    bus.dispatchInbound(resolveRequest("plain", "top.ts"), "control", "loopback");

    const answer = await reply(loopback, "plain");
    expect(answer.relPath).toBe("top.ts");
    expect(answer.exists).toBe(true);
    expect(answer.checkoutId).toBe("main");
  });

  test("malformed optional fields are ignored rather than trusted", async () => {
    const { bus, loopback } = await boot();

    bus.dispatchInbound({
      ...resolveRequest("odd", "top.ts"), terminalId: 42, base: "zzz",
    } as unknown as AbMessage, "control", "loopback");

    const answer = await reply(loopback, "odd");
    expect(answer.relPath).toBe("top.ts");
  });

  test("the reply reaches only the client that asked", async () => {
    const { bus, loopback, relay } = await boot();

    bus.dispatchInbound(resolveRequest("from-phone-1", "top.ts"), "control", "relay", "phone-1");
    await waitFor(relay, (m) => m.type === "file:resolve-path-result" && m.requestId === "from-phone-1", "phone reply");
    bus.dispatchInbound(resolveRequest("from-loopback", "top.ts"), "control", "loopback");
    await reply(loopback, "from-loopback");

    expect(relay.find((d) => d.message.type === "file:resolve-path-result" && d.message.requestId === "from-phone-1")?.peerId)
      .toBe("phone-1");
    expect(loopback.some((d) => d.message.type === "file:resolve-path-result" && d.message.requestId === "from-phone-1")).toBe(false);
    expect(relay.some((d) => d.message.type === "file:resolve-path-result" && d.message.requestId === "from-loopback")).toBe(false);
  });

  test("a ninth concurrent request from one client is dropped", async () => {
    const { bus, loopback } = await boot();

    for (let i = 0; i < 9; i++) bus.dispatchInbound(resolveRequest(`burst-${i}`, "top.ts"), "control", "loopback");
    for (let i = 0; i < 8; i++) await reply(loopback, `burst-${i}`);
    await new Promise((resolve) => setTimeout(resolve, 200));

    expect(loopback.some((d) => d.message.type === "file:resolve-path-result" && d.message.requestId === "burst-8")).toBe(false);

    // The slot frees once the replies are out, so the client is not locked out.
    bus.dispatchInbound(resolveRequest("after", "top.ts"), "control", "loopback");
    expect((await reply(loopback, "after")).exists).toBe(true);
  });
});

describe("terminal:history:page detection", () => {
  test("a page answers with detected URL links and reaches only the requester", async () => {
    const { bus, loopback, relay } = await boot();
    await startTerminal(bus, loopback, "adhoc", tmpdir());
    const requestId = crypto.randomUUID();
    bus.dispatchInbound(createMessage("terminal:subscribe", {
      terminalId: "adhoc", version: TERMINAL_PROTOCOL_VERSION, requestId,
    }), "control", "loopback");
    const subscribed = await waitFor(loopback, (m) => m.type === "terminal:subscribed" && m.requestId === requestId, "subscribed");
    if (subscribed.type !== "terminal:subscribed") throw new Error("unreachable");

    const text = "see https://example.com/archived ok".padEnd(40);
    const page = spyOn(TerminalManager.prototype, "historyPage").mockReturnValue({
      history: { epoch: 0, firstRowId: 1, nextRowId: 2, status: "ready", gapped: false },
      expired: false,
      beforeRowId: 2,
      rows: [{ rowId: 1, cols: 40, wrapped: false, spans: [{ text, cells: 40, sgr: "\x1b[0m" }] }],
    } as unknown as ReturnType<TerminalManager["historyPage"]>);
    try {
      bus.dispatchInbound(createMessage("terminal:history:request", {
        terminalId: "adhoc", runId: subscribed.runId, attachmentId: subscribed.attachmentId,
        requestId: "history-1", epoch: 0, beforeRowId: 2,
      }), "control", "loopback");
      const answer = await waitFor(loopback, (m) => m.type === "terminal:history:page" && m.requestId === "history-1", "history page");
      if (answer.type !== "terminal:history:page") throw new Error("unreachable");

      const uris = answer.rows.flatMap((r) => r.spans.map((s) => s.uri)).filter((u) => u !== undefined);
      expect(uris).toEqual(["antgrid-url:https://example.com/archived"]);
      expect(relay.some((d) => d.message.type === "terminal:history:page")).toBe(false);
    } finally {
      page.mockRestore();
    }
  });
});

describe("links in a terminal's frames", () => {
  type FrameMessage = Extract<AbMessage, { type: "terminal:frame" }>;

  async function startPrinter(bus: MessageBus, loopback: Delivery[], terminalId: string): Promise<void> {
    bus.dispatchInbound(createMessage("terminal:start", {
      terminalId,
      cwd: root,
      command: process.execPath,
      args: ["-e", "console.log('see top.ts'); setTimeout(() => {}, 60000)"],
    }), "control", "loopback");
    await waitFor(loopback, (m) => m.type === "terminal:started" && m.terminalId === terminalId, "terminal:started");
  }

  /** A viewer that acknowledges every frame, which is what lets the next one
   *  through, and returns the first frame the predicate accepts. */
  async function viewUntil(
    bus: MessageBus,
    loopback: Delivery[],
    terminalId: string,
    accept: (frame: FrameMessage) => boolean,
  ): Promise<{ frame: FrameMessage; runId: string; attachmentId: string }> {
    const requestId = crypto.randomUUID();
    bus.dispatchInbound(createMessage("terminal:subscribe", {
      terminalId, version: TERMINAL_PROTOCOL_VERSION, requestId,
    }), "control", "loopback");
    const subscribed = await waitFor(loopback, (m) => m.type === "terminal:subscribed" && m.requestId === requestId, "subscribed");
    if (subscribed.type !== "terminal:subscribed") throw new Error("unreachable");
    const seen = new Set<number>();
    const deadline = Date.now() + 15_000;
    while (Date.now() < deadline) {
      for (const d of loopback) {
        const m = d.message;
        if (m.type !== "terminal:frame" || m.attachmentId !== subscribed.attachmentId || seen.has(m.sequence)) continue;
        seen.add(m.sequence);
        if (accept(m)) return { frame: m, runId: subscribed.runId, attachmentId: subscribed.attachmentId };
        bus.dispatchInbound(createMessage("terminal:ack", {
          terminalId, runId: subscribed.runId, attachmentId: subscribed.attachmentId, sequence: m.sequence,
        }), "control", "loopback");
      }
      await new Promise((resolve) => setTimeout(resolve, 20));
    }
    throw new Error("no frame carried the link");
  }

  const hasLink = (frame: FrameMessage): boolean => frame.ansi.includes("antgrid-path:") && frame.ansi.includes("top.ts");

  test("a live terminal's printed relative path links against the checkout the core set", async () => {
    const { bus, loopback } = await boot();
    await startPrinter(bus, loopback, "live");

    const { frame } = await viewUntil(bus, loopback, "live", hasLink);

    expect(frame.ansi).toContain("antgrid-path:");
  }, 30_000);

  test("a stopped terminal's saved screen is linked again when it is restored for a viewer", async () => {
    const { bus, loopback } = await boot();
    await startPrinter(bus, loopback, "stopped");
    const first = await viewUntil(bus, loopback, "stopped", hasLink);
    // Still attached: the hub keeps the finished run for it, and the restore re-registers that same run.
    bus.dispatchInbound(createMessage("terminal:stop", { terminalId: "stopped" }), "control", "loopback");
    await waitFor(loopback, (m) => m.type === "terminal:exited" && m.terminalId === "stopped", "terminal:exited");
    await new Promise((resolve) => setTimeout(resolve, 500));
    const restore = spyOn(TerminalManager.prototype, "restoreArchivedTerminal");
    try {
      const restored = await viewUntil(bus, loopback, "stopped", hasLink);

      expect(restore).toHaveBeenCalled();
      expect(restored.runId).toBe(first.runId);
      expect(restored.frame.ansi).toContain("antgrid-path:");
    } finally {
      restore.mockRestore();
    }
  }, 30_000);
});
