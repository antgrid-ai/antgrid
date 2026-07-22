import { expect, test } from "bun:test";
import { join } from "node:path";

test("hook subcommand posts through the source entrypoint without reading bootstrap credentials", async () => {
  let received: unknown;
  const server = Bun.serve({
    hostname: "127.0.0.1",
    port: 0,
    async fetch(req) {
      received = await req.json();
      return new Response("{}", { headers: { "content-type": "application/json" } });
    },
  });
  try {
    const entry = join(import.meta.dir, "..", "src", "index.ts");
    const proc = Bun.spawn(
      [process.execPath, entry, "hook", "cursor", "session-start"],
      {
        env: {
          ...process.env,
          ANTGRID_API_PORT: String(server.port),
          ANTGRID_TERMINAL_ID: "term-cli",
        },
        stdin: "pipe",
        stdout: "pipe",
        stderr: "pipe",
      },
    );
    proc.stdin.write(`\uFEFF${JSON.stringify({ session_id: "cursor-cli" })}`);
    proc.stdin.end();
    expect(await proc.exited).toBe(0);
    expect(received).toEqual({
      terminalId: "term-cli",
      sessionId: "cursor-cli",
      agent: "cursor",
    });
    expect(await new Response(proc.stdout).text()).toBe("");
    expect(await new Response(proc.stderr).text()).toBe("");
  } finally {
    server.stop(true);
  }
});
