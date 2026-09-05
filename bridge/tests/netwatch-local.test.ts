// The bridge's half of `antgrid watch --local`: what the LocalListener records
// for the loopback socket the desktop app rides.
//
// Loopback is point-to-point with no relay in between, so this ONE side sees
// the whole wire — every frame `deliver()` sends is one the app received, and
// every frame reaching `handleFrame()` is one the app sent. The tests therefore
// drive a real listener over a real socket rather than asserting hand-built
// events: what is being checked is that both halves of a round trip land in the
// ring describing the SAME frame.
import { afterEach, beforeEach, describe, expect, it, spyOn } from "bun:test";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { LocalListener } from "../src/local-listener";
import { MessageBus } from "../src/message-bus";
import { createMessage } from "../src/protocol";
import {
  armBodyCapture,
  isBodyCaptureArmed,
  netwatch,
  NETWATCH_BODY_MAX_CHARS,
  __resetNetwatchForTest,
  type NetwatchEvent,
} from "../src/netwatch";
import { renderEvent, runNetwatchCli } from "../src/cli/netwatch";

/** Recognisable on sight in any recorded value — this is the shared secret that
 *  guards the loopback socket, and the whole point of one test below is that it
 *  never reaches the ring. */
const TOKEN = "l00pback-shared-secret-8f31c2";
const PROJECT = "netwatch-local-proj";

let listener: LocalListener;
let bus: MessageBus;

beforeEach(async () => {
  __resetNetwatchForTest();
  bus = new MessageBus();
  listener = new LocalListener({ bus, token: TOKEN, projectId: PROJECT });
  await listener.start();
});

afterEach(async () => {
  await listener.stop();
  __resetNetwatchForTest();
});

/** Only this file's traffic: the ring is process-global and the suite shares one
 *  module cache, so a sibling spec's relay events sit in the same buffer. */
const allLocal = (): NetwatchEvent[] => netwatch.snapshot().filter((e) => e.transport === "local");

/** The data plane alone. Every `connectOwner()` also records the accepted hello
 *  and its `ready` answer, so a frame assertion that counted those would be
 *  measuring the fixture rather than the behaviour under test. */
const local = (): NetwatchEvent[] => allLocal().filter((e) => e.kind !== "handshake");

async function connectOwner(): Promise<WebSocket> {
  const ws = new WebSocket(`ws://127.0.0.1:${listener.port}`);
  await new Promise<void>((resolve, reject) => {
    ws.onopen = () => resolve();
    ws.onerror = (e) => reject(e);
  });
  ws.send(JSON.stringify({ type: "hello", token: TOKEN, appPid: 4242, appVersion: "test" }));
  await nextText(ws); // ready
  return ws;
}

function nextText(ws: WebSocket): Promise<string> {
  return new Promise((resolve) => {
    ws.onmessage = (ev) => resolve(String(ev.data));
  });
}

function nextClose(ws: WebSocket): Promise<number> {
  return new Promise((resolve) => {
    ws.onclose = (ev) => resolve(ev.code);
  });
}

/** An inbound frame is recorded on the bridge's own turn of the loop, not the
 *  sender's, so every rx assertion has to wait for one. */
async function untilLocal(count: number): Promise<NetwatchEvent[]> {
  const deadline = Date.now() + 2_000;
  for (;;) {
    const seen = local();
    if (seen.length >= count) return seen;
    if (Date.now() > deadline) {
      throw new Error(`timed out waiting for ${count} loopback events; saw ${JSON.stringify(seen)}`);
    }
    await new Promise((r) => setTimeout(r, 5));
  }
}

