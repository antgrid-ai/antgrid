// TunnelTcpRun and probeTls against real local sockets: the behaviours that
// matter here (graceful end, pause-based backpressure, a reset racing a close)
// only exist on a real socket, so nothing is faked below the peer interface.
import { afterEach, describe, expect, onTestFinished, test } from "bun:test";
import { spawn } from "node:child_process";
import net from "node:net";
import { fileURLToPath } from "node:url";
import tls from "node:tls";
import { probeTls, TunnelTcpRun, type TunnelTcpPeer } from "../src/tunnel-tcp";
import type { StreamSendOutcome } from "../src/peer/stream-records";
import { SELF_SIGNED_LOCALHOST_CERT, SELF_SIGNED_LOCALHOST_KEY } from "./support/self-signed-localhost";
import { until } from "./support/fake-bi-stream";

const servers: Array<net.Server> = [];
const sockets = new Set<net.Socket>();

afterEach(() => {
  for (const socket of sockets) socket.destroy();
  sockets.clear();
  for (const server of servers.splice(0)) server.close();
});

async function listen(server: net.Server): Promise<number> {
  servers.push(server);
  server.on("connection", (socket) => {
    sockets.add(socket);
    socket.on("close", () => sockets.delete(socket));
  });
  await new Promise<void>((resolve) => server.listen(0, resolve));
  return (server.address() as net.AddressInfo).port;
}

/** A port nothing listens on: bind one, note it, let it go. */
async function deadPort(): Promise<number> {
  const server = net.createServer();
  await new Promise<void>((resolve) => server.listen(0, resolve));
  const { port } = server.address() as net.AddressInfo;
  await new Promise<void>((resolve) => server.close(() => resolve()));
  return port;
}

function fakePeer(opts: { gateData?: boolean } = {}) {
  const events: string[] = [];
  const chunks: Buffer[] = [];
  let release: (() => void) | undefined;
  let dataCalls = 0;
  const peer: TunnelTcpPeer = {
    ready: async () => { events.push("ready"); return "sent"; },
    unreachable: (message) => { events.push(`unreachable:${message}`); },
    data: (bytes) => {
      dataCalls++;
      events.push("data");
      chunks.push(Buffer.from(bytes));
      if (!opts.gateData) return Promise.resolve("sent" as StreamSendOutcome);
      return new Promise<StreamSendOutcome>((resolve) => { release = () => resolve("sent"); });
    },
    end: () => { events.push("end"); },
  };
  return {
    peer,
    events,
    received: () => Buffer.concat(chunks),
    dataCalls: () => dataCalls,
    releaseData: () => { const r = release; release = undefined; r?.(); },
  };
}

function startRun(port: number, peer: TunnelTcpPeer, connectTimeoutMs?: number, endDrainMs?: number, endDestroyMs?: number) {
  let settled = 0;
  const run = new TunnelTcpRun(port, peer, () => { settled++; }, connectTimeoutMs, endDrainMs, endDestroyMs);
  run.start();
  return { run, settledCount: () => settled };
}

const settle = (ms = 60) => new Promise<void>((resolve) => setTimeout(resolve, ms));

