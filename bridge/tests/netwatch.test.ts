import { afterEach, beforeEach, describe, expect, it, spyOn } from "bun:test";
import { createHash } from "node:crypto";
import { encodePeerFrame } from "antgrid-wire";
import { Netwatch, netwatch, frameIdFor, __resetNetwatchForTest, type NetwatchEvent } from "../src/netwatch";
import { ControlListener } from "../src/control-listener";
import { TestPeerSessionOwner } from "./test-peer-session-owner";
import { createMessage } from "../src/protocol";
import { runNetwatchCli, renderEvent } from "../src/cli/netwatch";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

describe("Netwatch ring", () => {
  it("keeps native lifecycle observations distinct from transmitted frames", () => {
    const w = new Netwatch(4);
    expect(w.ingestRemote([{ at: 1, seq: 1, dir: "event", kind: "lifecycle", transport: "iroh",
      msgType: "transport:selected", detail: { elapsedMs: 5 }, body: "untrusted" }])).toBe(1);
    const event = w.snapshot()[0]!;
    expect(event.bytes).toBeUndefined();
    expect(event.frameId).toBeUndefined();
    expect(event.body).toBeUndefined();
    const rendered = renderEvent(event);
    expect(rendered).toContain("iroh");
    expect(rendered).toContain("event");
    expect(rendered).not.toContain("relay");
    // `event` dir is only valid paired with `lifecycle` — any other kind is
    // the malformed row this admits zero of.
    expect(w.ingestRemote([{ at: 2, dir: "event", kind: "frame" }])).toBe(0);
  });
  it("keeps the newest events, oldest first, and reports what it evicted", () => {
    const w = new Netwatch(3);
    for (let i = 0; i < 5; i++) {
      w.record({ dir: "tx", kind: "frame", transport: "relay", msgType: `m${i}` });
    }
    expect(w.snapshot().map((e) => e.msgType)).toEqual(["m2", "m3", "m4"]);
    expect(w.recorded).toBe(5);
    // The blind spot has to be reportable â€” a capture that silently starts in
    // the middle reads as "nothing was sent before this".
    expect(w.evicted).toBe(2);
  });

  it("honours a snapshot limit smaller than the ring", () => {
    const w = new Netwatch(8);
    for (let i = 0; i < 5; i++) {
      w.record({ dir: "rx", kind: "frame", transport: "relay", msgType: `m${i}` });
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
      w.record({ dir: "tx", kind: "frame", transport: "relay", msgType: "a" }),
    ).not.toThrow();
    off();
    w.record({ dir: "tx", kind: "frame", transport: "relay", msgType: "b" });
    expect(seen).toEqual(["a"]);
  });
});

describe("frameIdFor", () => {
  it("hashes the frame payload bytes, so both endpoints compute the same id with no wire change", () => {
    const payload = Buffer.from('{"type":"session:hello","attemptId":"a1"}');
    // Pinned, and pinned to the SAME string `frameIdOf` in
    // packages/antgrid_relay_client/lib/src/frame.dart asserts for these bytes.
    // The two are hand-mirrored: if they drift, nothing fails except a --join
    // that quietly pairs nothing.
    expect(frameIdFor(payload)).toBe("1e65322bad672889949c1355");
  });

  it("gives byte-identical recurrences (a ping, say) the same id", () => {
    const a = Buffer.from(JSON.stringify({ type: "ping" }));
    const b = Buffer.from(JSON.stringify({ type: "ping" }));
    expect(frameIdFor(a)).toBe(frameIdFor(b));
  });
});

const events = (): NetwatchEvent[] => netwatch.snapshot();

describe("TestPeerSessionOwner netwatch taps", () => {
  let client: TestPeerSessionOwner | null = null;

  beforeEach(() => __resetNetwatchForTest());
  afterEach(() => {
    client?.close();
    client = null;
    __resetNetwatchForTest();
  });

  it("records a send dropped for want of an E2E session", () => {
    client = TestPeerSessionOwner.forTest({ sendPayload: () => {}, peerId: "phone-1", deviceId: "dev-1" });
    client.establish("phone-1", { attemptId: "a1" });
    (client as any).sessions.clear();
    client.sendOnChannel(createMessage("agent:turn-start", { sessionId: "s1", turnId: "t1" }), "control");

    const drops = events().filter((e) => e.kind === "drop");
    expect(drops).toHaveLength(1);
    expect(drops[0].reason).toBe("no-e2e-session");
  });

  it("classifies a received frame by its message type and its own payload hash", () => {
    client = TestPeerSessionOwner.forTest({ sendPayload: () => {}, peerId: "phone-1", deviceId: "dev-1" });
    client.establish("phone-1", { attemptId: "a1" });
    // establish() records its own hello's rx diagnostic; reset so this test
    // sees only the frame it injects below.
    __resetNetwatchForTest();

    const payload = Buffer.from(JSON.stringify({ type: "terminal:input", terminalId: "t", data: "x" }));
    const frame = encodePeerFrame({ type: "message" }, payload);
    client.injectPeerFrame(Buffer.from(frame), "phone-1");

    const rx = events().filter((e) => e.dir === "rx" && e.kind === "frame");
    expect(rx).toHaveLength(1);
    expect(rx[0].msgType).toBe("terminal:input");
    expect(rx[0].frameId).toBe(createHash("sha256").update(payload).digest("hex").slice(0, 24));
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
    netwatch.record({ dir: "tx", kind: "frame", transport: "relay", msgType: "agent:turn-start" });
    netwatch.record({ dir: "rx", kind: "drop", transport: "relay", reason: "pre-establishment" });

    const res = await fetch(`http://127.0.0.1:${port}/netwatch?follow=0`, {
      headers: { authorization: `Bearer ${token}` },
    });
    expect(res.status).toBe(200);
    expect(res.headers.get("content-type")).toBe("text/event-stream");

    const body = await res.text();
    expect(body).toContain("agent:turn-start");
    expect(body).toContain("pre-establishment");
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
      kind: "frame",
      transport: "relay",
      msgType: `terminal:${ESC}]0;pwned${BEL}${ESC}[2Kinput`,
    });
    netwatch.record({ dir: "tx", kind: "frame", transport: "relay", msgType: "z".repeat(200) });

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
    // operator is reading â€” an OSC here retitles their window, a CSI repaints it.
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
