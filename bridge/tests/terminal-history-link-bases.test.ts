import { afterEach, beforeEach, describe, expect, mock, spyOn, test } from "bun:test";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { buildAgentCore, type AgentCore } from "../src/agent-core";
import { TerminalManager, closeTerminalHistoryStore } from "../src/terminal-manager";
import { MessageBus } from "../src/message-bus";
import { createMessage, type AbMessage } from "../src/protocol";
import { setLogLevel } from "../src/logger";
import { TERMINAL_PROTOCOL_VERSION } from "../src/terminal-frames/protocol";
import { pathParams } from "./support/terminal-links-fixtures";

setLogLevel("error");

interface Delivery { message: AbMessage }

let root: string;
let previousAbDir: string | undefined;
let core: AgentCore | null;

beforeEach(() => {
  previousAbDir = process.env.ANTGRID_DIR;
  root = mkdtempSync(join(tmpdir(), "antgrid-history-bases-"));
  process.env.ANTGRID_DIR = join(root, "state");
  process.env.ANTGRID_TERMINAL_HISTORY_TEST = "1";
  writeFileSync(join(root, "antgrid.yaml"), "name: history-link-bases\n");
  mkdirSync(join(root, "sub"));
  writeFileSync(join(root, "sub", "only-here.ts"), "x");
  writeFileSync(join(root, "top.ts"), "x");
});

afterEach(async () => {
  mock.restore();
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

async function waitFor(sent: Delivery[], predicate: (message: AbMessage) => boolean, what: string): Promise<AbMessage> {
  const deadline = Date.now() + 5000;
  while (Date.now() < deadline) {
    const found = sent.find((d) => predicate(d.message));
    if (found) return found.message;
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
  throw new Error(`timed out waiting for ${what}`);
}

/** A terminal whose spawn directory is `sub/`, subscribed to, with its page
 *  source replaced by one row that names a file under `sub/` and one at the
 *  checkout root. */
async function rig() {
  core = await buildAgentCore({
    folder: root,
    mode: "local",
    identity: { deviceId: "agent", deviceName: "agent", createdAt: new Date().toISOString() },
  });
  const bus = new MessageBus();
  const loopback: Delivery[] = [];
  bus.subscribe({ audience: "loopback", deliver: (message) => loopback.push({ message }) });
  core.attachTransport(bus);
  core.onHandshakeComplete();
  await waitFor(loopback, (m) => m.type === "agent:status", "agent:status");

  bus.dispatchInbound(createMessage("terminal:start", { terminalId: "work", cwd: join(root, "sub") }), "control", "loopback");
  await waitFor(loopback, (m) => m.type === "terminal:started" && m.terminalId === "work", "terminal:started");
  const subscribeId = crypto.randomUUID();
  bus.dispatchInbound(createMessage("terminal:subscribe", {
    terminalId: "work", version: TERMINAL_PROTOCOL_VERSION, requestId: subscribeId,
  }), "control", "loopback");
  const subscribed = await waitFor(loopback, (m) => m.type === "terminal:subscribed" && m.requestId === subscribeId, "subscribed");
  if (subscribed.type !== "terminal:subscribed") throw new Error("unreachable");

  const text = "see only-here.ts and top.ts".padEnd(60);
  spyOn(TerminalManager.prototype, "historyPage").mockReturnValue({
    history: { epoch: 0, firstRowId: 1, nextRowId: 2, status: "ready", gapped: false },
    expired: false,
    beforeRowId: 2,
    rows: [{ rowId: 1, cols: 60, wrapped: false, spans: [{ text, cells: 60, sgr: "\x1b[0m" }] }],
  } as unknown as ReturnType<TerminalManager["historyPage"]>);
  // A run the terminal once had: the ownership check passes, and the run is
  // not the one the terminal is running now.
  spyOn(TerminalManager.prototype, "ownsHistoryRun").mockReturnValue(true);

  async function pageLinks(runId: string): Promise<Array<{ p: string; b: string }>> {
    const requestId = crypto.randomUUID();
    bus.dispatchInbound(createMessage("terminal:history:request", {
      terminalId: "work", runId, attachmentId: subscribed.type === "terminal:subscribed" ? subscribed.attachmentId : "",
      requestId, epoch: 0, beforeRowId: 2,
    }), "control", "loopback");
    const answer = await waitFor(loopback, (m) => m.type === "terminal:history:page" && m.requestId === requestId, "history page");
    if (answer.type !== "terminal:history:page") throw new Error("unreachable");
    return answer.rows
      .flatMap((r) => r.spans.map((s) => s.uri))
      .filter((u): u is string => u !== undefined)
      .map((u) => pathParams(u))
      .map(({ p, b }) => ({ p, b }));
  }

  return { pageLinks, liveRunId: subscribed.runId };
}

describe("terminal:history:request link bases", () => {
  test("a page of the terminal's current run resolves against the terminal's own directory first", async () => {
    const { pageLinks, liveRunId } = await rig();

    expect(await pageLinks(liveRunId)).toEqual([
      { p: "only-here.ts", b: "s" },
      { p: "top.ts", b: "r" },
    ]);
  });

  test("a page of any other run never resolves against the live run's directory", async () => {
    const { pageLinks, liveRunId } = await rig();
    const otherRun = crypto.randomUUID();
    expect(otherRun).not.toBe(liveRunId);

    expect(await pageLinks(otherRun)).toEqual([{ p: "top.ts", b: "r" }]);
  });
});
