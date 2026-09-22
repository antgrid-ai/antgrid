// The send scheduler as the TestPeerSessionOwner wires it: what bypasses the
// queue and what clears it. Sealing is the identity function here so a queued
// peer frame can be read straight off the wire.
import { afterEach, describe, expect, it } from "bun:test";
import { decodePeerFrame, encodePeerFrame, FrameKind } from "antgrid-wire";
import { TestPeerSessionOwner } from "./test-peer-session-owner";
import { MessageBus } from "../src/message-bus";
import { createMessage } from "../src/protocol";
import type { SendScheduler } from "../src/send-scheduler";
import { installFakeSession } from "./fake-session";

const PHONE_ID = "phone-1";

interface Harness {
  client: TestPeerSessionOwner;
  sent: Array<string | Uint8Array>;
  s: SendScheduler;
}

let clients: TestPeerSessionOwner[] = [];
afterEach(() => { for (const c of clients.splice(0)) try { c.close(); } catch {} });

/** A paired, handshake-complete client whose socket collects frames and whose
 *  seal is the identity, so `sent` holds real peer frames over readable
 *  plaintext. */
function makeClient(): Harness {
  const sent: Array<string | Uint8Array> = [];
  const client = new TestPeerSessionOwner({
    identity: {
      deviceId: "dev-1",
      deviceName: "machine",
      createdAt: new Date().toISOString(),
      ed25519PublicKey: "pk",
      ed25519PrivateKey: "sk",
    },
    generateKeypair: () => { throw new Error("not used"); },
  });
  clients.push(client);
  const session = installFakeSession(client, PHONE_ID);
  client.setNativeWriter((data, to, channel = "control", kind = FrameKind.sealed) => {
    sent.push(encodePeerFrame({ type: "message", channel }, Buffer.from(data), kind));
    return true;
  });
  return { client, sent, s: session.scheduler as SendScheduler };
}

function decode(frame: string | Uint8Array): { channel: string; text: string } {
  const decoded = decodePeerFrame(Buffer.from(frame as Uint8Array));
  return { channel: decoded.header.channel, text: Buffer.from(decoded.payload).toString("utf8") };
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

describe("TestPeerSessionOwner send scheduler", () => {
  it("cancels only the addressed viewer's queued terminal frame", async () => {
    const { client, sent, s } = makeClient();
    const second = installFakeSession(client, "phone-2").scheduler as SendScheduler;
    s.hold = true;
    second.hold = true;
    const bus = new MessageBus();
    const handle = client.attachStream(bus, {});
    sent.length = 0;
    const controller = new AbortController();
    const status = createMessage("terminal:display:status", {
      terminalId: "t", code: "ACK_TIMEOUT", message: "Reconnect",
    });
    const delivery = bus.deliverTo(status, "preview", "relay", controller.signal, PHONE_ID);
    expect(s.queued("preview").frames).toBe(1);
    expect(second.queued("preview").frames).toBe(0);
    controller.abort();
    await delivery;
    // An aborted attachment deliberately retires without surfacing a send error.
    expect(s.queued("preview").frames).toBe(0);
    expect(sent).toEqual([]);
    handle.detach();
  });

  it("writes a sealed session ping ahead of held preview frames", () => {
    const { client, sent, s } = makeClient();
    s.hold = true;

    for (const id of ["r1", "r2", "r3"]) void client.sendTunnel(tunnelChunk(id));
    expect(sent).toHaveLength(0);

    (client as any).sessions.get(PHONE_ID).lastSealedRecvAt = 0;
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

  it("drops the queue when the native session owner closes", () => {
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
    expect(sent).toEqual([]);
  });

  it("drops the queue when the native peer session is retired", () => {
    const { client, s } = makeClient();
    s.hold = true;
    void client.sendTunnel(tunnelChunk("r1"));
    void client.sendTunnel(tunnelChunk("r2"));
    expect(s.queued("preview").frames).toBe(2);

    client.markPeerOffline(PHONE_ID);

    expect(s.queued("preview").frames).toBe(0);
    expect(client.hasEstablishedSession()).toBe(false);
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
