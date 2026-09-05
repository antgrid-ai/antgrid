import { afterEach, beforeEach, describe, expect, it, spyOn } from "bun:test";
import { encodeRouteFrame, FrameKind } from "antgrid-wire";
import { Netwatch, netwatch, frameIdFor, __resetNetwatchForTest, type NetwatchEvent } from "../src/netwatch";
import { ControlListener } from "../src/control-listener";
import { RelayClient } from "../src/relay-client";
import { createMessage } from "../src/protocol";
import { runNetwatchCli } from "../src/cli/netwatch";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

describe("Netwatch ring", () => {
  it("keeps the newest events, oldest first, and reports what it evicted", () => {
    const w = new Netwatch(3);
    for (let i = 0; i < 5; i++) {
      w.record({ dir: "tx", kind: "sealed", transport: "relay", msgType: `m${i}` });
    }
    expect(w.snapshot().map((e) => e.msgType)).toEqual(["m2", "m3", "m4"]);
    expect(w.recorded).toBe(5);
    // The blind spot has to be reportable — a capture that silently starts in
    // the middle reads as "nothing was sent before this".
    expect(w.evicted).toBe(2);
  });

  it("honours a snapshot limit smaller than the ring", () => {
    const w = new Netwatch(8);
    for (let i = 0; i < 5; i++) {
      w.record({ dir: "rx", kind: "sealed", transport: "relay", msgType: `m${i}` });
    }
    expect(w.snapshot(2).map((e) => e.msgType)).toEqual(["m3", "m4"]);
  });

  it("delivers to subscribers and survives one that throws", () => {
    const w = new Netwatch(4);
    const seen: string[] = [];
    w.subscribe(() => {
      throw new Error("watcher blew up");
    });
    const off = w.subscribe((e) => seen.push(e.msgType ?? ""));
    // A watcher is an observer; a broken one must never fail the send path.
    expect(() =>
      w.record({ dir: "tx", kind: "sealed", transport: "relay", msgType: "a" }),
    ).not.toThrow();
    off();
    w.record({ dir: "tx", kind: "sealed", transport: "relay", msgType: "b" });
    expect(seen).toEqual(["a"]);
  });
});

describe("frameIdFor", () => {
  it("uses the sealed frame's own nonce, which both endpoints see byte-identically", () => {
    const payload = Buffer.concat([Buffer.alloc(12, 0xab), Buffer.from("ciphertext")]);
    expect(frameIdFor(payload, true)).toBe("ab".repeat(12));
  });

  it("falls back to a hash for plaintext frames, which carry no nonce", () => {
    const id = frameIdFor(Buffer.from('{"type":"handshake:client-hello"}'), false);
    // Pinned, and pinned to the SAME string as `frameIdOf` in
    // packages/antgrid_relay_client/lib/src/frame.dart asserts for these bytes.
    // The two are hand-mirrored: if they drift, nothing fails except a --join
    // that quietly pairs nothing.
    expect(id).toBe("59e7c7d96c01d53688b362a9");
  });
});

/** A paired, handshake-complete client whose socket and seal are inert — the
 *  same seam relay-client-rate-diagnostics.test.ts uses. */
function makeClient(
  overrides: { open?: (b: Buffer) => string | null; readyState?: number } = {},
): RelayClient {
  const c = new RelayClient({
    url: "ws://127.0.0.1:1",
    identity: {
      deviceId: "dev-1",
      deviceName: "machine",
      createdAt: new Date().toISOString(),
      ed25519PublicKey: "pk",
      ed25519PrivateKey: "sk",
    },
    generateKeypair: () => {
      throw new Error("not used");
    },
    getLicenseToken: () => "token",
  });
  (c as any)._peerId = "phone-1";
  (c as any).established = {
    attemptId: "a1",
    transport: {
      seal: (plaintext: string) => Buffer.from(plaintext, "utf8"),
      open: overrides.open ?? (() => null),
    },
    sessionKeys: { a2p: Buffer.alloc(32), p2a: Buffer.alloc(32), confirm: Buffer.alloc(32) },
  };
  (c as any).ws = {
    readyState: overrides.readyState ?? WebSocket.OPEN,
    send: () => {},
    close: () => {},
  };
  return c;
}

const events = (): NetwatchEvent[] => netwatch.snapshot();

