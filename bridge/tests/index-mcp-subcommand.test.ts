import { expect, test } from "bun:test";
import { join } from "node:path";

const PROTOCOL_VERSION = "2024-11-05";

/**
 * Newline-delimited JSON-RPC over the child's stdio, read one line at a time.
 * Every line is parsed, which is the point as much as the responses are: the
 * bridge's logger writes to fd 1 by default, and one log line on this stream
 * breaks the transport with nothing in our own logs to say so.
 */
class StdioRpc {
  private buffered = "";
  private lines: string[] = [];
  private decoder = new TextDecoder();

  constructor(
    private readonly reader: ReadableStreamDefaultReader<Uint8Array>,
    private readonly stdin: { write(data: string): void },
  ) {}

  send(message: unknown): void {
    this.stdin.write(`${JSON.stringify(message)}\n`);
  }

  async nextFrame(): Promise<any> {
    while (this.lines.length === 0) {
      const { value, done } = await this.reader.read();
      if (done) throw new Error("mcp server closed stdout before answering");
      this.buffered += this.decoder.decode(value, { stream: true });
      const parts = this.buffered.split("\n");
      this.buffered = parts.pop() ?? "";
      this.lines.push(...parts.filter((line) => line.trim().length > 0));
    }
    const line = this.lines.shift()!;
    const frame = JSON.parse(line);
    expect(frame.jsonrpc).toBe("2.0");
    return frame;
  }

  async call(id: number, method: string, params: unknown): Promise<any> {
    this.send({ jsonrpc: "2.0", id, method, params });
    const frame = await this.nextFrame();
    expect(frame.id).toBe(id);
    expect(frame.error).toBeUndefined();
    return frame.result;
  }
}

test("mcp subcommand serves the antgrid tools over stdio against the stamped core", async () => {
  const requested: string[] = [];
  const server = Bun.serve({
    hostname: "127.0.0.1",
    port: 0,
    fetch(req) {
      const url = new URL(req.url);
      requested.push(`${req.method} ${url.pathname}${url.search}`);
      return new Response("[]", { headers: { "content-type": "application/json" } });
    },
  });
  const entry = join(import.meta.dir, "..", "src", "index.ts");
  const proc = Bun.spawn([process.execPath, entry, "mcp"], {
    env: {
      ...process.env,
      ANTGRID_API_PORT: String(server.port),
      ANTGRID_TERMINAL_ID: "term-cli",
    },
    stdin: "pipe",
    stdout: "pipe",
    stderr: "pipe",
  });

  try {
    const rpc = new StdioRpc(proc.stdout.getReader(), proc.stdin);

    const initialized = await rpc.call(1, "initialize", {
      protocolVersion: PROTOCOL_VERSION,
      capabilities: {},
      clientInfo: { name: "antgrid-test", version: "0.0.0" },
    });
    expect(initialized.serverInfo.name).toBe("antgrid");
    rpc.send({ jsonrpc: "2.0", method: "notifications/initialized" });

    // One table, the same for every caller: listing it costs no request at all,
    // and the bus tools are in it whether or not this terminal can use one.
    const listed = await rpc.call(2, "tools/list", {});
    expect(listed.tools.map((t: { name: string }) => t.name)).toEqual([
      "antgrid_init",
      "antgrid_list_commands",
      "antgrid_run_command",
      "antgrid_list_terminals",
      "antgrid_read_terminal",
      "antgrid_list_sessions",
      "antgrid_publish_artifact",
      "antgrid_list_artifacts",
      "antgrid_get_artifact",
      "antgrid_post",
      "antgrid_notify",
      "antgrid_reply",
      "antgrid_inbox",
      "antgrid_thread",
    ]);

    const called = await rpc.call(3, "tools/call", {
      name: "antgrid_list_terminals",
      arguments: {},
    });
    expect(called.content[0].text).toBe("No active terminals");
    // The slot rides on every request: the core answers the checkout-variable
    // routes out of the CALLER's checkout, and this is the only thing that
    // names it.
    expect(requested).toEqual([
      "GET /terminals?all=false&terminalId=term-cli",
    ]);
  } finally {
    proc.stdin.end();
    proc.kill();
    await proc.exited;
    server.stop(true);
  }
});
