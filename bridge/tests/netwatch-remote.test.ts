// The bridge's half of `antgrid watch --remote`: admitting a batch a remote app
// captured on ITS side of the same socket, and keeping that batch out of
// everything downstream.
import { afterEach, beforeEach, describe, expect, it } from "bun:test";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { encodeRouteFrame, FrameKind } from "antgrid-wire";
import { Netwatch, netwatch, __resetNetwatchForTest } from "../src/netwatch";
import { RelayClient } from "../src/relay-client";
import type { AbMessage } from "../src/protocol";
import { runNetwatchCli } from "../src/cli/netwatch";

const appEvent = (over: Record<string, unknown> = {}): Record<string, unknown> => ({
  seq: 7,
  at: 1_000,
  dir: "tx",
  kind: "sealed",
  transport: "relay",
  origin: "app",
  channel: "control",
  msgType: "terminal:input",
  frameId: "a3f9c2110bd4aa01bb02cc03",
  bytes: 412,
  ...over,
});

describe("Netwatch.ingestRemote", () => {
  it("keeps the app's own seq and marks the event as the far end's", () => {
    const w = new Netwatch(8);
    w.record({ dir: "rx", kind: "sealed", transport: "relay", msgType: "local" });
    expect(w.ingestRemote([appEvent()])).toBe(1);

    const remote = w.snapshot().find((e) => e.origin === "app")!;
    // Renumbering would destroy the only signal that the app's uploader hit its
    // own budget — a gap there is the app saying so.
    expect(remote.seq).toBe(7);
    expect(remote.msgType).toBe("terminal:input");
    expect(w.snapshot().find((e) => e.msgType === "local")!.origin).toBeUndefined();
  });

  it("shifts every timestamp onto this machine's clock", () => {
    const w = new Netwatch(8);
    w.ingestRemote([appEvent({ at: 1_000 }), appEvent({ at: 1_040 })], 5_000);

    const ats = w.snapshot().map((e) => e.at);
    expect(ats).toEqual([6_000, 6_040]);
    // The shift is uniform, so deltas BETWEEN two app-side events survive it.
    expect(ats[1] - ats[0]).toBe(40);
  });

  it("passes through a field this bridge has no name for", () => {
    const w = new Netwatch(8);
    w.ingestRemote([appEvent({ somethingNewer: "keep me" })]);
    // The whole point is reading what the OTHER endpoint saw; a newer app's
    // vocabulary must not be filtered down to this build's.
    expect((w.snapshot()[0] as unknown as Record<string, unknown>).somethingNewer).toBe("keep me");
  });

  it("refuses anything that is not shaped like an event", () => {
    const w = new Netwatch(8);
    const admitted = w.ingestRemote([
      null,
      "not an object",
      { dir: "sideways", kind: "sealed", at: 1 },
      { dir: "tx", at: 1 },
      { dir: "tx", kind: "sealed" },
      appEvent(),
    ]);
    expect(admitted).toBe(1);
    expect(w.snapshot()).toHaveLength(1);
  });

  it("counts remote events against the ring's eviction budget", () => {
    const w = new Netwatch(2);
    w.record({ dir: "tx", kind: "sealed", transport: "relay" });
    w.ingestRemote([appEvent(), appEvent(), appEvent()]);
    // `seq` counts only what THIS process recorded, so eviction cannot be
    // derived from it once a second origin is feeding the same ring.
    expect(w.snapshot()).toHaveLength(2);
    expect(w.evicted).toBe(2);
  });
});

/** A paired, handshake-complete client whose socket and seal are inert. */
function makeClient(open: () => string | null, onMessage?: (m: AbMessage) => void): RelayClient {
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
    onMessage,
  });
  (c as any)._peerId = "phone-1";
  (c as any).established = {
    attemptId: "a1",
    transport: { seal: (p: string) => Buffer.from(p, "utf8"), open },
    sessionKeys: { a2p: Buffer.alloc(32), p2a: Buffer.alloc(32), confirm: Buffer.alloc(32) },
  };
  (c as any).ws = { readyState: WebSocket.OPEN, send: () => {}, close: () => {} };
  return c;
}

function deliverControlPlane(client: RelayClient, m: unknown): void {
  const payload = Buffer.concat([Buffer.alloc(12, 0x7f), Buffer.from("sealed")]);
  (client as any).established.transport.open = () => JSON.stringify({ m });
  const frame = encodeRouteFrame(
    { type: "message", from: "phone-1", channel: "control", ts: Date.now() },
    payload,
    FrameKind.sealed,
  );
  (client as any).handleBinaryFrame(Buffer.from(frame));
}

describe("RelayClient netwatch:events ingest", () => {
  let client: RelayClient | null = null;

  beforeEach(() => __resetNetwatchForTest());
  afterEach(() => {
    client?.close();
    client = null;
    __resetNetwatchForTest();
  });

  it("admits the batch and never forwards it downstream", () => {
    const seen: AbMessage[] = [];
    client = makeClient(() => null, (m) => seen.push(m));
    deliverControlPlane(client, {
      type: "netwatch:events",
      id: "1",
      timestamp: Date.now(),
      events: [appEvent()],
    });

    expect(netwatch.snapshot().filter((e) => e.origin === "app")).toHaveLength(1);
    // A capture batch is diagnostics about this socket, not a verb: forwarding
    // it hands every project core a type it has no case for.
    expect(seen).toHaveLength(0);
  });

  it("records what the app's own budget threw away", () => {
    client = makeClient(() => null);
    deliverControlPlane(client, {
      type: "netwatch:events",
      id: "1",
      timestamp: Date.now(),
      events: [],
      dropped: 12,
    });

    const drop = netwatch.snapshot().find((e) => e.reason === "app-budget-exceeded")!;
    expect(drop.origin).toBe("app");
    expect(drop.detail).toMatchObject({ dropped: 12 });
  });

  it("survives a batch whose events are not an array", () => {
    client = makeClient(() => null);
    // parseMessageFast checks the `type` and nothing else, so this reaches the
    // ingest exactly as the peer wrote it.
    expect(() =>
      deliverControlPlane(client!, {
        type: "netwatch:events",
        id: "1",
        timestamp: Date.now(),
        events: "not an array",
      }),
    ).not.toThrow();
    expect(netwatch.snapshot().filter((e) => e.origin === "app")).toHaveLength(0);
  });
});

describe("antgrid watch --remote", () => {
  it("refuses to combine with --join", async () => {
    const dir = mkdtempSync(join(tmpdir(), "netwatch-remote-"));
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
    try {
      // Both answer "show me both halves", by paths that cannot combine: one
      // merges live in the ring, the other merges two files after the fact.
      expect(await runNetwatchCli({ dir, remote: true, join: `${dir}/netwatch.log` })).toBe(1);
    } finally {
      if (prev === undefined) delete process.env.ANTGRID_DIR;
      else process.env.ANTGRID_DIR = prev;
    }
  });
});
