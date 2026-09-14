import { describe, it, expect, spyOn } from "bun:test";
import { mkdtempSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join as joinPath } from "node:path";
import { joinCaptures, runNetwatchCli } from "../src/cli/netwatch";
import type { NetwatchEvent } from "../src/netwatch";

let seq = 0;
function ev(partial: Partial<NetwatchEvent> & { at: number; dir: "tx" | "rx" }): NetwatchEvent {
  return {
    seq: ++seq,
    kind: "sealed",
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
        { seq: 1, at: base, dir: "rx", kind: "sealed", transport: "relay", channel: "control", frameId: "aa" },
        { seq: 2, at: base + 5, dir: "rx", kind: "sealed", transport: "relay", channel: "control", frameId: "solo" },
      ] as NetwatchEvent[],
      [
        JSON.stringify({ seq: 1, at: base - 20, dir: "tx", kind: "sealed", transport: "relay", origin: "app", channel: "control", frameId: "aa", msgType: "terminal:input" }),
        JSON.stringify({ seq: 2, at: base + 2, dir: "tx", kind: "sealed", transport: "relay", origin: "app", channel: "control", frameId: "vanished", msgType: "file:read" }),
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