describe("LocalListener netwatch taps", () => {
  it("records the accepted hello and its answer, not just the refusals", async () => {
    const ws = await connectOwner();

    const shake = allLocal().filter((e) => e.kind === "handshake");
    // Recording only the REFUSED helloes would make every session that DID come
    // up look like it had no beginning: a capture would open with traffic on a
    // socket the reader never saw attach.
    expect(shake.map((e) => [e.dir, e.msgType])).toEqual([
      ["rx", "hello"],
      ["tx", "ready"],
    ]);
    expect(shake[0].detail).toMatchObject({ project: PROJECT, appPid: 4242 });
    // Both carry the token — the accepted one carries a VALID token — so the
    // body must be absent here exactly as it is on the refusal paths.
    expect(shake.every((e) => e.body === undefined)).toBe(true);
    ws.close();
  });

  it("records an outbound frame with the message's own id as its join key", async () => {
    const ws = await connectOwner();
    const msg = createMessage("terminal:output", { terminalId: "t1", data: "out" });
    bus.publish(msg, "control");
    const wire = await nextText(ws);

    const tx = local().filter((e) => e.dir === "tx");
    expect(tx).toHaveLength(1);
    expect(tx[0].kind).toBe("json");
    expect(tx[0].msgType).toBe("terminal:output");
    expect(tx[0].channel).toBe("control");
    // The relay path pays a nonce hash for its join key because its route
    // header carries no message id. Loopback frames carry theirs, and hashing
    // one instead would put a sha256 on the terminal-output path for nothing.
    expect(tx[0].frameId).toBe(msg.id);
    // The count has to be the bytes that actually crossed, or a capture is
    // wrong about the one thing nobody can re-measure after the fact.
    expect(tx[0].bytes).toBe(Buffer.byteLength(wire, "utf8"));
    ws.close();
  });

  it("gives a round-tripped frame the same id on both sides of the socket", async () => {
    const ws = await connectOwner();
    const msg = createMessage("terminal:output", { terminalId: "t1", data: "echo me" });
    bus.publish(msg, "control");
    // Echoing the delivered text back is what the app's own send looks like from
    // here, so this is a real round trip rather than two hand-built events.
    ws.send(await nextText(ws));

    const seen = await untilLocal(2);
    const tx = seen.find((e) => e.dir === "tx")!;
    const rx = seen.find((e) => e.dir === "rx")!;
    expect(rx.kind).toBe("json");
    expect(rx.msgType).toBe("terminal:output");
    // Every join in the CLI rests on this equality. If the two sides ever
    // derived their ids differently, `--join` would pair nothing and report it
    // as "the other endpoint never saw this frame".
    expect(rx.frameId).toBe(tx.frameId);
    expect(rx.frameId).toBe(msg.id);
    ws.close();
  });

  it("records the send that reaches nobody because no app is connected", () => {
    // The listener's own bus subscription lives only while an owner does, so
    // this is the window a core emits into after the desktop quit or during a
    // reconnect — the frame is dropped with no log at any level, which is where
    // "the app never showed that" begins.
    listener.deliver(createMessage("terminal:output", { terminalId: "t1", data: "x" }), "control");

    const drops = local().filter((e) => e.kind === "drop");
    expect(drops).toHaveLength(1);
    expect(drops[0].reason).toBe("no-owner");
    expect(drops[0].dir).toBe("tx");
    expect(drops[0].msgType).toBe("terminal:output");
  });

  it("records text on an established socket that is not a message at all", async () => {
    const ws = await connectOwner();
    // A truncated send, or something else that found this port. The bridge
    // returns silently, so without the tap the app's frame simply ceases to exist.
    ws.send("{not json");

    const drops = (await untilLocal(1)).filter((e) => e.kind === "drop");
    expect(drops).toHaveLength(1);
    expect(drops[0].reason).toBe("not-json");
    expect(drops[0].dir).toBe("rx");
    expect(drops[0].bytes).toBe(Buffer.byteLength("{not json", "utf8"));
    ws.close();
  });

  it("records a frame this bridge has no schema for, with the type it named", async () => {
    const ws = await connectOwner();
    // An app and a bridge that disagree about the wire — a schema addition only
    // one half shipped. Silent on both sides, and from the app indistinguishable
    // from a handler that simply chose not to answer.
    ws.send(JSON.stringify({ channel: "control", type: "terminal:from-the-future", id: "fut-1" }));

    const drops = (await untilLocal(1)).filter((e) => e.kind === "drop");
    expect(drops).toHaveLength(1);
    expect(drops[0].reason).toBe("unparseable");
    expect(drops[0].msgType).toBe("terminal:from-the-future");
    // Named by the sender, so the app's own capture can still be joined against
    // a frame this bridge refused.
    expect(drops[0].frameId).toBe("fut-1");
    ws.close();
  });

  it("records every hello it refuses, with the reason it refused for", async () => {
    // A refused hello is the failure a relay-path capture can never show: both
    // halves of that capture ride the sealed session, so a session that never
    // came up records nothing and "it just never connected" is invisible.
    const refusals: [string, string][] = [
      ["not-a-json-envelope", "hello-not-json"],
      [JSON.stringify({ type: "hello", appPid: 1 }), "hello-malformed"],
      [JSON.stringify({ type: "hello", token: "wrong-token-a91b7", appPid: 1 }), "hello-bad-token"],
    ];

    for (const [text] of refusals) {
      const ws = new WebSocket(`ws://127.0.0.1:${listener.port}`);
      await new Promise<void>((resolve, reject) => {
        ws.onopen = () => resolve();
        ws.onerror = (e) => reject(e);
      });
      const closed = nextClose(ws);
      ws.send(text);
      expect(await closed).toBe(4401);
    }

    const drops = (await untilLocal(refusals.length)).filter((e) => e.kind === "drop");
    expect(drops.map((e) => e.reason)).toEqual(refusals.map(([, reason]) => reason));
    for (const [i, drop] of drops.entries()) {
      expect(drop.dir).toBe("rx");
      expect(drop.bytes).toBe(Buffer.byteLength(refusals[i][0], "utf8"));
      // A hello carries no message id, so the sha256 prefix is the only join key
      // it can have — and it is a digest of the frame, never of the secret.
      expect(drop.frameId).toHaveLength(24);
    }
  });

  it("stamps every event with the project whose socket it crossed", async () => {
    const ws = await connectOwner();
    bus.publish(createMessage("terminal:output", { terminalId: "t1", data: "out" }), "control");
    ws.send(await nextText(ws));
    ws.send("{not json");

    const seen = await untilLocal(3);
    // One bridge hosts a listener per project core into ONE process-global ring,
    // so without this tag an interleaved capture cannot say whose frames these
    // are — and every reading of it is a guess.
    for (const e of seen) expect(e.detail).toMatchObject({ project: PROJECT });
    ws.close();
  });
});