describe("TunnelTcpRun", () => {
  test("the ready record precedes the first upstream byte, even when the upstream speaks first", async () => {
    const port = await listen(net.createServer((socket) => { socket.on("error", () => {}); socket.write("banner"); }));
    const p = fakePeer();
    startRun(port, p.peer);
    await until(() => p.received().toString() === "banner");
    expect(p.events.slice(0, 2)).toEqual(["ready", "data"]);
  });

  test("bytes round-trip through a real echo server in both directions", async () => {
    const port = await listen(net.createServer((socket) => { socket.on("error", () => {}); socket.on("data", (c) => socket.write(c)); }));
    const p = fakePeer();
    const { run } = startRun(port, p.peer);
    await until(() => p.events.includes("ready"));
    await run.write(Buffer.from("hello "));
    await run.write(Buffer.from("world"));
    await until(() => p.received().toString() === "hello world");
  });

  test("the upstream closing ends the tunnel exactly once, after the bytes it sent", async () => {
    const port = await listen(net.createServer((socket) => { socket.on("error", () => {}); socket.end("last words"); }));
    const p = fakePeer();
    const { settledCount } = startRun(port, p.peer);
    await until(() => p.events.includes("end"));
    await settle();
    expect(p.received().toString()).toBe("last words");
    expect(p.events).toEqual(["ready", "data", "end"]);
    expect(settledCount()).toBe(1);
  });

  test("an upstream reset racing its own close still ends the tunnel once", async () => {
    const port = await listen(net.createServer((socket) => { socket.on("error", () => {}); socket.resetAndDestroy(); }));
    const p = fakePeer();
    const { settledCount } = startRun(port, p.peer);
    await until(() => p.events.includes("end") || p.events.some((e) => e.startsWith("unreachable")));
    await settle();
    expect(p.events.filter((e) => e === "end" || e.startsWith("unreachable"))).toHaveLength(1);
    expect(settledCount()).toBe(1);
  });

  test("the app's end reaches the upstream as a graceful FIN, never an error, and reports the tunnel over", async () => {
    let serverEnded = false;
    let serverError: unknown;
    const port = await listen(net.createServer((socket) => {
      socket.on("error", (e) => { serverError = e; });
      socket.on("end", () => { serverEnded = true; socket.end(); });
    }));
    const p = fakePeer();
    const { run, settledCount } = startRun(port, p.peer);
    await until(() => p.events.includes("ready"));
    run.end();
    run.end();
    await until(() => serverEnded);
    await settle();
    expect(serverError).toBeUndefined();
    expect(p.events.filter((e) => e === "end")).toHaveLength(1);
    expect(settledCount()).toBe(1);
  });

  test("bytes the upstream sends after the app ended are dropped, not relayed", async () => {
    let upstream: net.Socket | undefined;
    const port = await listen(net.createServer((socket) => {
      socket.on("error", () => {});
      socket.on("end", () => {});
      upstream = socket;
    }));
    const p = fakePeer();
    const { run } = startRun(port, p.peer);
    await until(() => p.events.includes("ready"));
    run.end();
    await until(() => p.events.includes("end"));
    upstream!.write("too late");
    await settle(100);
    expect(p.dataCalls()).toBe(0);
    upstream!.end();
  });

  test("ending a run before its connect completes still ends the socket gracefully once it opens", async () => {
    let serverEnded = false;
    let serverError: unknown;
    const port = await listen(net.createServer((socket) => {
      socket.on("error", (e) => { serverError = e; });
      socket.on("end", () => { serverEnded = true; socket.end(); });
    }));
    const p = fakePeer();
    const { run, settledCount } = startRun(port, p.peer);
    run.end();
    await until(() => serverEnded);
    expect(serverError).toBeUndefined();
    expect(p.events).toEqual(["end"]);
    expect(settledCount()).toBe(1);
  });

  test("a refused port reports unreachable, never end, and a later end() is a no-op", async () => {
    const port = await deadPort();
    const p = fakePeer();
    const { run, settledCount } = startRun(port, p.peer);
    await until(() => p.events.length > 0);
    expect(p.events).toEqual([expect.stringMatching(/^unreachable:.*(ECONNREFUSED|ConnectionRefused|refused)/i)]);
    run.end();
    await settle();
    expect(p.events).toHaveLength(1);
    expect(settledCount()).toBe(1);
  });

  test("fail() before a start reports unreachable once and blocks a later start", async () => {
    const port = await listen(net.createServer());
    const p = fakePeer();
    let settled = 0;
    const run = new TunnelTcpRun(port, p.peer, () => { settled++; });
    run.fail("manager stopped");
    run.start();
    await settle();
    expect(p.events).toEqual(["unreachable:manager stopped"]);
    expect(settled).toBe(1);
  });

  test("upstream reads pause while the peer has not accepted the previous chunk", async () => {
    const big = Buffer.alloc(8 * 1024 * 1024, 0x61);
    const port = await listen(net.createServer((socket) => { socket.on("error", () => {}); socket.write(big); }));
    const p = fakePeer({ gateData: true });
    startRun(port, p.peer);
    await until(() => p.dataCalls() === 1);
    await settle(150);
    expect(p.dataCalls()).toBe(1);
    p.releaseData();
    await until(() => p.dataCalls() === 2);
  });

  // Bun keeps draining a server socket its owner paused, so a genuinely full
  // kernel buffer cannot be produced here; the socket's own answer to a full
  // buffer is what the run has to honour, so that answer is forced instead.
  test("a write the socket pushes back on stays pending until it drains, and a close also releases it", async () => {
    const port = await listen(net.createServer((socket) => { socket.on("error", () => {}); }));
    for (const releaseWith of ["drain", "close"] as const) {
      const p = fakePeer();
      const { run } = startRun(port, p.peer);
      await until(() => p.events.includes("ready"));
      const socket = (run as unknown as { socket: net.Socket }).socket;
      socket.write = (() => false) as typeof socket.write;
      let resolved = false;
      const pending = run.write(Buffer.from("x")).then(() => { resolved = true; });
      await settle(50);
      expect(resolved).toBe(false);
      socket.emit(releaseWith);
      await pending;
      expect(resolved).toBe(true);
      run.end();
    }
  });

  test("the connect timeout is inert once the upstream has connected", async () => {
    // The socket's idle clock keeps running after a connect unless it is
    // cleared; an idle tunnel must outlive the connect timeout untouched.
    const port = await listen(net.createServer((socket) => { socket.on("error", () => {}); }));
    const p = fakePeer();
    startRun(port, p.peer, 30);
    await until(() => p.events.includes("ready"));
    await settle(120);
    expect(p.events).toEqual(["ready"]);
  });

  test("an upstream that never reads or closes is destroyed after the bound, releasing a parked write", async () => {
    const port = await listen(net.createServer((socket) => { socket.on("error", () => {}); }));
    const p = fakePeer();
    const { run } = startRun(port, p.peer, undefined, 5_000, 150);
    await until(() => p.events.includes("ready"));
    const socket = (run as unknown as { socket: net.Socket }).socket;
    socket.write = (() => false) as typeof socket.write;
    let resolved = false;
    const pending = run.write(Buffer.from("x")).then(() => { resolved = true; });
    await settle(30);
    run.end();
    await settle(50);
    expect(resolved).toBe(false);
    await pending;
    expect(socket.destroyed).toBe(true);
  });

  describe("ending while the upstream is still writing", () => {
    /** A raw net upstream in a separate Node process, which reports what its
     *  own socket saw. Bun does not surface a peer's reset on an in-process
     *  server, so this is the only place a reset is observable. */
    async function spawnUpstream(totalBytes: number) {
      const child = spawn("node", [fileURLToPath(new URL("./support/tunnel-tcp-upstream.mjs", import.meta.url)), String(totalBytes)], {
        stdio: ["ignore", "pipe", "inherit"],
      });
      const lines: string[] = [];
      let buffered = "";
      child.stdout.on("data", (d: Buffer) => {
        buffered += d.toString();
        const parts = buffered.split("\n");
        buffered = parts.pop() ?? "";
        lines.push(...parts.filter(Boolean));
      });
      onTestFinished(() => { child.kill(); });
      await until(() => lines.some((l) => l.startsWith("listening ")), 10_000);
      const port = Number(lines.find((l) => l.startsWith("listening "))!.split(" ")[1]);
      return { port, lines };
    }

    test("a body the upstream finishes inside the drain window ends without a reset", async () => {
      const up = await spawnUpstream(4 * 1024 * 1024);
      const p = fakePeer();
      const { run } = startRun(up.port, p.peer, undefined, 2_000);
      await until(() => p.dataCalls() > 0);
      run.end();
      await until(() => up.lines.includes("close"), 10_000);
      expect(up.lines.filter((l) => l.startsWith("error"))).toEqual([]);
      expect(up.lines).toContain("end");
    }, 30_000);

    test("an upstream that never finishes is half-closed once the drain window passes, and the run releases it", async () => {
      const up = await spawnUpstream(512 * 1024 * 1024);
      const p = fakePeer();
      const { run, settledCount } = startRun(up.port, p.peer, undefined, 100);
      await until(() => p.dataCalls() > 0);
      run.end();
      expect(settledCount()).toBe(1);
      await until(() => up.lines.includes("close"), 20_000);
      // The upstream was mid-body when the browser gave up, so it may see a
      // reset here, as it would from a real browser; it must not hang.
      expect(up.lines.filter((l) => l.startsWith("error")).every((l) => l === "error ECONNRESET" || l === "error EPIPE")).toBe(true);
    }, 30_000);
  });
});

