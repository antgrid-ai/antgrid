import { resolve } from "node:path";

// Proves bun --compile actually bundled @modelcontextprotocol/sdk into the
// compiled binary: the SDK is dual CJS/ESM with deep subpath exports reached
// through a lazy `await import()`, so a bundler mis-resolution shows up only
// here, never in `bun test` against the dev entrypoint. Modeled on
// smoke-hook-binary.ts (PATH emptied, binary supplied as argv[2]) and on
// bridge/tests/index-mcp-subcommand.test.ts (the newline-delimited JSON-RPC
// framing), hand-rolled rather than pulling in the SDK client so the compiled
// artifact stays the only thing under test.

const PROTOCOL_VERSION = "2024-11-05";
const EXPECTED_TOOLS = [
  "antgrid_init",
  "antgrid_list_commands",
  "antgrid_run_command",
  "antgrid_list_terminals",
  "antgrid_read_terminal",
];

const binaryArg = process.argv[2];
if (!binaryArg) throw new Error("usage: smoke-mcp-binary.ts <bridge-binary>");
const binary = resolve(binaryArg);
const emptyPath = resolve("dist", ".mcp-smoke-empty-path");

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
      if (done) throw new Error("mcp binary closed stdout before answering");
      this.buffered += this.decoder.decode(value, { stream: true });
      const parts = this.buffered.split("\n");
      this.buffered = parts.pop() ?? "";
      this.lines.push(...parts.filter((line) => line.trim().length > 0));
    }
    const line = this.lines.shift()!;
    let frame: any;
    try {
      frame = JSON.parse(line);
    } catch {
      throw new Error(`non-JSON-RPC line on stdout: ${JSON.stringify(line)}`);
    }
    if (frame.jsonrpc !== "2.0") {
      throw new Error(`non-JSON-RPC line on stdout: ${JSON.stringify(line)}`);
    }
    return frame;
  }

  async call(id: number, method: string, params: unknown): Promise<any> {
    this.send({ jsonrpc: "2.0", id, method, params });
    const frame = await this.nextFrame();
    if (frame.id !== id) throw new Error(`expected response id ${id}, got ${frame.id}`);
    if (frame.error) throw new Error(`${method} errored: ${JSON.stringify(frame.error)}`);
    return frame.result;
  }
}

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

const child = Bun.spawn([binary, "mcp"], {
  env: {
    PATH: emptyPath,
    ANTGRID_API_PORT: String(server.port),
    ANTGRID_TERMINAL_ID: "compiled-mcp-smoke",
    ...(process.env.SystemRoot ? { SystemRoot: process.env.SystemRoot } : {}),
    ...(process.env.SYSTEMROOT ? { SYSTEMROOT: process.env.SYSTEMROOT } : {}),
  },
  stdin: "pipe",
  stdout: "pipe",
  stderr: "pipe",
});

try {
  const rpc = new StdioRpc(child.stdout.getReader(), child.stdin);

  const initialized = await rpc.call(1, "initialize", {
    protocolVersion: PROTOCOL_VERSION,
    capabilities: {},
    clientInfo: { name: "antgrid-mcp-smoke", version: "0.0.0" },
  });
  if (initialized?.serverInfo?.name !== "antgrid") {
    throw new Error(`unexpected serverInfo: ${JSON.stringify(initialized?.serverInfo)}`);
  }
  rpc.send({ jsonrpc: "2.0", method: "notifications/initialized" });

  const listed = await rpc.call(2, "tools/list", {});
  const toolNames = (listed.tools as { name: string }[]).map((t) => t.name);
  if (JSON.stringify(toolNames) !== JSON.stringify(EXPECTED_TOOLS)) {
    throw new Error(`unexpected tool list: ${JSON.stringify(toolNames)}`);
  }

  const called = await rpc.call(3, "tools/call", {
    name: "antgrid_list_terminals",
    arguments: {},
  });
  // With the caller's slot on it: the compiled binary has to read
  // ANTGRID_TERMINAL_ID out of its own environment for the core to answer the
  // checkout-variable routes out of the right tree.
  if (!requested.includes("GET /terminals?all=false&terminalId=compiled-mcp-smoke")) {
    throw new Error(`compiled mcp binary never reached the loopback API: ${JSON.stringify(requested)}`);
  }
  if (called.isError) {
    throw new Error(`antgrid_list_terminals call reported an error: ${JSON.stringify(called)}`);
  }

  child.stdin.end();

  const [exitCode, stderr] = await Promise.all([
    Promise.race([
      child.exited,
      Bun.sleep(5_000).then(() => {
        throw new Error("compiled mcp binary did not exit within 5s of stdin closing");
      }),
    ]),
    new Response(child.stderr).text(),
  ]);

  if (exitCode !== 0) throw new Error(`compiled mcp binary exited ${exitCode}`);
  if (stderr !== "") throw new Error(`compiled mcp binary wrote to stderr: ${JSON.stringify(stderr)}`);
} finally {
  child.kill();
  server.stop(true);
}