describe("LocalListener body capture", () => {
  it("never lets the hello's shared secret reach the ring", async () => {
    armBodyCapture(true, 60_000);
    expect(isBodyCaptureArmed()).toBe(true);

    // Both shapes the token takes on this socket: the real secret on the hello
    // that is ACCEPTED (which records nothing today, so a body added there is
    // caught by the search below), and a rejected one on the hello that is
    // REFUSED — the only hello path that records at all. The refused token
    // deliberately CONTAINS the real one, so the single search covers both.
    const bad = new WebSocket(`ws://127.0.0.1:${listener.port}`);
    await new Promise<void>((resolve, reject) => {
      bad.onopen = () => resolve();
      bad.onerror = (e) => reject(e);
    });
    const badClosed = nextClose(bad);
    bad.send(JSON.stringify({ type: "hello", token: `wrong-${TOKEN}`, appPid: 9 }));
    await badClosed;

    const ws = await connectOwner();
    bus.publish(createMessage("terminal:output", { terminalId: "t1", data: "out" }), "control");
    ws.send(await nextText(ws));
    const seen = await untilLocal(3);

    // Non-vacuous: capture is genuinely on, so an ordinary frame DID record its
    // plaintext while these hello frames recorded none.
    expect(seen.some((e) => e.body !== undefined)).toBe(true);
    // netwatch events are written to netwatch.log and handed out verbatim by the
    // CLI's export, so a captured hello would publish the credential that guards
    // this socket — silently, to whoever the operator sends the capture to.
    expect(JSON.stringify(netwatch.snapshot())).not.toContain(TOKEN);
    ws.close();
  });

  it("records no plaintext until someone asks for it", async () => {
    const ws = await connectOwner();
    bus.publish(createMessage("terminal:output", { terminalId: "t1", data: "secret output" }), "control");
    ws.send(await nextText(ws));

    // Always-on metadata is the whole reason the ring is affordable. A body
    // nobody armed is the user's own keystrokes and build output kept in memory
    // by default.
    for (const e of await untilLocal(2)) expect(e.body).toBeUndefined();
    expect(local().some((e) => e.msgType === "terminal:output")).toBe(true);
    ws.close();
  });

  it("carries both directions' plaintext once armed", async () => {
    const ws = await connectOwner();
    armBodyCapture(true, 60_000);
    bus.publish(createMessage("terminal:output", { terminalId: "t1", data: "hello world" }), "control");
    const wire = await nextText(ws);
    ws.send(wire);

    const seen = await untilLocal(2);
    const tx = seen.find((e) => e.dir === "tx")!;
    const rx = seen.find((e) => e.dir === "rx")!;
    // The body is the frame as it crossed, not a re-serialization: a capture
    // that reconstructs the JSON cannot show a wire the app disagreed with.
    expect(tx.body).toBe(wire);
    expect(rx.body).toBe(wire);
    ws.close();
  });

  it("truncates a body at the cap and says how much it dropped", async () => {
    const ws = await connectOwner();
    armBodyCapture(true, 60_000);
    const data = "x".repeat(20_000);
    bus.publish(createMessage("terminal:output", { terminalId: "t1", data }), "control");
    const wire = await nextText(ws);

    const tx = local().find((e) => e.dir === "tx")!;
    // A single terminal-output frame can carry a whole screen of build log and
    // the ring holds thousands of them, so the cap is what bounds memory — a
    // marker appended PAST it would defeat the thing it reports.
    expect(tx.body!.length).toBeLessThanOrEqual(NETWATCH_BODY_MAX_CHARS);
    expect(tx.body).toMatch(/…\[\+\d+ chars\]$/);
    expect(wire.startsWith(tx.body!.slice(0, 100))).toBe(true);
    ws.close();
  });

  it("stops recording plaintext once the window lapses", async () => {
    const ws = await connectOwner();
    armBodyCapture(true, 20);
    await new Promise((r) => setTimeout(r, 120));

    bus.publish(createMessage("terminal:output", { terminalId: "t1", data: "after the window" }), "control");
    ws.send(await nextText(ws));

    // The dead man's switch: the only thing that ever disarms is the watcher
    // that armed it, and a watcher killed with SIGKILL sends no disarm — without
    // the lapse one `antgrid watch` leaves the host recording payloads for the
    // rest of its life with nothing on the machine able to turn it off.
    expect(isBodyCaptureArmed()).toBe(false);
    for (const e of await untilLocal(2)) expect(e.body).toBeUndefined();
    ws.close();
  });
});