describe("RelayClient netwatch taps", () => {
  let client: RelayClient | null = null;

  beforeEach(() => __resetNetwatchForTest());
  afterEach(() => {
    client?.close();
    client = null;
    __resetNetwatchForTest();
  });

  it("records an outbound frame with its type, channel and nonce", () => {
    client = makeClient();
    client.sendOnChannel(createMessage("agent:turn-start", { sessionId: "s1", turnId: "t1" }), "control");

    const tx = events().filter((e) => e.dir === "tx" && e.kind === "sealed");
    expect(tx).toHaveLength(1);
    expect(tx[0].msgType).toBe("agent:turn-start");
    expect(tx[0].channel).toBe("control");
    expect(tx[0].transport).toBe("relay");
    expect(tx[0].bytes).toBeGreaterThan(0);
    expect(tx[0].frameId).toHaveLength(24);
  });

  it("records the send that logs nothing today: socket not open", () => {
    client = makeClient({ readyState: WebSocket.CLOSED });
    client.sendOnChannel(createMessage("agent:turn-start", { sessionId: "s1", turnId: "t1" }), "control");

    const drops = events().filter((e) => e.kind === "drop");
    expect(drops).toHaveLength(1);
    expect(drops[0].reason).toBe("socket-not-open");
    expect(drops[0].msgType).toBe("agent:turn-start");
  });

  it("records a send dropped for want of an E2E session", () => {
    client = makeClient();
    (client as any).established = null;
    client.sendOnChannel(createMessage("agent:turn-start", { sessionId: "s1", turnId: "t1" }), "control");

    const drops = events().filter((e) => e.kind === "drop");
    expect(drops).toHaveLength(1);
    expect(drops[0].reason).toBe("no-e2e-session");
  });

  it("carries the nonce down four calls so an inbound frame lands with its type", () => {
    // The threading is the fragile part: the id is only readable before
    // decrypt, the type only after it.
    const envelope = JSON.stringify({ s: "abc123def456", m: { type: "terminal:input", data: "x" } });
    client = makeClient({ open: () => envelope });

    const payload = Buffer.concat([Buffer.alloc(12, 0x7f), Buffer.from("sealed-bytes")]);
    const frame = encodeRouteFrame(
      { type: "message", from: "phone-1", channel: "control", ts: Date.now() },
      payload,
      FrameKind.sealed,
    );
    (client as any).handleBinaryFrame(Buffer.from(frame));

    const rx = events().filter((e) => e.dir === "rx" && e.kind === "sealed");
    expect(rx).toHaveLength(1);
    expect(rx[0].msgType).toBe("terminal:input");
    expect(rx[0].streamId).toBe("abc123def456");
    expect(rx[0].frameId).toBe("7f".repeat(12));
  });

  it("records a frame that arrived but would not decrypt", () => {
    client = makeClient({ open: () => null });
    const payload = Buffer.concat([Buffer.alloc(12, 0x01), Buffer.from("garbage")]);
    const frame = encodeRouteFrame(
      { type: "message", from: "phone-1", channel: "control", ts: Date.now() },
      payload,
      FrameKind.sealed,
    );
    (client as any).handleBinaryFrame(Buffer.from(frame));

    const drops = events().filter((e) => e.kind === "drop");
    expect(drops).toHaveLength(1);
    expect(drops[0].reason).toBe("decrypt-failed");
    expect(drops[0].frameId).toBe("01".repeat(12));
  });

  it("keeps the relay's own verbs, with the code that explains the stall", () => {
    client = makeClient();
    (client as any).handleTextMessage(
      JSON.stringify({
        type: "error",
        code: "MESSAGE_RATE_LIMITED",
        message: "slow down",
        retryable: true,
      }),
    );

    const control = events().filter((e) => e.kind === "control");
    expect(control).toHaveLength(1);
    expect(control[0].msgType).toBe("error");
    expect(control[0].detail).toMatchObject({ code: "MESSAGE_RATE_LIMITED", retryable: true });
  });
});

