// Credit windows as the RelayClient runs them: what the gate holds back, what
// a cumulative credit releases, what the receive path counts, and what a relay
// drop report reopens. Real E2E keys throughout, so every byte count asserted
// here is the count that goes on the wire.
import { afterAll, afterEach, beforeEach, describe, expect, it } from "bun:test";
import { generateKeyPairSync, randomBytes } from "node:crypto";
import { encodeRouteFrame, FrameKind } from "antgrid-wire";
import { RelayClient } from "../src/relay-client";
import { createMessage } from "../src/protocol";
import { generateEphemeralKeypair, deriveSharedSecret } from "../src/key-exchange";
import {
  buildTranscript, deriveSessionKeys, phoneConfirmTag, E2eTransport, signTranscript,
} from "../src/e2e";
import { __setRootForTest } from "../src/logger";
import type { SendScheduler } from "../src/send-scheduler";

const AGENT_DEVICE_ID = "agent-1";
const PHONE_ID = "phone-1";
const PHONE_2_ID = "phone-2";
/** Shrunk from the shipped 2 MiB / 3 MiB / 512 KiB so these move kilobytes
 *  instead of megabytes; the arithmetic under test is unchanged. */
const WINDOW = 200_000;
const SOCKET_CAP = 300_000;
const CREDIT_BATCH = 100_000;
/** Three of these fit the window and a fourth does not, which is what makes
 *  "exactly three went out" a statement about the gate. */
const BODY = 50_000;

type Frame = string | Buffer;

let clients: RelayClient[] = [];
let logLines: string[] = [];

beforeEach(() => {
  logLines = [];
  // pino writes JSONL straight to its destination, bypassing console.*.
  __setRootForTest({ write(s: string): boolean { logLines.push(s); return true; } }, "debug");
});
afterEach(() => { for (const c of clients.splice(0)) try { c.close(); } catch {} });
afterAll(() => __setRootForTest(process.stdout));

function ed25519Pair(): { seedB64: string; pubB64: string } {
  const { publicKey, privateKey } = generateKeyPairSync("ed25519");
  return {
    seedB64: Buffer.from(privateKey.export({ format: "der", type: "pkcs8" }).subarray(-32)).toString("base64"),
    pubB64: Buffer.from(publicKey.export({ format: "der", type: "spki" }).subarray(-32)).toString("base64"),
  };
}

function injectFrame(
  client: RelayClient,
  kind: FrameKind,
  payload: Buffer,
  channel: "control" | "preview" = "control",
  from: string = PHONE_ID,
): void {
  const frame = encodeRouteFrame({ type: "message", from, channel }, payload, kind);
  (client as any).handleBinaryFrame(Buffer.from(frame));
}

/** Seal one plaintext as the phone and feed it in. Returns the sealed length —
 *  exactly the number the receiver counts and the sender charged. */
function injectSealed(
  client: RelayClient,
  phone: E2eTransport,
  plaintext: string,
  channel: "control" | "preview" = "control",
  from: string = PHONE_ID,
): number {
  const sealed = phone.seal(plaintext);
  injectFrame(client, FrameKind.sealed, sealed, channel, from);
  return sealed.length;
}

function open(phone: E2eTransport, frame: Frame): any {
  const plaintext = phone.open(frame as Buffer);
  if (plaintext === null) throw new Error("frame did not open under the phone's keys");
  return JSON.parse(plaintext);
}

/** Drive one client-hello, agent-hello, app:ready exchange and return the
 *  phone-side transport for the session it establishes. */
