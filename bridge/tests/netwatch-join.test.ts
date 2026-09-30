import { describe, it, expect, spyOn } from "bun:test";
import { mkdtempSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join as joinPath } from "node:path";
import { joinCaptures, joinSelected, readAppCapture, runNetwatchCli, type NetwatchCliOptions } from "../src/cli/netwatch";
import { netwatch, __resetNetwatchForTest } from "../src/netwatch";
import type { NetwatchEvent } from "../src/netwatch";
import { TestPeerSessionOwner } from "./test-peer-session-owner";
import peerTransportVectors from "../../evals/fixtures/peer-transport-vectors.json";

let seq = 0;
function ev(partial: Partial<NetwatchEvent> & { at: number; dir: "tx" | "rx" }): NetwatchEvent {
  return {
    seq: ++seq,
    kind: "frame",
    transport: "relay",
    channel: "control",
    ...partial,
  } as NetwatchEvent;
}

// A fixed `now` well past every fixture, so the settle margin (which exists to
// stop the newest frames being called lost while they are still buffered) never
// clips what a test is actually asserting.
const NOW = 60_000;

describe("joinCaptures", () => {
  it("pairs a send against the receive of the same frame and times it", () => {
    const app = [ev({ at: 1000, dir: "tx", frameId: "aa", msgType: "terminal:input" })];
    const bridge = [ev({ at: 1022, dir: "rx", frameId: "aa" })];

    const { rows, overlap } = joinCaptures(app, bridge, NOW);
    expect(rows.map((r) => r.verdict)).toEqual(["matched", "matched"]);
    // The delta hangs off the RECEIVING half — that is the direction latency
    // has a meaning in.
    expect(rows[0].deltaMs).toBeUndefined();
    expect(rows[1].deltaMs).toBe(22);
    // Starts at the later of the two first events; runs to now, less settle.
    expect(overlap).toEqual([1022, NOW - 1000]);
  });

  it("calls a frame lost when the other capture was already covering that moment", () => {
    const app = [
      ev({ at: 1000, dir: "tx", frameId: "aa" }),
      ev({ at: 1500, dir: "tx", frameId: "bb", msgType: "file:read" }),
      ev({ at: 2000, dir: "rx", frameId: "cc" }),
    ];
    const bridge = [
      ev({ at: 1000, dir: "rx", frameId: "aa" }),
      ev({ at: 2000, dir: "tx", frameId: "cc" }),
    ];

    const { rows } = joinCaptures(app, bridge, NOW);
    const lost = rows.filter((r) => r.verdict === "lost");
    expect(lost).toHaveLength(1);
    expect(lost[0].event.frameId).toBe("bb");
    expect(lost[0].event.msgType).toBe("file:read");
  });

  it("a quiet stretch does not end a capture — the tail is still judged", () => {
    // The host recorded nothing after 1000. That is not the ring closing, and a
    // send at 30s with no matching receive is still a real loss.
    const app = [
      ev({ at: 1000, dir: "tx", frameId: "aa" }),
      ev({ at: 30_000, dir: "tx", frameId: "zz", msgType: "file:read" }),
    ];
    const bridge = [ev({ at: 1000, dir: "rx", frameId: "aa" })];

    const { rows } = joinCaptures(app, bridge, NOW);
    expect(rows.find((r) => r.event.frameId === "zz")!.verdict).toBe("lost");
  });

  it("says nothing about frames older than the shorter capture reaches", () => {
    // The host's ring had already evicted everything before 5000, so the app's
    // earlier frames are simply unknowable — never "lost".
    const app = [
      ev({ at: 1000, dir: "tx", frameId: "ancient" }),
      ev({ at: 6000, dir: "tx", frameId: "aa" }),
    ];
    const bridge = [ev({ at: 6000, dir: "rx", frameId: "aa" })];

    const { rows } = joinCaptures(app, bridge, NOW);
    expect(rows.find((r) => r.event.frameId === "ancient")!.verdict).toBe("outside");
    expect(rows.filter((r) => r.verdict === "lost")).toHaveLength(0);
  });

  it("does not call the newest frames lost while they are still buffered", () => {
    // The app holds an event briefly to annotate it and batches the write, so
    // the freshest host frame legitimately has no counterpart on disk yet.
    const app = [ev({ at: NOW - 30_000, dir: "tx", frameId: "aa" })];
    const bridge = [
      ev({ at: NOW - 30_000, dir: "rx", frameId: "aa" }),
      ev({ at: NOW - 50, dir: "rx", frameId: "brand-new" }),
    ];

    const { rows } = joinCaptures(app, bridge, NOW);
    expect(rows.find((r) => r.event.frameId === "brand-new")!.verdict).toBe("outside");
  });

  it("reports a receive whose sender was never captured", () => {
    const app = [ev({ at: 1000, dir: "tx", frameId: "aa" })];
    const bridge = [
      ev({ at: 1000, dir: "rx", frameId: "aa" }),
      ev({ at: 1001, dir: "rx", frameId: "orphan" }),
    ];

    const { rows } = joinCaptures(app, bridge, NOW);
    expect(rows.find((r) => r.event.frameId === "orphan")!.verdict).toBe("unpaired");
  });

  it("pairs byte-identical frames (same frameId) by occurrence, not all to one peer", () => {
    // A ping, a pong, a credit update — every occurrence of the same payload
    // hashes to the same frameId. The buggy `.find()` wired every send to the
    // FIRST receive sharing that id, so this must use two occurrences on each
    // side and check each pairs with its own counterpart, not both with #1.
    const app = [
      ev({ at: 1000, dir: "tx", frameId: "dup", msgType: "ping" }),
      ev({ at: 2000, dir: "tx", frameId: "dup", msgType: "ping" }),
    ];
    const bridge = [
      ev({ at: 1010, dir: "rx", frameId: "dup" }),
      ev({ at: 2050, dir: "rx", frameId: "dup" }),
    ];

    const { rows } = joinCaptures(app, bridge, NOW);
    expect(rows.every((r) => r.verdict === "matched")).toBe(true);
    const rx1 = rows.find((r) => r.event.dir === "rx" && r.event.at === 1010)!;
    const rx2 = rows.find((r) => r.event.dir === "rx" && r.event.at === 2050)!;
    expect(rx1.deltaMs).toBe(10);
    expect(rx2.deltaMs).toBe(50);
  });

  it("pairs a duplicate id's discard to its own occurrence, not to a later delivery", () => {
    const app = [
      ev({ at: 1000, dir: "tx", frameId: "dup", msgType: "ping" }),
      ev({ at: 2000, dir: "tx", frameId: "dup", msgType: "ping" }),
    ];
    const bridge = [
      ev({ at: 1010, dir: "rx", kind: "drop", frameId: "dup", reason: "pre-establishment" }),
      ev({ at: 2050, dir: "rx", frameId: "dup" }),
    ];

    const { rows } = joinCaptures(app, bridge, NOW);
    const tx1 = rows.find((r) => r.event.dir === "tx" && r.event.at === 1000)!;
    const tx2 = rows.find((r) => r.event.dir === "tx" && r.event.at === 2000)!;
    expect(tx1.verdict).toBe("discarded");
    expect(tx2.verdict).toBe("matched");
    expect(tx2.deltaMs).toBeUndefined();
    const rx2 = rows.find((r) => r.event.dir === "rx" && r.event.at === 2050)!;
    expect(rx2.verdict).toBe("matched");
    expect(rx2.deltaMs).toBe(50);
  });

  it("never pairs a duplicate id against a frame travelling the other way", () => {
    // Both ends send the same bytes, so both sends share one hash id. A send
    // pairs only with a receive at the FAR end: the app's own receive of the
    // bridge's copy is a different frame, however close in time.
    const app = [
      ev({ at: 1000, dir: "tx", frameId: "dup", msgType: "ping" }),
      ev({ at: 1005, dir: "rx", frameId: "dup" }),
    ];
    const bridge = [
      ev({ at: 1001, dir: "tx", frameId: "dup", msgType: "ping" }),
      ev({ at: 1030, dir: "rx", frameId: "dup" }),
    ];

    const { rows } = joinCaptures(app, bridge, NOW);
    expect(rows.every((r) => r.verdict === "matched")).toBe(true);
    const appRx = rows.find((r) => r.origin === "app" && r.event.dir === "rx")!;
    const brgRx = rows.find((r) => r.origin === "brg" && r.event.dir === "rx")!;
    expect(appRx.deltaMs).toBe(4);
    expect(brgRx.deltaMs).toBe(30);
  });

  it("pairs a duplicate id only within its own channel", () => {
    const app = [
      ev({ at: 1000, dir: "tx", frameId: "dup", channel: "preview" }),
      ev({ at: 1001, dir: "tx", frameId: "dup", channel: "control" }),
    ];
    const bridge = [ev({ at: 1020, dir: "rx", frameId: "dup", channel: "control" })];

    const { rows } = joinCaptures(app, bridge, NOW);
    const preview = rows.find((r) => r.event.channel === "preview")!;
    const rx = rows.find((r) => r.event.dir === "rx")!;
    expect(preview.verdict).not.toBe("matched");
    expect(rx.deltaMs).toBe(19);
  });

  it("pairs a bridge record tagged with a stream kind against the app's untagged copy", () => {
    // The app's capture carries no stream kind, so the bridge tagging its half
    // must not split the pair.
    const app = [ev({ at: 1000, dir: "tx", frameId: "pk", transport: "iroh" })];
    const bridge = [ev({ at: 1020, dir: "rx", frameId: "pk", transport: "iroh", streamKind: "project" })];

    const { rows } = joinCaptures(app, bridge, NOW);
    expect(rows.map((r) => r.verdict)).toEqual(["matched", "matched"]);
    expect(rows.find((r) => r.event.dir === "rx")!.deltaMs).toBe(20);
  });

  it("counts a drop as unpairable, not as a match", () => {
    // A drop never crossed the socket, so it has no counterpart by
    // construction — calling it matched would flatter every report.
    const app = [ev({ at: 1000, dir: "tx", kind: "drop", frameId: "aa", reason: "socket-not-open" })];
    const { rows } = joinCaptures(app, [], NOW);
    expect(rows[0].verdict).toBe("na");
  });

  it("pairs nothing when one side captured nothing at all", () => {
    const { overlap, rows } = joinCaptures([ev({ at: 1000, dir: "tx", frameId: "aa" })], [], NOW);
    expect(overlap).toBeNull();
    expect(rows.every((r) => r.verdict === "outside")).toBe(true);
  });

  it("orders the merged timeline by time across both origins", () => {
    const app = [ev({ at: 1005, dir: "tx", frameId: "b" })];
    const bridge = [ev({ at: 1000, dir: "rx", frameId: "a" })];
    const { rows } = joinCaptures(app, bridge, NOW);
    expect(rows.map((r) => r.origin)).toEqual(["brg", "app"]);
  });
});

