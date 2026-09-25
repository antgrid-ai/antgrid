// The send scheduler as the TestPeerSessionOwner wires it: what bypasses the
// queue and what clears it. Payloads are plaintext on the wire (Stage B), so a
// queued peer frame can be read straight off the wire with no unseal step.
//
// A4 moved bus-attached project traffic off this scheduler entirely — a
// project stream writes straight to its own bound QUIC stream
// (`ProjectStreamRegistry.writeToRecipients`), with no queue here to inspect.
// The session-stream (`CONTROL_STREAM_ID`) traffic this file exercises is
// untouched (kept through A5); cancel-isolation-between-viewers and
// detach-drops-the-queue coverage for the project stream itself now live in
// terminal-frame-cancellation.test.ts against a real binding.
import { afterEach, describe, expect, it } from "bun:test";
import { CONTROL_STREAM_ID, decodePeerFrame, encodePeerFrame } from "antgrid-wire";
import { TestPeerSessionOwner } from "./test-peer-session-owner";
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

/** A client with a session installed directly (past the hello with no
 *  connection run) whose socket collects frames, so `sent` holds real peer
 *  frames over readable plaintext. */
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
  });
  clients.push(client);
  const session = installFakeSession(client, PHONE_ID);
  client.setNativeWriter((data, to, channel = "control") => {
    sent.push(encodePeerFrame({ type: "message", channel }, Buffer.from(data)));
    return true;
  });
  return { client, sent, s: session.scheduler as SendScheduler };
}

function decode(frame: string | Uint8Array): { channel: string; text: string } {
  const decoded = decodePeerFrame(Buffer.from(frame as Uint8Array));
  return { channel: decoded.header.channel, text: Buffer.from(decoded.payload).toString("utf8") };
}

// A2 removed the tunnel-specific send wrapper; any preview-channel frame
// exercises the same scheduler path now that tunnel records ride their own
// stream instead of the bus (Stage A A3).
function previewFrame(requestId: string): object {
  return { type: "preview:test", requestId };
}

describe("TestPeerSessionOwner send scheduler", () => {
  it("writes a session ping ahead of held preview frames", () => {
    const { client, sent, s } = makeClient();
    s.hold = true;

    for (const id of ["r1", "r2", "r3"]) void (client as any).sendAppEnvelope(CONTROL_STREAM_ID, previewFrame(id), "preview");
    expect(sent).toHaveLength(0);

    (client as any).sessions.get(PHONE_ID).lastRecvAt = 0;
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
    for (const id of ["r1", "r2", "r3"]) void (client as any).sendAppEnvelope(CONTROL_STREAM_ID, previewFrame(id), "preview");
    expect(s.queued("preview").frames).toBe(3);

    client.close();

    expect(s.queued("preview").frames).toBe(0);
    expect(sent).toHaveLength(0);
  });

  it("drops the queue when the native peer session is retired", () => {
    const { client, s } = makeClient();
    s.hold = true;
    void (client as any).sendAppEnvelope(CONTROL_STREAM_ID, previewFrame("r1"), "preview");
    void (client as any).sendAppEnvelope(CONTROL_STREAM_ID, previewFrame("r2"), "preview");
    expect(s.queued("preview").frames).toBe(2);

    client.markPeerOffline(PHONE_ID);

    expect(s.queued("preview").frames).toBe(0);
    expect(client.hasEstablishedSession()).toBe(false);
  });

  // The pacing contract any preview-channel sender rides on: the promise says
  // when the message LEFT the queue, and a cleared queue is a "dropped", not a hang.
  it("settles a queued frame when the hold lifts, and dropped when the queue is cleared first", async () => {
    const held = makeClient();
    held.s.hold = true;
    const sentPromise = (held.client as any).sendAppEnvelope(CONTROL_STREAM_ID, previewFrame("r1"), "preview");
    let settled: string | undefined;
    void sentPromise.then((o: string) => { settled = o; });
    await Promise.resolve();
    expect(settled).toBeUndefined();

    held.s.hold = false;
    (held.client as any).drain();
    expect(await sentPromise).toBe("sent");

    const cleared = makeClient();
    cleared.s.hold = true;
    const dropped = (cleared.client as any).sendAppEnvelope(CONTROL_STREAM_ID, previewFrame("r1"), "preview");
    cleared.client.close();
    expect(await dropped).toBe("dropped");
  });
});
