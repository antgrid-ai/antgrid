// Which channel each terminal-viewer reply actually leaves agent-core on, and
// which wire it reaches. `checkout-mirror-contract.test.ts` gates the SET
// against its Dart mirror; nothing there observes the wire, so both sets could
// agree while agent-core hard-codes a channel the app no longer admits. These
// assertions are written against PREVIEW_CHANNEL_MESSAGE_TYPES rather than
// against the literal "preview"/"control" — the set is the contract, so the
// test fails when the wire and the set disagree, in either direction, instead
// of pinning today's membership a second time.
import { afterEach, beforeEach, describe, expect, spyOn, test } from "bun:test";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { buildAgentCore, type AgentCore } from "../src/agent-core";
import { TerminalManager, closeTerminalHistoryStore } from "../src/terminal-manager";
import { MessageBus, type Channel } from "../src/message-bus";
import { PREVIEW_CHANNEL_MESSAGE_TYPES, createMessage, type AbMessage } from "../src/protocol";
import { setLogLevel } from "../src/logger";
import { TERMINAL_PROTOCOL_VERSION } from "../src/terminal-frames/protocol";
import type { TerminalStreamHooks } from "../src/stream-mux";

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
  test("two relay viewers keep independent attachments, replies and disconnects", async () => {
    const { bus } = await bootWithTerminal();
    const deliveries: Array<Delivery & { peerId?: string }> = [];
    bus.subscribe({ audience: "relay", deliver: (message, channel, _signal, peerId) => {
      deliveries.push({ message, channel, peerId });
    } });
    for (const peerId of ["phone-1", "phone-2"]) {
      bus.dispatchInbound(createMessage("terminal:subscribe", {
        terminalId: "adhoc", version: TERMINAL_PROTOCOL_VERSION, requestId: peerId,
      }), "control", "relay", peerId);
    }
    const one = await waitFor(deliveries, m => m.type === "terminal:subscribed" && m.requestId === "phone-1", "first subscription");
    const two = await waitFor(deliveries, m => m.type === "terminal:subscribed" && m.requestId === "phone-2", "second subscription");
    if (one.message.type !== "terminal:subscribed" || two.message.type !== "terminal:subscribed") throw new Error("unreachable");
    expect(one.message.attachmentId).not.toBe(two.message.attachmentId);
    for (const [peerId, subscription] of [["phone-1", one.message], ["phone-2", two.message]] as const) {
      const frame = await waitFor(deliveries, m => m.type === "terminal:frame" && m.attachmentId === subscription.attachmentId, peerId);
      expect(deliveries.find(d => d.message === frame.message)?.peerId).toBe(peerId);
    }
    core!.noteClientGone("phone-1");
    const { runId, attachmentId } = two.message;
    bus.dispatchInbound(createMessage("terminal:history:request", {
      terminalId: "adhoc", runId, attachmentId, requestId: "page-two", epoch: 0, beforeRowId: 0,
    }), "control", "relay", "phone-2");
    const page = await waitFor(deliveries, m => m.type === "terminal:history:page" && m.requestId === "page-two", "second viewer history");
    expect(deliveries.find(d => d.message === page.message)?.peerId).toBe("phone-2");
  }, 30_000);

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