describe("antgrid watch --join", () => {
  function seeded(events: NetwatchEvent[], appLines: string[]) {
    const dir = mkdtempSync(joinPath(tmpdir(), "netwatch-join-"));
    const token = "join-token";
    const server = Bun.serve({
      hostname: "127.0.0.1",
      port: 0,
      fetch(req) {
        const url = new URL(req.url);
        if (url.pathname !== "/netwatch") return new Response("not found", { status: 404 });
        if (req.headers.get("authorization") !== `Bearer ${token}`) {
          return new Response("unauthorized", { status: 401 });
        }
        return new Response(
          [
            ...events.map((e) => `data: ${JSON.stringify(e)}\n\n`),
            `event: replayed\ndata: ${JSON.stringify({ recorded: events.length, evicted: 0 })}\n\n`,
          ].join(""),
          { headers: { "content-type": "text/event-stream" } },
        );
      },
    });
    writeFileSync(
      joinPath(dir, "host.json"),
      JSON.stringify({
        version: 1,
        pid: process.pid,
        controlPort: server.port,
        token,
        startedAt: new Date().toISOString(),
        agentVersion: "0.0.0-test",
      }),
    );
    const appLog = joinPath(dir, "netwatch.log");
    writeFileSync(appLog, appLines.join("\n"));
    return { dir, appLog, server };
  }

  async function run(opts: { dir: string; join: string }) {
    const out: string[] = [];
    const err: string[] = [];
    const log = spyOn(console, "log").mockImplementation((...a: unknown[]) => {
      out.push(a.join(" "));
    });
    const error = spyOn(console, "error").mockImplementation((...a: unknown[]) => {
      err.push(a.join(" "));
    });
    const prevDir = process.env.ANTGRID_DIR;
    try {
      const code = await runNetwatchCli({ ...opts, json: true });
      return { code, out, err };
    } finally {
      log.mockRestore();
      error.mockRestore();
      if (prevDir === undefined) delete process.env.ANTGRID_DIR;
      else process.env.ANTGRID_DIR = prevDir;
    }
  }

  it("merges the app file with the host ring and verdicts each frame", async () => {
    // Comfortably older than the settle margin, so every fixture frame is
    // inside the window and gets a real verdict rather than "outside".
    const base = Date.now() - 30_000;
    const { dir, appLog, server } = seeded(
      [
        { seq: 1, at: base, dir: "rx", kind: "frame", transport: "relay", channel: "control", frameId: "aa" },
        { seq: 2, at: base + 5, dir: "rx", kind: "frame", transport: "relay", channel: "control", frameId: "solo" },
      ] as NetwatchEvent[],
      [
        JSON.stringify({ seq: 1, at: base - 20, dir: "tx", kind: "frame", transport: "relay", origin: "app", channel: "control", frameId: "aa", msgType: "terminal:input" }),
        JSON.stringify({ seq: 2, at: base + 2, dir: "tx", kind: "frame", transport: "relay", origin: "app", channel: "control", frameId: "vanished", msgType: "file:read" }),
        "{ this line is torn",
      ],
    );

    const { code, out } = await run({ dir, join: appLog });
    expect(code).toBe(0);

    const rows = out.map((l) => JSON.parse(l) as { frameId?: string; verdict: string; deltaMs?: number });
    expect(rows.find((r) => r.frameId === "aa" && r.deltaMs !== undefined)?.deltaMs).toBe(20);
    expect(rows.find((r) => r.frameId === "vanished")?.verdict).toBe("lost");
    expect(rows.find((r) => r.frameId === "solo")?.verdict).toBe("unpaired");
    // The torn trailing line must cost one row, not the whole capture.
    expect(rows).toHaveLength(4);

    server.stop(true);
    rmSync(dir, { recursive: true, force: true });
  });

  it("explains itself when the app never wrote a capture", async () => {
    const { dir, server } = seeded([], []);
    const { code, err } = await run({ dir, join: joinPath(dir, "absent.log") });
    expect(code).toBe(1);
    expect(err.join("\n")).toContain("ANTGRID_NETWATCH");

    server.stop(true);
    rmSync(dir, { recursive: true, force: true });
  });
});