function handshake(
  client: RelayClient,
  sent: Frame[],
  opts: { attemptId: string; phoneEd: { seedB64: string }; phoneId: string; nonce: Buffer },
): E2eTransport {
  const app = generateEphemeralKeypair();
  const shared = {
    registrationId: AGENT_DEVICE_ID,
    agentDeviceId: AGENT_DEVICE_ID,
    phoneDeviceId: opts.phoneId,
    phoneX25519Pub: app.publicKey,
    nonce: opts.nonce,
  };
  const sig = signTranscript(
    buildTranscript({ ...shared, role: "phone", agentX25519Pub: Buffer.alloc(0) }),
    Buffer.from(opts.phoneEd.seedB64, "base64"),
  );
  const helloAt = sent.length;
  injectFrame(
    client,
    FrameKind.handshake,
    Buffer.from(JSON.stringify({
      type: "handshake:client-hello",
      attemptId: opts.attemptId,
      pubkey: app.publicKey.toString("base64"),
      nonce: opts.nonce.toString("base64"),
      sig,
    })),
    "control",
    opts.phoneId,
  );

  const agentPubkey = Buffer.from(JSON.parse(sent[helloAt] as string).pubkey, "base64");
  const keys = deriveSessionKeys(
    deriveSharedSecret(app.privateKey, agentPubkey),
    buildTranscript({ ...shared, role: "agent", agentX25519Pub: agentPubkey }),
  );
  const phone = new E2eTransport({ sendKey: keys.p2a, recvKey: keys.a2p });
  injectSealed(
    client,
    phone,
    JSON.stringify({
      type: "app:ready",
      attemptId: opts.attemptId,
      confirm: phoneConfirmTag(keys.confirm).toString("base64"),
    }),
    "control",
    opts.phoneId,
  );
  return phone;
}

interface Harness {
  client: RelayClient;
  sent: Frame[];
  phone: E2eTransport;
  s: SendScheduler;
  agentEd: { seedB64: string; pubB64: string };
  phoneEd: { seedB64: string; pubB64: string };
}

function establish(): Harness {
  const agentEd = ed25519Pair();
  const phoneEd = ed25519Pair();
  const sent: Frame[] = [];
  const client = RelayClient.forTest({
    generateKeypair: generateEphemeralKeypair,
    sendPayload: (p) => sent.push(p),
    peerId: PHONE_ID,
    deviceId: AGENT_DEVICE_ID,
    agentEd25519PrivB64: agentEd.seedB64,
    phoneEd25519PubB64: phoneEd.pubB64,
    creditBatchBytes: CREDIT_BATCH,
  });
  clients.push(client);
  const phone = handshake(client, sent, {
    attemptId: "a1", phoneEd, phoneId: PHONE_ID, nonce: Buffer.from([1, 2, 3, 4, 5, 6, 7, 8]),
  });
  expect(client._handshakeComplete()).toBe(true);
  const s = (client as any).scheduler as SendScheduler;
  s.limits.window = WINDOW;
  s.limits.socketCap = SOCKET_CAP;
  return { client, sent, phone, s, agentEd, phoneEd };
}

function tunnelResponse(requestId: string): object {
  return {
    type: "tunnel:http-response",
    requestId,
    status: 200,
    headers: {},
    body: "x".repeat(BODY),
    bodyEncoding: "utf8",
  };
}

/** A control-plane envelope whose plaintext is exactly `bytes` long. */
function envelope(bytes: number): string {
  const msg = createMessage("terminal:input", { terminalId: "t1", data: "" });
  const pad = bytes - JSON.stringify({ m: msg }).length;
  return JSON.stringify({ m: { ...msg, data: "x".repeat(pad) } });
}

/** Fill the preview window: five bodies queued, three of which fit. */
function fillWindow(h: Harness): { at: number; written: Buffer[] } {
  const at = h.sent.length;
  for (let i = 0; i < 5; i++) h.client.sendTunnel(tunnelResponse(`r${i}`));
  const written = h.sent.slice(at) as Buffer[];
  expect(written).toHaveLength(3);
  expect(h.s.queued("preview").frames).toBe(2);
  return { at, written };
}

const sum = (frames: Buffer[]): number => frames.reduce((n, f) => n + f.length, 0);