describe("probeTls", () => {
  test("a port nothing listens on is unreachable", async () => {
    const result = await probeTls(await deadPort(), 1_000);
    expect(result.reachable).toBe(false);
  });

  test("a plaintext server that answers a ClientHello with an error is reachable and not TLS", async () => {
    const port = await listen(net.createServer((socket) => {
      socket.on("error", () => {});
      socket.on("data", () => socket.end("HTTP/1.1 400 Bad Request\r\nconnection: close\r\n\r\n"));
    }));
    expect(await probeTls(port, 2_000)).toEqual({ reachable: true, tls: false });
  });

  test("a plaintext server that stays silent is reachable, not TLS, once the probe times out", async () => {
    const port = await listen(net.createServer((socket) => { socket.on("error", () => {}); }));
    const started = Date.now();
    expect(await probeTls(port, 150)).toEqual({ reachable: true, tls: false });
    expect(Date.now() - started).toBeLessThan(2_000);
  });

  test("a TLS server that rejects the handshake with an alert is still TLS", async () => {
    // TLS 1.2 only, and this server insists on a client certificate: the
    // probe presents none, so the server answers with an alert.
    const server = tls.createServer({
      cert: SELF_SIGNED_LOCALHOST_CERT,
      key: SELF_SIGNED_LOCALHOST_KEY,
      maxVersion: "TLSv1.2",
      requestCert: true,
      rejectUnauthorized: true,
    }, (socket) => { socket.on("error", () => {}); });
    server.on("tlsClientError", () => {});
    const port = await listen(server);
    expect(await probeTls(port, 3_000)).toEqual({ reachable: true, tls: true });
    await settle(100);
  });

  test("a server that resets the connection on the ClientHello is not TLS", async () => {
    const port = await listen(net.createServer((socket) => { socket.on("error", () => {}); socket.resetAndDestroy(); }));
    expect(await probeTls(port, 2_000)).toEqual({ reachable: true, tls: false });
  });

  test("a TLS server with a self-signed certificate is reachable and TLS", async () => {
    const server = tls.createServer({ cert: SELF_SIGNED_LOCALHOST_CERT, key: SELF_SIGNED_LOCALHOST_KEY }, (socket) => {
      socket.on("error", () => {});
    });
    server.on("tlsClientError", () => {});
    const port = await listen(server);
    expect(await probeTls(port, 3_000)).toEqual({ reachable: true, tls: true });
    // The probe's own socket may error after its verdict; that must not escape.
    await settle(100);
  });
});
