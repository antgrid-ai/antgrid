// Which channel each terminal-viewer reply actually leaves agent-core on, and
// which wire it reaches. `checkout-mirror-contract.test.ts` gates the SET
// against its Dart mirror; nothing there observes the wire, so both sets could
// agree while agent-core hard-codes a channel the app no longer admits. These
// assertions are written against PREVIEW_CHANNEL_MESSAGE_TYPES rather than
// against the literal "preview"/"control" — the set is the contract, so the
// test fails when the wire and the set disagree, in either direction, instead
// of pinning today's membership a second time.
import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { buildAgentCore, type AgentCore } from "../src/agent-core";
import { closeTerminalHistoryStore } from "../src/terminal-manager";
import { MessageBus, type Channel } from "../src/message-bus";
import { PREVIEW_CHANNEL_MESSAGE_TYPES, createMessage, type AbMessage } from "../src/protocol";
import { setLogLevel } from "../src/logger";
import { TERMINAL_PROTOCOL_VERSION } from "../src/terminal-frames/protocol";

setLogLevel("error");

interface Delivery { message: AbMessage; channel: Channel }

let root: string;
let previousAbDir: string | undefined;
let core: AgentCore | null;

beforeEach(() => {
  previousAbDir = process.env.ANTGRID_DIR;
  root = mkdtempSync(join(tmpdir(), "antgrid-terminal-frame-channel-"));
  process.env.ANTGRID_DIR = join(root, "state");
  // The history:request case needs the real store open; see its own doc in
  // terminal-manager.ts for why a bare `bun test` run opts out by default.
  process.env.ANTGRID_TERMINAL_HISTORY_TEST = "1";
  writeFileSync(join(root, "antgrid.yaml"), "name: terminal-frame-channel\n");
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
): Promise<Delivery> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const found = sent.find((d) => predicate(d.message));
    if (found) return found;
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
  throw new Error(`timed out waiting for ${what}`);
}

/** Both collectors record the CHANNEL, which is the whole subject here — the
 *  delivery suite's collectors discard `deliver`'s second argument, so nothing
 *  there can see a channel change. Two wires, because the replies are
 *  audience-targeted: `sent` stands in for the desktop's loopback socket,
 *  `relaySent` for a phone's relay stream. */
async function bootWithTerminal(): Promise<{ bus: MessageBus; sent: Delivery[]; relaySent: Delivery[] }> {
  core = await buildAgentCore({
    folder: root,
    mode: "local",
    identity: { deviceId: "agent", deviceName: "agent", createdAt: new Date().toISOString() },
  });
  const bus = new MessageBus();
  const sent: Delivery[] = [];
  const relaySent: Delivery[] = [];
  bus.subscribe({ audience: "loopback", deliver: (message, channel) => sent.push({ message, channel }) });
  bus.subscribe({ audience: "relay", deliver: (message, channel) => relaySent.push({ message, channel }) });
  core.attachTransport(bus);
  core.onHandshakeComplete();
  await waitFor(sent, (m) => m.type === "agent:status", "agent:status");

  bus.dispatchInbound(
    createMessage("terminal:start", { terminalId: "adhoc", cwd: tmpdir() }),
    "control",
    "loopback",
  );
  await waitFor(sent, (m) => m.type === "terminal:started" && m.terminalId === "adhoc", "terminal:started");
  return { bus, sent, relaySent };
}

/** The channel the contract says this type must ride. */
function contractChannel(type: string): Channel {
  return PREVIEW_CHANNEL_MESSAGE_TYPES.has(type) ? "preview" : "control";
}

describe("terminal viewer replies ride the channel the contract names", () => {
  test("subscribe, its frames and its history page each leave on their contract channel", async () => {
    const { bus, sent, relaySent } = await bootWithTerminal();
    sent.length = 0;
    relaySent.length = 0;

    const subscribeRequestId = crypto.randomUUID();
    bus.dispatchInbound(
      createMessage("terminal:subscribe", {
        terminalId: "adhoc", version: TERMINAL_PROTOCOL_VERSION, requestId: subscribeRequestId,
      }),
      "control",
      "loopback",
    );
    const subscribed = await waitFor(
      sent,
      (m) => m.type === "terminal:subscribed" && m.requestId === subscribeRequestId,
      "terminal:subscribed",
    );
    if (subscribed.message.type !== "terminal:subscribed") throw new Error("unreachable");
    // Not in the set, so it must be on control — the small latched reply the
    // requester is blocking on is exactly what must not queue behind bulk.
    expect(subscribed.channel).toBe(contractChannel("terminal:subscribed"));

    const frame = await waitFor(sent, (m) => m.type === "terminal:frame" && m.terminalId === "adhoc", "terminal:frame");
    expect(frame.channel).toBe(contractChannel("terminal:frame"));

    const { runId, attachmentId } = subscribed.message;
    const historyRequestId = crypto.randomUUID();
    bus.dispatchInbound(
      createMessage("terminal:history:request", {
        terminalId: "adhoc", runId, attachmentId, requestId: historyRequestId, epoch: 0, beforeRowId: 0,
      }),
      "control",
      "loopback",
    );
    const page = await waitFor(
      sent,
      (m) => m.type === "terminal:history:page" && m.requestId === historyRequestId,
      "terminal:history:page",
    );
    expect(page.channel).toBe(contractChannel("terminal:history:page"));

    // Targeted, not broadcast: the wire that did not ask pays nothing for
    // another client's paging cursor into its own scrollback.
    expect(relaySent.filter((d) => d.message.type === "terminal:history:page")).toEqual([]);
    expect(relaySent.filter((d) => d.message.type === "terminal:frame")).toEqual([]);
  }, 30_000);
});