describe("RelayClient credit windows", () => {
  it("stops at the window and resumes on a cumulative credit", () => {
    const h = establish();
    const { at, written } = fillWindow(h);
    expect(h.s.unacked("preview")).toBe(sum(written));

    // Control has its own window, so a full preview channel never holds it up.
    h.client.sendOnChannel(createMessage("agent:turn-start", { sessionId: "s1", turnId: "t1" }), "control");
    expect(h.sent).toHaveLength(at + 4);

    injectSealed(h.client, h.phone, JSON.stringify({ type: "credit", channel: "preview", consumed: sum(written) }));

    const preview = (h.sent.slice(at) as Buffer[]).filter((f) => f.length > 1000);
    expect(preview).toHaveLength(5);
    expect(h.s.queued("preview").frames).toBe(0);
  });

  it("heals a lost credit with the next cumulative one", () => {
    const h = establish();
    const { written } = fillWindow(h);
    const [f0, f1, f2] = written;

    // The peer credits cumulatively, so a value in the middle can go missing
    // entirely and the next one still releases everything up to it.
    injectSealed(h.client, h.phone, JSON.stringify({ type: "credit", channel: "preview", consumed: f0.length }));
    expect(h.s.queued("preview").frames).toBe(1);

    injectSealed(h.client, h.phone, JSON.stringify({
      type: "credit", channel: "preview", consumed: f0.length + f1.length + f2.length,
    }));
    expect(h.s.queued("preview").frames).toBe(0);
  });

  it("releases nothing on a stale or duplicate credit", () => {
    const h = establish();
    fillWindow(h);
    const credit = (consumed: number) =>
      injectSealed(h.client, h.phone, JSON.stringify({ type: "credit", channel: "preview", consumed }));

    // Advancing, but nowhere near enough to fit the head.
    credit(1);
    expect(h.s.queued("preview").frames).toBe(2);
    // Stale: below the highest cumulative figure already accepted.
    credit(0);
    expect(h.s.queued("preview").frames).toBe(2);
    // An advancing credit in between keeps the two non-advancing ones from
    // being consecutive; consecutive is the resync signal, exercised below.
    credit(2);
    credit(2);
    expect(h.s.queued("preview").frames).toBe(2);
  });

  it("credits per batch of consumed bytes, counting undecryptable and session frames", () => {
    const h = establish();
    let at = h.sent.length;

    const a = injectSealed(h.client, h.phone, envelope(40_000), "preview");
    const b = injectSealed(h.client, h.phone, envelope(40_000), "preview");
    expect(h.sent).toHaveLength(at);
    const c = injectSealed(h.client, h.phone, envelope(40_000), "preview");

    expect(open(h.phone, h.sent[at]!)).toEqual({ type: "credit", channel: "preview", consumed: a + b + c });
    at = h.sent.length;

    // A frame nothing can open was still charged by its sender; leaving it out
    // would shrink that channel's window for the rest of the session.
    const junk = randomBytes(40_000);
    injectFrame(h.client, FrameKind.sealed, junk, "preview");
    const d = injectSealed(h.client, h.phone, envelope(60_000), "preview");

    expect(open(h.phone, h.sent[at]!)).toEqual({
      type: "credit", channel: "preview", consumed: a + b + c + junk.length + d,
    });

    const ping = injectSealed(h.client, h.phone, JSON.stringify({ type: "ping" }), "control");
    expect(open(h.phone, h.sent[h.sent.length - 1]!)).toEqual({ type: "pong" });
    expect((h.client as any).rxFlow.consumed.control).toBe(ping);
  });

  it("re-sends both credits every liveness tick, and a credit refreshes liveness", () => {
    const h = establish();
    const consumed = injectSealed(h.client, h.phone, envelope(10_000), "preview");
    const expected = [
      { type: "credit", channel: "control", consumed: 0 },
      { type: "credit", channel: "preview", consumed },
    ];

    // Healthy silence window: no ping is due, the credits go anyway.
    let at = h.sent.length;
    (h.client as any).lastSealedRecvAt = Date.now();
    (h.client as any).checkLiveness();
    expect((h.sent.slice(at) as Buffer[]).map((f) => open(h.phone, f))).toEqual(expected);

    at = h.sent.length;
    (h.client as any).lastSealedRecvAt = Date.now();
    (h.client as any).checkLiveness();
    expect((h.sent.slice(at) as Buffer[]).map((f) => open(h.phone, f))).toEqual(expected);

    (h.client as any).awaitingPong = true;
    (h.client as any).lastSealedRecvAt = 0;
    injectSealed(h.client, h.phone, JSON.stringify({ type: "credit", channel: "preview", consumed: 1 }));

    expect((h.client as any).awaitingPong).toBe(false);
    expect(Date.now() - (h.client as any).lastSealedRecvAt).toBeLessThan(1000);
  });

  it("charges session frames without gating them", () => {
    const h = establish();
    fillWindow(h);
    const at = h.sent.length;
    const before = h.s.unacked("control");

    (h.client as any).lastSealedRecvAt = 0;
    (h.client as any).checkLiveness();

    const written = h.sent.slice(at) as Buffer[];
    expect(written.map((f) => open(h.phone, f).type)).toContain("ping");
    expect(h.s.unacked("control") - before).toBe(sum(written));
    expect(h.s.queued("preview").frames).toBe(2);
  });

  it("reopens the window when the relay reports a dropped frame", () => {
    const h = establish();
    const { written } = fillWindow(h);

    (h.client as any).handleTextMessage(JSON.stringify({
      type: "error",
      code: "MESSAGE_RATE_LIMITED",
      message: "Message rate limit exceeded",
      retryable: true,
      channel: "preview",
      bytes: written[0].length,
    }));

    expect(h.s.queued("preview").frames).toBe(1);
  });

  it("coalesces a burst of routing failures into one report", () => {
    const h = establish();
    const surfaced: string[] = [];
    (h.client as any).opts.onError = (code: string) => surfaced.push(code);

    for (let i = 0; i < 3; i++) {
      (h.client as any).handleTextMessage(JSON.stringify({
        type: "error", code: "ROUTE_FAILED", message: "Recipient backlogged", retryable: true,
      }));
    }

    expect(surfaced).toEqual(["ROUTE_FAILED"]);
    expect(logLines.filter((l) => l.includes("Relay dropped frames"))).toHaveLength(1);
  });

  it("logs a stalled channel once", () => {
    const h = establish();
    fillWindow(h);
    const stalled = () => logLines.filter((l) => l.includes("Send gate stalled on preview"));

    // Back-date the block so the warn threshold is reached without waiting it out.
    h.s.blockedSince.preview = Date.now() - 6_000;
    (h.client as any).drain();
    expect(stalled()).toHaveLength(1);

    (h.client as any).drain();
    expect(stalled()).toHaveLength(1);
  });

  it("resyncs a wedged channel after two non-advancing credits", () => {
    const h = establish();
    fillWindow(h);
    const credit = () =>
      injectSealed(h.client, h.phone, JSON.stringify({ type: "credit", channel: "preview", consumed: 0 }));

    credit();
    expect(h.s.queued("preview").frames).toBe(2);

    credit();
    expect(h.s.queued("preview").frames).toBe(0);
    expect(h.s.unacked("preview")).toBeGreaterThan(0);
    expect(logLines.filter((l) => l.includes("window resync on preview"))).toHaveLength(1);
  });

  it("drops held frames and resets both windows on a same-device rekey", () => {
    const h = establish();
    fillWindow(h);
    const at = h.sent.length;

    const phone2 = handshake(h.client, h.sent, {
      attemptId: "a2", phoneEd: h.phoneEd, phoneId: PHONE_ID, nonce: Buffer.from([2, 2, 2, 2, 2, 2, 2, 2]),
    });

    // agent-hello, agent-ready, established and nothing behind them: the phone
    // re-syncs from the snapshot, so a stale backlog would only sit ahead of
    // the adverts it needs first.
    const written = h.sent.slice(at);
    expect(written).toHaveLength(3);
    const established = written[2] as Buffer;
    expect(open(phone2, established)).toEqual({ type: "established", attemptId: "a2" });
    expect(h.s.queued("preview").frames).toBe(0);
    expect(h.s.unacked("preview")).toBe(0);
    // The ack itself is the only thing charged on the fresh session.
    expect(h.s.unacked("control")).toBe(established.length);
  });

  it("drops everything when a different device takes the session over", () => {
    const h = establish();
    fillWindow(h);
    const phone2Ed = ed25519Pair();
    (h.client as any).phoneEd25519ByDeviceId.set(PHONE_2_ID, phone2Ed.pubB64);

    const app = generateEphemeralKeypair();
    const nonce = Buffer.from([7, 7, 7, 7, 7, 7, 7, 7]);
    const sig = signTranscript(
      buildTranscript({
        registrationId: AGENT_DEVICE_ID, role: "phone", agentDeviceId: AGENT_DEVICE_ID,
        phoneDeviceId: PHONE_2_ID, agentX25519Pub: Buffer.alloc(0), phoneX25519Pub: app.publicKey, nonce,
      }),
      Buffer.from(phone2Ed.seedB64, "base64"),
    );
    injectFrame(
      h.client,
      FrameKind.handshake,
      Buffer.from(JSON.stringify({
        type: "handshake:client-hello", attemptId: "b1",
        pubkey: app.publicKey.toString("base64"), nonce: nonce.toString("base64"), sig,
      })),
      "control",
      PHONE_2_ID,
    );

    expect((h.client as any).established).toBeNull();
    expect(h.s.queued("preview").frames).toBe(0);
    expect(h.s.unacked("preview")).toBe(0);
  });
});