describe("control plane /netwatch", () => {
  let listener: ControlListener | null = null;

  beforeEach(() => __resetNetwatchForTest());
  afterEach(async () => {
    await listener?.stop();
    listener = null;
    __resetNetwatchForTest();
  });

  async function start(): Promise<{ port: number; token: string }> {
    const token = "test-token";
    listener = new ControlListener({
      token,
      handler: async () => ({ id: "x", ok: true, result: {} }) as any,
    });
    await listener.start();
    return { port: listener.port, token };
  }

  it("refuses a capture without the host token", async () => {
    const { port } = await start();
    const res = await fetch(`http://127.0.0.1:${port}/netwatch?follow=0`);
    expect(res.status).toBe(401);
  });

  it("replays the buffer and closes when not following", async () => {
    const { port, token } = await start();
    netwatch.record({ dir: "tx", kind: "sealed", transport: "relay", msgType: "agent:turn-start" });
    netwatch.record({ dir: "rx", kind: "drop", transport: "relay", reason: "decrypt-failed" });

    const res = await fetch(`http://127.0.0.1:${port}/netwatch?follow=0`, {
      headers: { authorization: `Bearer ${token}` },
    });
    expect(res.status).toBe(200);
    expect(res.headers.get("content-type")).toBe("text/event-stream");

    const body = await res.text();
    expect(body).toContain("agent:turn-start");
    expect(body).toContain("decrypt-failed");
    expect(body).toContain("event: replayed");
  });

  it("pushes frames recorded after the watcher attached", async () => {
    const { port, token } = await start();
    const res = await fetch(`http://127.0.0.1:${port}/netwatch?limit=0`, {
      headers: { authorization: `Bearer ${token}` },
    });
    expect(res.status).toBe(200);

    const reader = res.body!.getReader();
    const decoder = new TextDecoder();

    // Drain the replay marker first, so the read below can only see live traffic.
    let seen = "";
    while (!seen.includes("event: replayed")) {
      const { value, done } = await reader.read();
      if (done) throw new Error("stream closed before the replay marker");
      seen += decoder.decode(value, { stream: true });
    }

    netwatch.record({
      dir: "rx", kind: "control", transport: "relay", msgType: "peer-offline",
      detail: { peerId: "phone-1" },
    });

    let live = "";
    while (!live.includes("peer-offline")) {
      const { value, done } = await reader.read();
      if (done) throw new Error("stream closed before the live event arrived");
      live += decoder.decode(value, { stream: true });
    }
    expect(live).toContain("phone-1");
    await reader.cancel();
  });
});

describe("antgrid watch summary", () => {
  let listener: ControlListener | null = null;

  beforeEach(() => __resetNetwatchForTest());
  afterEach(async () => {
    await listener?.stop();
    listener = null;
    __resetNetwatchForTest();
  });

  it("strips escapes out of the type it tallies, and caps its length", async () => {
    const token = "summary-token";
    listener = new ControlListener({ token, handler: async () => ({ id: "x", ok: true, result: {} }) as any });
    await listener.start();

    const dir = mkdtempSync(join(tmpdir(), "netwatch-summary-"));
    writeFileSync(
      join(dir, "host.json"),
      JSON.stringify({
        version: 1,
        pid: process.pid,
        controlPort: listener.port,
        token,
        startedAt: new Date().toISOString(),
        agentVersion: "0.0.0-test",
      }),
    );

    // Built from char codes rather than written literally: a control character
    // pasted into a source file is invisible in every diff that would review it.
    const ESC = String.fromCharCode(27);
    const BEL = String.fromCharCode(7);
    netwatch.record({
      dir: "rx",
      kind: "sealed",
      transport: "relay",
      msgType: `terminal:${ESC}]0;pwned${BEL}${ESC}[2Kinput`,
    });
    netwatch.record({ dir: "tx", kind: "sealed", transport: "relay", msgType: "z".repeat(200) });

    const err = spyOn(console, "error").mockImplementation(() => {});
    const out = spyOn(console, "log").mockImplementation(() => {});
    let printed = "";
    try {
      expect(await runNetwatchCli({ dir, follow: false })).toBe(0);
      printed = err.mock.calls.flat().join("\n");
    } finally {
      out.mockRestore();
      err.mockRestore();
    }

    // The summary prints AFTER the rows have scrolled by, onto a terminal the
    // operator is reading — an OSC here retitles their window, a CSI repaints it.
    expect(printed).not.toContain(`${ESC}]`);
    expect(printed).not.toContain(`${ESC}[2K`);
    // Still counted, and still legible as the frame it was.
    expect(printed).toContain("rx terminal:]0;pwned[2Kinput 1");
    // One peer must not be able to push the other eleven rows off a ranked list
    // that only shows twelve.
    expect(printed).toContain(`tx ${"z".repeat(40)} 1`);
    expect(printed).not.toContain("z".repeat(41));
  });
});
