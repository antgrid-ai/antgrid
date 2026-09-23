// Credit windows as the TestPeerSessionOwner runs them: what the gate holds back, what
// a cumulative credit releases, what the receive path counts, and what a relay
// drop report reopens. Payloads are plaintext now (Stage B), so every byte
// count asserted here is the plaintext length that goes on the wire.
import { afterAll, afterEach, beforeEach, describe, expect, it } from "bun:test";
import { randomBytes } from "node:crypto";
import { WINDOW_RESYNC_AGE_MS } from "antgrid-wire";
import { TestPeerSessionOwner } from "./test-peer-session-owner";
import { createMessage } from "../src/protocol";
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

let clients: TestPeerSessionOwner[] = [];
let logLines: string[] = [];

beforeEach(() => {
  logLines = [];
  // pino writes JSONL straight to its destination, bypassing console.*.
  __setRootForTest({ write(s: string): boolean { logLines.push(s); return true; } }, "debug");
});
afterEach(() => { for (const c of clients.splice(0)) try { c.close(); } catch {} });
afterAll(() => __setRootForTest(process.stdout));

/** Inject a raw payload from `from` exactly as it would arrive on the wire —
 *  used for bytes that are deliberately not valid JSON, which `sendFromPeer`
 *  (string|object only) cannot express. */
function injectRaw(client: TestPeerSessionOwner, payload: Buffer, channel: "control" | "preview" = "control", from: string = PHONE_ID): void {
  client.injectPeerPayload(payload, from, channel);
}

/** Send one plaintext control/app-plane message from the phone through the
 *  seam. Returns its UTF-8 byte length, exactly the number the receiver
 *  counts and the sender charges. */
function injectPlain(
  client: TestPeerSessionOwner,
  plaintext: string,
  channel: "control" | "preview" = "control",
  from: string = PHONE_ID,
): number {
  client.sendFromPeer(from, plaintext, channel);
  return Buffer.byteLength(plaintext, "utf8");
}

function parse(frame: Frame): any {
  return JSON.parse(typeof frame === "string" ? frame : frame.toString("utf8"));
}

interface Harness {
  client: TestPeerSessionOwner;
  sent: Frame[];
  readonly s: SendScheduler;
  readonly session: { lastRecvAt: number; rxFlow: { consumed: Record<string, number> } };
}

function sessionOf(client: TestPeerSessionOwner, peerId = PHONE_ID): any {
  return (client as any).sessions.get(peerId);
}

/** Re-applied on every read: a fresh session installs a scheduler at
 *  production defaults, which would put the window far out of this file's
 *  reach. */
function applyLimits(s: SendScheduler): SendScheduler {
  s.limits.window = WINDOW;
  s.limits.socketCap = SOCKET_CAP;
  return s;
}

function establish(): Harness {
  const sent: Frame[] = [];
  const client = TestPeerSessionOwner.forTest({
    sendPayload: (p) => sent.push(p),
    peerId: PHONE_ID,
    deviceId: AGENT_DEVICE_ID,
    creditBatchBytes: CREDIT_BATCH,
  });
  clients.push(client);
  client.establish(PHONE_ID, { attemptId: "a1" });
  expect(client._handshakeComplete()).toBe(true);
  applyLimits(sessionOf(client).scheduler as SendScheduler);
  return {
    client, sent,
    get s(): SendScheduler { return applyLimits(sessionOf(client).scheduler as SendScheduler); },
    get session() { return sessionOf(client); },
  };
}