describe("antgrid watch --local", () => {
  it("refuses to combine with --relay", async () => {
    const err = spyOn(console, "error").mockImplementation(() => {});
    try {
      // Two narrowings of one field with nothing in the intersection; showing
      // both is already what asking for neither means.
      expect(await runNetwatchCli({ local: true, relay: true })).toBe(1);
      expect(err.mock.calls.flat().join(" ")).toContain("--local and --relay");
    } finally {
      err.mockRestore();
    }
  });

  it("refuses to arm bodies for a snapshot that is already in the ring", async () => {
    const dir = mkdtempSync(join(tmpdir(), "netwatch-local-"));
    writeFileSync(
      join(dir, "host.json"),
      JSON.stringify({
        version: 1,
        pid: process.pid,
        controlPort: 1,
        token: "t",
        startedAt: new Date().toISOString(),
        agentVersion: "0.0.0-test",
      }),
    );
    const prev = process.env.ANTGRID_DIR;
    const err = spyOn(console, "error").mockImplementation(() => {});
    try {
      // Arming records the FUTURE, so with no stream to follow the window would
      // open and close around a snapshot it could never fill — a silent no-op
      // that reads as "this build captures no bodies".
      expect(await runNetwatchCli({ dir, bodies: true, follow: false })).toBe(1);
      expect(err.mock.calls.flat().join(" ")).toContain("--bodies");
    } finally {
      err.mockRestore();
      if (prev === undefined) delete process.env.ANTGRID_DIR;
      else process.env.ANTGRID_DIR = prev;
    }
  });

  it("names the transport and sanitizes the body it prints", () => {
    const line = renderEvent({
      seq: 1,
      at: Date.now(),
      dir: "rx",
      kind: "json",
      transport: "local",
      channel: "control",
      msgType: "terminal:input",
      frameId: "id-1",
      body: "before[2Jafter",
    });
    // Loopback is the wire no other column hints at — channel, kind and size all
    // read like a relay frame's.
    expect(line).toContain("local");
    // A body is the least trusted thing in a capture, and an unsanitized one is
    // an escape sequence straight into the operator's terminal.
    expect(line).not.toContain("");
    expect(line.split("\n")[1]).toContain("before[2Jafter");
  });
});