describe("joinSelected", () => {
  const iroh = { at: 0, dir: "tx", transport: "iroh" } as NetwatchEvent;
  const relay = { at: 0, dir: "tx", transport: "relay" } as NetwatchEvent;
  const local = { at: 0, dir: "tx", transport: "local" } as NetwatchEvent;

  it("with no flags keeps iroh and relay, and drops local", () => {
    const opts = {} as NetwatchCliOptions;
    expect(joinSelected(iroh, opts)).toBe(true);
    expect(joinSelected(relay, opts)).toBe(true);
    expect(joinSelected(local, opts)).toBe(false);
  });

  it("--local keeps only local", () => {
    const opts = { local: true } as NetwatchCliOptions;
    expect(joinSelected(iroh, opts)).toBe(false);
    expect(joinSelected(relay, opts)).toBe(false);
    expect(joinSelected(local, opts)).toBe(true);
  });

  it("--relay keeps only relay", () => {
    const opts = { relay: true } as NetwatchCliOptions;
    expect(joinSelected(iroh, opts)).toBe(false);
    expect(joinSelected(relay, opts)).toBe(true);
    expect(joinSelected(local, opts)).toBe(false);
  });
});

describe("a native session:ping pairs across a real join", () => {
  it("the app's tx row and the bridge's rx row both verdict matched", async () => {
    __resetNetwatchForTest();
    const sample = (peerTransportVectors as {
      sessionRecords: { samples: Array<{ name: string; json: string; frameId: string }> };
    }).sessionRecords.samples.find((s) => s.name === "ping");
    if (!sample) throw new Error("fixture has no sessionRecords ping sample");

    const dir = mkdtempSync(joinPath(tmpdir(), "netwatch-ping-pair-"));
    const now = Date.now();
    const appLine = JSON.stringify({
      seq: 1, at: now, dir: "tx", kind: "frame", transport: "iroh", origin: "app",
      channel: "control", streamId: "0", streamKind: "session", msgType: "session:ping",
      bytes: Buffer.byteLength(sample.json, "utf8"), frameId: sample.frameId,
    });
    const appLog = joinPath(dir, "netwatch.log");
    writeFileSync(appLog, appLine);
    const app = readAppCapture(appLog);
    expect(app).not.toBeNull();

    const client = TestPeerSessionOwner.forTest({ sendPayload: () => {}, peerId: "phone-1", deviceId: "dev-1" });
    try {
      client.establish("phone-1");
      __resetNetwatchForTest();
      client.injectPeerPayload(Buffer.from(sample.json, "utf8"), "phone-1");
      const bridge = netwatch.snapshot().filter((e) => e.dir === "rx" && e.kind === "frame");

      const appRows = app!.filter((e) => joinSelected(e, {} as NetwatchCliOptions));
      const bridgeRows = bridge.filter((e) => joinSelected(e, {} as NetwatchCliOptions));
      // Comfortably past both events' `at` and past the 1s settle margin, so
      // neither the app's (pre-dated) row nor the bridge's (just-recorded) one
      // is read as still-buffered ("outside").
      const { rows } = joinCaptures(appRows, bridgeRows, Date.now() + 5_000);
      const appRow = rows.find((r) => r.origin === "app");
      const bridgeRow = rows.find((r) => r.origin === "brg");
      expect(appRow?.verdict).toBe("matched");
      expect(bridgeRow?.verdict).toBe("matched");
    } finally {
      client.close();
      rmSync(dir, { recursive: true, force: true });
    }
  });
});