function tunnelChunk(requestId: string): object {
  return {
    type: "tunnel:http-chunk",
    requestId,
    seq: 1,
    data: "x".repeat(BODY),
    bodyEncoding: "base64",
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
  for (let i = 0; i < 5; i++) void h.client.sendTunnel(tunnelChunk(`r${i}`));
  const written = h.sent.slice(at) as Buffer[];
  expect(written).toHaveLength(3);
  expect(h.s.queued("preview").frames).toBe(2);
  return { at, written };
}

const sum = (frames: Buffer[]): number => frames.reduce((n, f) => n + f.length, 0);

describe("TestPeerSessionOwner credit windows", () => {
  it("stops at the window and resumes on a cumulative credit", () => {
    const h = establish();
    const { at, written } = fillWindow(h);
    expect(h.s.unacked("preview")).toBe(sum(written));

    // Control has its own window, so a full preview channel never holds it up.
    h.client.sendOnChannel(createMessage("agent:turn-start", { sessionId: "s1", turnId: "t1" }), "control");
    expect(h.sent).toHaveLength(at + 4);

    injectPlain(h.client, JSON.stringify({ type: "credit", channel: "preview", consumed: sum(written) }));

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
    injectPlain(h.client, JSON.stringify({ type: "credit", channel: "preview", consumed: f0.length }));
    expect(h.s.queued("preview").frames).toBe(1);

    injectPlain(h.client, JSON.stringify({
      type: "credit", channel: "preview", consumed: f0.length + f1.length + f2.length,
    }));
    expect(h.s.queued("preview").frames).toBe(0);
  });

  it("releases nothing on a stale or duplicate credit", () => {
    const h = establish();
    fillWindow(h);
    const credit = (consumed: number) =>
      injectPlain(h.client, JSON.stringify({ type: "credit", channel: "preview", consumed }));

    // Advancing, but nowhere near enough to fit the head.
    credit(1);
    expect(h.s.queued("preview").frames).toBe(2);
    // Stale: below the highest cumulative figure already accepted.
    credit(0);
    expect(h.s.queued("preview").frames).toBe(2);
    // Repeats never move the window on their own; only age does, exercised
    // below.
    credit(2);
    credit(2);
    expect(h.s.queued("preview").frames).toBe(2);
  });

  it("credits per batch of consumed bytes, counting unparseable and session frames", () => {
    const h = establish();
    let at = h.sent.length;

    const a = injectPlain(h.client, envelope(40_000), "preview");
    const b = injectPlain(h.client, envelope(40_000), "preview");
    expect(h.sent).toHaveLength(at);
    const c = injectPlain(h.client, envelope(40_000), "preview");

    expect(parse(h.sent[at]!)).toEqual({ type: "credit", channel: "preview", consumed: a + b + c });
    at = h.sent.length;

    // A frame nothing can parse was still charged by its sender; leaving it
    // out would shrink that channel's window for the rest of the session.
    const junk = randomBytes(40_000);
    injectRaw(h.client, junk, "preview");
    const d = injectPlain(h.client, envelope(60_000), "preview");

    expect(parse(h.sent[at]!)).toEqual({
      type: "credit", channel: "preview", consumed: a + b + c + junk.length + d,
    });

    const ping = injectPlain(h.client, JSON.stringify({ type: "ping" }), "control");
    expect(parse(h.sent[h.sent.length - 1]!)).toEqual({ type: "pong" });
    expect(h.session.rxFlow.consumed.control).toBe(ping);
  });

  it("re-sends both credits every liveness tick, and a credit refreshes liveness", () => {
    const h = establish();
    const consumed = injectPlain(h.client, envelope(10_000), "preview");
    const expected = [
      { type: "credit", channel: "control", consumed: 0 },
      { type: "credit", channel: "preview", consumed },
    ];

    // Healthy silence window: no ping is due, the credits go anyway.
    let at = h.sent.length;
    h.session.lastRecvAt = Date.now();
    (h.client as any).checkLiveness();
    expect((h.sent.slice(at) as Buffer[]).map((f) => parse(f))).toEqual(expected);

    at = h.sent.length;
    h.session.lastRecvAt = Date.now();
    (h.client as any).checkLiveness();
    expect((h.sent.slice(at) as Buffer[]).map((f) => parse(f))).toEqual(expected);
    h.session.lastRecvAt = 0;
    injectPlain(h.client, JSON.stringify({ type: "credit", channel: "preview", consumed: 1 }));
    expect(Date.now() - h.session.lastRecvAt).toBeLessThan(1000);
  });

  it("charges session frames without gating them", () => {
    const h = establish();
    fillWindow(h);
    const at = h.sent.length;
    const before = h.s.unacked("control");

    h.session.lastRecvAt = 0;
    (h.client as any).checkLiveness();

    const written = h.sent.slice(at) as Buffer[];
    expect(written.map((f) => parse(f).type)).toContain("ping");
    expect(h.s.unacked("control") - before).toBe(sum(written));
    expect(h.s.queued("preview").frames).toBe(2);
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

  it("resyncs a wedged channel once a credit two ticks on still counts nothing", () => {
    const h = establish();
    fillWindow(h);
    let clock = 1_000;
    h.s.now = () => clock;
    const credit = () =>
      injectPlain(h.client, JSON.stringify({ type: "credit", channel: "preview", consumed: 0 }));

    credit();
    clock += WINDOW_RESYNC_AGE_MS - 1;
    credit();
    expect(h.s.queued("preview").frames).toBe(2);

    clock += 1;
    credit();
    expect(h.s.queued("preview").frames).toBe(0);
    expect(h.s.unacked("preview")).toBeGreaterThan(0);
    expect(logLines.filter((l) => l.includes("window resync on preview"))).toHaveLength(1);
  });

  it("a different attemptId while established drops the session and its held window", () => {
    const h = establish();
    fillWindow(h);

    // Same peer, new attemptId, still on the same (test) connection: a
    // protocol violation. The base class's `refusePeer` tears the session
    // down — queued frames die with it rather than surviving into a "new"
    // session, since there is no longer a rekey that carries a backlog over.
    h.client.injectPeerPayload(
      Buffer.from(JSON.stringify({ type: "session:hello", attemptId: "a2" })),
      PHONE_ID,
    );

    expect(h.client.peerSession(PHONE_ID)).toBeNull();
  });

  it("leaves a busy device's window alone when a SECOND device sends its hello", () => {
    const h = establish();
    const { written } = fillWindow(h);

    h.client.establish(PHONE_2_ID, { attemptId: "b1" });

    expect(h.client.peerSession(PHONE_ID)).not.toBeNull();
    expect(h.client.peerSession(PHONE_2_ID)).not.toBeNull();
    expect(h.s.queued("preview").frames).toBe(2);
    expect(h.s.unacked("preview")).toBe(sum(written));
  });
});
