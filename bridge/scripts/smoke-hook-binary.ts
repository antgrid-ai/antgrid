import { resolve } from "node:path";

const binaryArg = process.argv[2];
if (!binaryArg) throw new Error("usage: smoke-hook-binary.ts <bridge-binary>");

const binary = resolve(binaryArg);
const emptyPath = resolve("dist", ".hook-smoke-empty-path");
let received: { path: string; body: unknown } | undefined;
let receiveRequest!: () => void;
const requestReceived = new Promise<void>((resolveRequest) => {
  receiveRequest = resolveRequest;
});

const server = Bun.serve({
  port: 0,
  hostname: "127.0.0.1",
  async fetch(request) {
    received = {
      path: new URL(request.url).pathname,
      body: await request.json(),
    };
    receiveRequest();
    return new Response(null, { status: 204 });
  },
});

try {
  const child = Bun.spawn([binary, "hook", "cursor", "session-start"], {
    env: {
      PATH: emptyPath,
      ANTGRID_API_PORT: String(server.port),
      ANTGRID_TERMINAL_ID: "compiled-hook-smoke",
      ...(process.env.SystemRoot ? { SystemRoot: process.env.SystemRoot } : {}),
      ...(process.env.SYSTEMROOT ? { SYSTEMROOT: process.env.SYSTEMROOT } : {}),
    },
    stdin: "pipe",
    stdout: "pipe",
    stderr: "pipe",
  });

  child.stdin.write(`\uFEFF${JSON.stringify({ session_id: "smoke-session" })}`);
  child.stdin.end();

  const [exitCode, stdout, stderr, didReceiveRequest] = await Promise.all([
    child.exited,
    new Response(child.stdout).text(),
    new Response(child.stderr).text(),
    Promise.race([
      requestReceived.then(() => true),
      Bun.sleep(2_000).then(() => false),
    ]),
  ]);

  if (exitCode !== 0) throw new Error(`compiled hook exited ${exitCode}`);
  if (stdout !== "" || stderr !== "") {
    throw new Error(
      `compiled hook produced output: stdout=${JSON.stringify(stdout)} stderr=${JSON.stringify(stderr)}`,
    );
  }
  if (!didReceiveRequest) {
    throw new Error("compiled hook exited cleanly without reaching the loopback endpoint");
  }
  if (received?.path !== "/session-title") {
    throw new Error(`unexpected hook route: ${received?.path ?? "none"}`);
  }
  const body = received.body as Record<string, unknown>;
  if (
    body.terminalId !== "compiled-hook-smoke" ||
    body.sessionId !== "smoke-session" ||
    body.agent !== "cursor"
  ) {
    throw new Error(`unexpected hook body: ${JSON.stringify(body)}`);
  }
} finally {
  server.stop(true);
}