// A2: routing itself moved into the mux subscriber (below the core, D-4), so
// the channel expectations above are unchanged. What IS new at the core is
// that a relay terminal:subscribe's own lifecycle reaches a registry through
// these hooks — never for loopback, which never binds a native stream.
describe("terminal stream hooks (A2)", () => {
  function hooksRecorder() {
    const retired: Array<{ peerId: string; attachmentId: string }> = [];
    const settled: Array<{ peerId: string; requestId: string; attachmentId: string | undefined }> = [];
    const hooks: TerminalStreamHooks = {
      retired: (peerId, attachmentId) => retired.push({ peerId, attachmentId }),
      subscribeSettled: (peerId, requestId, attachmentId) => settled.push({ peerId, requestId, attachmentId }),
    };
    return { hooks, retired, settled };
  }

  test("retired and subscribeSettled reach the terminal stream hooks with the relay peerId and never for loopback", async () => {
    const { bus, sent } = await bootWithTerminal();
    const { hooks, retired, settled } = hooksRecorder();
    core!.setTerminalStreamHooks(hooks);
    const relayDeliveries: Array<Delivery & { peerId?: string }> = [];
    bus.subscribe({ audience: "relay", deliver: (message, channel, _signal, peerId) => {
      relayDeliveries.push({ message, channel, peerId });
    } });

    const requestId = crypto.randomUUID();
    bus.dispatchInbound(
      createMessage("terminal:subscribe", { terminalId: "adhoc", version: TERMINAL_PROTOCOL_VERSION, requestId }),
      "control", "relay", "phone-1",
    );
    const subscribed = await waitFor(relayDeliveries, (m) => m.type === "terminal:subscribed" && m.requestId === requestId, "terminal:subscribed");
    if (subscribed.message.type !== "terminal:subscribed") throw new Error("unreachable");
    expect(settled).toEqual([{ peerId: "phone-1", requestId, attachmentId: subscribed.message.attachmentId }]);

    bus.dispatchInbound(
      createMessage("terminal:unsubscribe", {
        terminalId: "adhoc", runId: subscribed.message.runId, attachmentId: subscribed.message.attachmentId,
      }),
      "control", "relay", "phone-1",
    );
    await new Promise((resolve) => setTimeout(resolve, 150));
    expect(retired).toEqual([{ peerId: "phone-1", attachmentId: subscribed.message.attachmentId }]);

    // A loopback subscriber never binds a native stream, so it must never
    // reach these hooks even though it goes through the exact same core path.
    settled.length = 0;
    retired.length = 0;
    const loopbackRequestId = crypto.randomUUID();
    bus.dispatchInbound(
      createMessage("terminal:subscribe", { terminalId: "adhoc", version: TERMINAL_PROTOCOL_VERSION, requestId: loopbackRequestId }),
      "control", "loopback",
    );
    const loopbackSubscribed = await waitFor(
      sent, (m) => m.type === "terminal:subscribed" && m.requestId === loopbackRequestId, "loopback terminal:subscribed",
    );
    if (loopbackSubscribed.message.type !== "terminal:subscribed") throw new Error("unreachable");
    expect(settled).toEqual([]);
    core!.noteClientGone("loopback");
    await new Promise((resolve) => setTimeout(resolve, 150));
    expect(retired).toEqual([]);
  }, 30_000);

  test("every exit of a relay terminal:subscribe calls subscribeSettled exactly once", async () => {
    const { bus } = await bootWithTerminal();
    const { hooks, settled } = hooksRecorder();
    core!.setTerminalStreamHooks(hooks);
    const relayDeliveries: Array<Delivery & { peerId?: string }> = [];
    bus.subscribe({ audience: "relay", deliver: (message, channel, _signal, peerId) => {
      relayDeliveries.push({ message, channel, peerId });
    } });

    // Unknown terminal: the subscribe resolves with no attachment.
    const unknownRequestId = crypto.randomUUID();
    bus.dispatchInbound(
      createMessage("terminal:subscribe", { terminalId: "never-existed", version: TERMINAL_PROTOCOL_VERSION, requestId: unknownRequestId }),
      "control", "relay", "phone-unknown",
    );
    await waitFor(
      relayDeliveries,
      (m) => (m.type === "terminal:subscribed" || m.type === "terminal:display:status") &&
        (m as { requestId?: string }).requestId === unknownRequestId,
      "unknown-terminal reply",
    );
    await new Promise((resolve) => setTimeout(resolve, 50));
    expect(settled.filter((s) => s.requestId === unknownRequestId)).toHaveLength(1);

    // A generation mismatch: the client's socket is torn down while the
    // subscribe's own async attach (restoreArchivedTerminal) is still
    // in flight, so the continuation's generation check breaks it.
    //
    // The spy stays installed for the rest of the test (only its
    // implementation swaps) — `mockRestore()` detaches the spy from the
    // prototype entirely, so a later `mockImplementationOnce` on the same
    // handle would silently do nothing and the real method would run instead.
    const originalRestore = TerminalManager.prototype.restoreArchivedTerminal;
    const restoreArchived = spyOn(TerminalManager.prototype, "restoreArchivedTerminal");
    const gate = Promise.withResolvers<void>();
    restoreArchived.mockImplementationOnce(() => gate.promise);
    const raceRequestId = crypto.randomUUID();
    bus.dispatchInbound(
      createMessage("terminal:subscribe", { terminalId: "adhoc", version: TERMINAL_PROTOCOL_VERSION, requestId: raceRequestId }),
      "control", "relay", "phone-race",
    );
    await new Promise((resolve) => setTimeout(resolve, 20)); // let it reach the await
    core!.noteClientGone("phone-race");
    gate.resolve();
    await new Promise((resolve) => setTimeout(resolve, 100));
    const raceSettled = settled.filter((s) => s.requestId === raceRequestId);
    expect(raceSettled).toEqual([{ peerId: "phone-race", requestId: raceRequestId, attachmentId: undefined }]);
    expect(relayDeliveries.some((d) => (d.message as { requestId?: string }).requestId === raceRequestId)).toBe(false);
    restoreArchived.mockImplementation(originalRestore);

    // Success path.
    const okRequestId = crypto.randomUUID();
    bus.dispatchInbound(
      createMessage("terminal:subscribe", { terminalId: "adhoc", version: TERMINAL_PROTOCOL_VERSION, requestId: okRequestId }),
      "control", "relay", "phone-ok",
    );
    const ok = await waitFor(relayDeliveries, (m) => m.type === "terminal:subscribed" && m.requestId === okRequestId, "success subscribed");
    if (ok.message.type !== "terminal:subscribed") throw new Error("unreachable");
    expect(settled.filter((s) => s.requestId === okRequestId)).toEqual([
      { peerId: "phone-ok", requestId: okRequestId, attachmentId: ok.message.attachmentId },
    ]);

    // Attach failure: restoreArchivedTerminal itself rejects, driving the
    // `.catch` exit, whose DISPLAY_FAILED notice must be handed to the
    // transport before subscribeSettled fires (§3.5).
    restoreArchived.mockImplementationOnce(() => Promise.reject(new Error("archive unavailable")));
    const failRequestId = crypto.randomUUID();
    bus.dispatchInbound(
      createMessage("terminal:subscribe", { terminalId: "adhoc", version: TERMINAL_PROTOCOL_VERSION, requestId: failRequestId }),
      "control", "relay", "phone-fail",
    );
    const failed = await waitFor(
      relayDeliveries,
      (m) => m.type === "terminal:display:status" && (m as { requestId?: string }).requestId === failRequestId,
      "archive display failure",
    );
    expect(failed.message).toMatchObject({ code: "DISPLAY_FAILED" });
    await new Promise((resolve) => setTimeout(resolve, 50));
    expect(settled.filter((s) => s.requestId === failRequestId)).toEqual([
      { peerId: "phone-fail", requestId: failRequestId, attachmentId: undefined },
    ]);
    restoreArchived.mockImplementation(originalRestore);

    // Every request id this test drove settled exactly once.
    const counts = new Map<string, number>();
    for (const s of settled) counts.set(s.requestId, (counts.get(s.requestId) ?? 0) + 1);
    for (const count of counts.values()) expect(count).toBe(1);
  }, 30_000);
});
