// `antgrid watch --bodies`: what a run leaves behind on the host when it ends.
//
// Split from the other netwatch CLI files because none of them arms anything —
// they drive `runNetwatchCli` for its rendering, its filters and its join, and
// every one of those paths returns before the arming code runs. So the arm, the
// heartbeat and the disarm that must outlive every exit executed in ZERO netwatch
// tests, which made "the netwatch suite stayed green" no evidence at all about
// the half of `cli/watch-transport.ts` they live in.
//
// Driven against a stand-in host for the reason the modelwatch CLI file is: the
// assertions are about the arming protocol, and a real host would make them
// depend on whether a frame happened to cross the wire.
import { afterEach, beforeEach, describe, expect, it, spyOn } from "bun:test";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { runNetwatchCli } from "../src/cli/netwatch";

type Record_ = Record<string, unknown>;

const HOST_TOKEN = "host-bearer-token-netwatch-arm";

function startFakeHost(opts: { streamStatus?: number; armOk?: boolean } = {}): {
  dir: string;
  requests: Record_[];
  stop: () => Promise<void>;
} {
  const requests: Record_[] = [];
  const server = Bun.serve({
    hostname: "127.0.0.1",
    port: 0,
    fetch: async (req) => {
      const url = new URL(req.url);
      if (url.pathname === "/control") {
        const body = (await req.json()) as Record_;
        requests.push(body);
        if (opts.armOk === false) {
          return Response.json({ id: body.id, ok: false, error: { code: "NOPE", message: "refused" } }, { status: 400 });
        }
        return Response.json({
          id: body.id,
          ok: true,
          type: "netwatch:local",
          bodies: body.bodies === true,
          ttlMs: body.bodies === true ? 60_000 : 0,
        });
      }
      if (url.pathname === "/netwatch") {
        if (opts.streamStatus && opts.streamStatus !== 200) {
          return new Response("no", { status: opts.streamStatus });
        }
        const replay = { recorded: 0, evicted: 0, buffered: 0, replayed: 0 };
        return new Response(`event: replayed\ndata: ${JSON.stringify(replay)}\n\n`, {
          headers: { "content-type": "text/event-stream" },
        });
      }
      return new Response("not found", { status: 404 });
    },
  });

  const dir = mkdtempSync(join(tmpdir(), "netwatch-cli-arm-"));
  writeFileSync(
    join(dir, "host.json"),
    JSON.stringify({
      version: 1,
      pid: process.pid,
      controlPort: server.port,
      token: HOST_TOKEN,
      startedAt: new Date().toISOString(),
      agentVersion: "0.0.0-test",
    }),
  );
  return {
    dir,
    requests,
    stop: async () => {
      server.stop(true);
      rmSync(dir, { recursive: true, force: true });
    },
  };
}

let prevAbDir: string | undefined;

/** `runNetwatchCli` sets ANTGRID_DIR from `--dir`, so the environment is put
 *  back afterwards. */
async function run(opts: Record_): Promise<{ code: number; err: string }> {
  prevAbDir = process.env.ANTGRID_DIR;
  const err: string[] = [];
  const log = spyOn(console, "log").mockImplementation(() => {});
  const error = spyOn(console, "error").mockImplementation((...args: unknown[]) => { err.push(args.join(" ")); });
  try {
    const code = await runNetwatchCli(opts);
    return { code, err: err.join("\n") };
  } finally {
    log.mockRestore();
    error.mockRestore();
    if (prevAbDir === undefined) delete process.env.ANTGRID_DIR;
    else process.env.ANTGRID_DIR = prevAbDir;
  }
}

let fake: { dir: string; requests: Record_[]; stop: () => Promise<void> } | null = null;
let sigintHandlers = 0;

beforeEach(() => {
  sigintHandlers = process.listenerCount("SIGINT");
});

afterEach(async () => {
  await fake?.stop();
  fake = null;
  // The handler that defers Ctrl-C until the arms are disarmed must come off
  // again on every path out, or it displaces SIGINT's default — exiting 0 — for
  // the rest of the process, one more handler per run.
  expect(process.listenerCount("SIGINT")).toBe(sigintHandlers);
});

describe("antgrid watch --bodies", () => {
  it("arms body capture and disarms it when the stream ends", async () => {
    fake = startFakeHost();
    const { code } = await run({ dir: fake.dir, bodies: true });

    expect(code).toBe(0);
    // The arm is a dead man's switch the watcher holds open; the disarm is what
    // stops this host recording loopback plaintext once nobody is reading.
    expect(fake.requests.map((r) => [r.type, r.bodies])).toEqual([
      ["netwatch:local", true],
      ["netwatch:local", false],
    ]);
  });

  it("disarms on the way out of a failed run too", async () => {
    fake = startFakeHost({ streamStatus: 500 });
    const { code, err } = await run({ dir: fake.dir, bodies: true });

    expect(code).toBe(1);
    expect(err).toContain("HTTP 500");
    // The arm landed before the stream was refused. An exit that skipped the
    // disarm would leave this host recording plaintext until the TTL lapsed,
    // with the watcher that armed it already gone.
    expect(fake.requests.map((r) => r.bodies)).toEqual([true, false]);
  });

  it("sends no disarm for a capture the host never armed", async () => {
    fake = startFakeHost({ armOk: false });
    const { code, err } = await run({ dir: fake.dir, bodies: true });

    expect(code).toBe(1);
    expect(err).toContain("could not arm body capture");
    // Only what was actually armed is held: a run that disarmed a capture it
    // never got would be turning off a window someone else opened.
    expect(fake.requests.map((r) => r.bodies)).toEqual([true]);
  });

  it("refuses to arm for a snapshot that is already in the ring", async () => {
    fake = startFakeHost();
    const { code, err } = await run({ dir: fake.dir, bodies: true, follow: false });

    // Arming records the future, so with no stream to follow the window would
    // open and close around a snapshot it could never have filled.
    expect(code).toBe(1);
    expect(err).toContain("--bodies needs a live stream");
    expect(fake.requests).toEqual([]);
  });
});
