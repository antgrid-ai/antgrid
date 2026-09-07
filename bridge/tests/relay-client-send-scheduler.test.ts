// The send scheduler as the RelayClient wires it: what bypasses the queue
// (sealed session frames, relay JSON verbs) and what clears it. Sealing is the
// identity function here so a queued frame can be read straight off the wire.
import { afterEach, describe, expect, it } from "bun:test";
import { decodeRouteFrame, FrameKind } from "antgrid-wire";
import { RelayClient } from "../src/relay-client";
import { MessageBus } from "../src/message-bus";
import { createMessage } from "../src/protocol";
import type { SendScheduler } from "../src/send-scheduler";

const PHONE_ID = "phone-1";

interface Harness {
  client: RelayClient;
  sent: Array<string | Uint8Array>;
  s: SendScheduler;
}

let clients: RelayClient[] = [];
afterEach(() => { for (const c of clients.splice(0)) try { c.close(); } catch {} });

/** A paired, handshake-complete client whose socket collects frames and whose
 *  seal is the identity, so `sent` holds real route frames over readable
 *  plaintext. */
function makeClient(): Harness {
  const sent: Array<string | Uint8Array> = [];
  const client = new RelayClient({
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
  });
  clients.push(client);
  (client as any)._peerId = PHONE_ID;
  (client as any).established = {
    attemptId: "a1",
    peerId: PHONE_ID,
    transport: { seal: (plaintext: string) => Buffer.from(plaintext, "utf8") },
    sessionKeys: { a2p: Buffer.alloc(32), p2a: Buffer.alloc(32), confirm: Buffer.alloc(32) },
  };
  (client as any).ws = {
    readyState: WebSocket.OPEN,
    send: (d: string | Uint8Array) => sent.push(d),
    close: () => {},
  };
  return { client, sent, s: (client as any).scheduler as SendScheduler };
}

function decode(frame: string | Uint8Array): { channel: string; text: string } {
  const decoded = decodeRouteFrame(Buffer.from(frame as Uint8Array));
  const header = decoded.header as { channel?: string };
  return { channel: header.channel ?? "control", text: Buffer.from(decoded.payload).toString("utf8") };
}

function tunnelChunk(requestId: string): object {
  return {
    type: "tunnel:http-chunk",
    requestId,
    seq: 1,
    data: "ok",
    bodyEncoding: "base64",
  };
}

describe("RelayClient send scheduler", () => {
  it("writes a sealed session ping ahead of held preview frames", () => {
    const { client, sent, s } = makeClient();
    s.hold = true;

    for (const id of ["r1", "r2", "r3"]) void client.sendTunnel(tunnelChunk(id));
    expect(sent).toHaveLength(0);

    (client as any).lastSealedRecvAt = 0;
    (client as any).checkLiveness();

    // A tick writes both channels' credits beside the ping; every one of them
    // is a session frame, so all of them precede the held queue.
    const session = sent.map((f) => decode(f));
    expect(session.map((d) => d.channel)).toEqual(session.map(() => "control"));
    expect(session.map((d) => JSON.parse(d.text).type)).toContain("ping");

    s.hold = false;
    (client as any).drain();

    expect(sent).toHaveLength(session.length + 3);
    const drained = sent.slice(session.length).map((f) => decode(f));
    expect(drained.map((d) => d.channel)).toEqual(["preview", "preview", "preview"]);
    expect(drained.map((d) => JSON.parse(d.text).m.requestId)).toEqual(["r1", "r2", "r3"]);
  });

  it("writes the relay JSON heartbeat without touching the sealed queue", () => {
    const { client, sent, s } = makeClient();
    s.hold = true;
    void client.sendTunnel(tunnelChunk("r1"));
    void client.sendTunnel(tunnelChunk("r2"));

    (client as any).heartbeatTick();

    expect(sent).toEqual([JSON.stringify({ type: "ping" })]);
    expect(s.queued("preview").frames).toBe(2);
  });

  it("drops the queue when the socket closes", () => {
    const { client, sent, s } = makeClient();
    s.hold = true;
    for (const id of ["r1", "r2", "r3"]) void client.sendTunnel(tunnelChunk(id));
    expect(s.queued("preview").frames).toBe(3);

    client.close();

    expect(s.queued("preview").frames).toBe(0);
    expect(sent).toHaveLength(0);
  });

  it("drops a stream's queued frames when it detaches", () => {
    const { client, sent, s } = makeClient();
    const bus = new MessageBus();
    const handle = client.attachStream(bus, {});
    s.hold = true;

    bus.publish(createMessage("pong", {}), "control");
    bus.publish(createMessage("pong", {}), "control");
    expect(s.queued("control").frames).toBe(2);
    sent.length = 0;

    handle.detach();

    expect(s.queued("control").frames).toBe(0);
    expect(sent).toEqual([JSON.stringify({ type: "stream-close", streamId: handle.streamId })]);
  });

  it("drops the queue when the peer goes offline, keeping the session", () => {
    const { client, s } = makeClient();
    s.hold = true;
    void client.sendTunnel(tunnelChunk("r1"));
    void client.sendTunnel(tunnelChunk("r2"));
    expect(s.queued("preview").frames).toBe(2);

    (client as any).handleTextMessage(JSON.stringify({ type: "peer-offline", peerId: PHONE_ID }));

    expect(s.queued("preview").frames).toBe(0);
    expect(client.hasEstablishedSession).toBe(true);
  });

  // The pacing contract the tunnel's chunk loop rides on: the promise says when
  // the message LEFT the queue, and a cleared queue is a "dropped", not a hang.
  it("settles a queued frame when the hold lifts, and dropped when the queue is cleared first", async () => {
    const held = makeClient();
    held.s.hold = true;
    const sentPromise = held.client.sendTunnel(tunnelChunk("r1"));
    let settled: string | undefined;
    void sentPromise.then((o) => { settled = o; });
    await Promise.resolve();
    expect(settled).toBeUndefined();

    held.s.hold = false;
    (held.client as any).drain();
    expect(await sentPromise).toBe("sent");

    const cleared = makeClient();
    cleared.s.hold = true;
    const dropped = cleared.client.sendTunnel(tunnelChunk("r1"));
    cleared.client.close();
    expect(await dropped).toBe("dropped");
  });
});
