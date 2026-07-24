import { afterAll, afterEach, beforeEach, describe, expect, it } from "bun:test";
import { RelayClient } from "../src/relay-client";
import { createMessage } from "../src/protocol";
import { __setRootForTest } from "../src/logger";

const RELAY_RATE_ERROR = JSON.stringify({
  type: "error",
  code: "MESSAGE_RATE_LIMITED",
  message: "Message rate limit exceeded",
  retryable: true,
});

describe("RelayClient rate-limit diagnostics", () => {
  let client: RelayClient | null = null;
  // pino writes JSONL straight to its destination stream, bypassing console.*,
  // so capture via the test root rather than spying on console.error.
  let capturedLines: string[];
  let surfaced: Array<{ code: string; message: string }>;

  /** A paired, handshake-complete client whose socket and seal are inert, so a
   *  send does everything except leave the process. */
  function makeClient(): RelayClient {
    const c = new RelayClient({
      url: "ws://127.0.0.1:1",
      identity: {
        deviceId: "dev-1",
        deviceName: "machine",
        createdAt: new Date().toISOString(),
        ed25519PublicKey: "pk",
        ed25519PrivateKey: "sk",
      },
      generateKeypair: () => { throw new Error("not used"); },
      getLicenseToken: () => "token",
      onError: (code, message) => surfaced.push({ code, message }),
    });
    (c as any)._peerId = "phone-1";
    (c as any).established = {
      attemptId: "a1",
      transport: { seal: (plaintext: string) => Buffer.from(plaintext, "utf8") },
      sessionKeys: { a2p: Buffer.alloc(32), p2a: Buffer.alloc(32), confirm: Buffer.alloc(32) },
    };
    (c as any).ws = {
      readyState: WebSocket.OPEN,
      send: () => {},
      close: () => {},
    };
    return c;
  }

  function sendItems(c: RelayClient, count: number): void {
    for (let i = 0; i < count; i++) {
      c.sendOnChannel(createMessage("agent:item-added", {
        sessionId: "session-1",
        turnId: "turn-1",
        itemId: `item-${i}`,
        item: {
          itemId: `item-${i}`,
          kind: "message",
          role: "assistant",
          text: "delta",
        },
      }), "control");
    }
  }

  const logLines = (): string[] =>
    capturedLines.map((l) => (JSON.parse(l) as { msg: string }).msg);

  beforeEach(() => {
    surfaced = [];
    capturedLines = [];
    __setRootForTest({
      write(s: string): boolean {
        capturedLines.push(s);
        return true;
      },
    }, "debug");
  });

  afterEach(() => {
    client?.close();
    client = null;
  });

  afterAll(() => __setRootForTest(process.stdout));

  it("logs the project and recent outbound message types without flooding callbacks", () => {
    client = makeClient();

    client.sendOnChannel(createMessage("agent:turn-start", {
      sessionId: "session-1",
      turnId: "turn-1",
    }), "control");
    sendItems(client, 3);

    (client as any).handleTextMessage(RELAY_RATE_ERROR);
    (client as any).handleTextMessage(RELAY_RATE_ERROR);

    expect(surfaced).toEqual([{
      code: "MESSAGE_RATE_LIMITED",
      message: "Message rate limit exceeded",
    }]);
    expect(capturedLines.length).toBe(1);

    const log = logLines()[0];
    expect(log).toContain("device=dev-1");
    expect(log).toContain("peer=phone-1");
    expect(log).toContain("total=4 frame(s)");
    expect(log).toContain("agent:item-added/control=3 frame(s)");
    expect(log).toContain("agent:turn-start/control=1 frame(s)");

    (client as any).finishRateLimitBurst();
    expect(capturedLines.length).toBe(2);
    const summary = logLines()[1];
    expect(summary).toContain("rejectedFrames=2");
    expect(summary).toContain("duplicateCallbacksSuppressed=1");
  });

  it("still reports the burst summary when the socket drops mid-flood", () => {
    client = makeClient();
    sendItems(client, 2);
    for (let i = 0; i < 3; i++) (client as any).handleTextMessage(RELAY_RATE_ERROR);

    // A flood usually ends with the pair being torn down — which is exactly
    // when the rejected-frame count is worth having. Discarding the burst on
    // cleanup loses it precisely in the case the diagnostic exists for.
    client.close();

    const summaries = logLines().filter((l) => l.includes("burst summary"));
    expect(summaries).toHaveLength(1);
    expect(summaries[0]).toContain("rejectedFrames=3");
  });

  it("attributes the burst to the frames that tripped the limiter", () => {
    client = makeClient();
    sendItems(client, 3);
    (client as any).handleTextMessage(RELAY_RATE_ERROR);
    (client as any).handleTextMessage(RELAY_RATE_ERROR);

    // The summary lands a second after the limiter bit, by which point the
    // sampling window has rolled past the frames that caused it. It has to
    // report what was sent at onset, not the silence that followed — otherwise
    // a flood-then-quiet agent reads as "sent nothing, got rate limited" and
    // sends the reader after the relay instead of the sender.
    (client as any).outboundFrameDiagnostics.length = 0;
    (client as any).finishRateLimitBurst();

    const summary = logLines().filter((l) => l.includes("burst summary"))[0];
    expect(summary).toContain("agent:item-added/control=3 frame(s)");
  });

  it("says so when the sample cap discards frames from the window", () => {
    client = makeClient();
    // Past MAX_OUTBOUND_DIAGNOSTIC_FRAMES: the cap drops the oldest half, all
    // of it still inside the window. Reporting the survivors as `total=` would
    // undercount by 2048 and read as the whole truth.
    sendItems(client, 4200);
    (client as any).handleTextMessage(RELAY_RATE_ERROR);

    const log = logLines()[0];
    expect(log).toContain("dropped=2048 frame(s)");
  });
});
