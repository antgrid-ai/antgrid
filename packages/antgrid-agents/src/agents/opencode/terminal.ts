import { OpenCode } from "@opencode/client";
import { agentHost, processGroupSpawn, withAgentHost } from "../../host";
import { prepareCliTerminalLaunch, type TerminalLaunchRequest } from "../terminal-launch";
import { toolSpawnArgs } from "../windows-argv";
import { raceTimeout } from "../race-timeout";
import { requireOpencodeV2 } from "./version";
import { startOpencodeServer } from "./server";

// Every OpenCode process Antgrid starts owns its own MCP identity: a shared
// background server would inherit another terminal's.
export const OPENCODE_STANDALONE = "--standalone";

export async function prepareOpencodeTerminal(
  request: TerminalLaunchRequest,
  readVersion = probeVersion,
) {
  const command = request.tool ? "opencode" : request.configured.command;
  requireOpencodeV2(await readVersion(command, request));
  request.signal.throwIfAborted();
  const configured = request.tool ? request.configured : { ...request.configured, args: [OPENCODE_STANDALONE, ...request.configured.args ?? []] };
  const source = request.conversation.kind === "fork" ? request.conversation.sourceSessionId : undefined;
  if (source && request.initialPrompt?.trim()) throw new Error("Send a prompt after the OpenCode fork opens.");
  const resume = (sessionId: string) => prepareCliTerminalLaunch({ ...request, configured, conversation: { kind: "resume", sessionId } });
  const launch = source ? resume(source) : prepareCliTerminalLaunch({ ...request, configured });
  if (source) {
    const host = agentHost();
    return { ...launch, resumed: false, createNativeFork: () => withAgentHost(host, async () => {
      const server = await startOpencodeServer({ command, cwd: request.cwd, env: launch.env, signal: request.signal });
      request.scope.registerCleanup(server.close);
      try {
        const fork = await OpenCode.make({ baseUrl: server.url, headers: server.headers }).session.fork({ sessionID: source }, { signal: request.signal });
        return { nativeId: fork.id, launch: resume(fork.id) };
      } finally { await server.close(); }
    }) };
  }
  return launch;
}

async function probeVersion(command: string, request: TerminalLaunchRequest): Promise<string | undefined> {
  request.signal.throwIfAborted();
  const host = agentHost();
  const launch = toolSpawnArgs(command, ["--version"], process.env);
  const proc = Bun.spawn(launch.cmd, {
    cwd: request.cwd, ...processGroupSpawn(), stdin: "ignore", stdout: "pipe", stderr: "ignore",
    env: launch.env,
  });
  let exited = false;
  let termination: Promise<void> | undefined;
  const cleanup = () => exited ? Promise.resolve() : termination ??= (async () => {
    await host.killChildTree(proc);
    if (!await raceTimeout(proc.exited, 5_000)) throw new Error("OpenCode version probe did not exit after termination");
  })();
  request.scope.registerCleanup(cleanup);
  const signal = AbortSignal.any([request.signal, AbortSignal.timeout(10_000)]);
  let abort!: () => void;
  try {
    const result = await Promise.race([
      Promise.all([new Response(proc.stdout).text(), proc.exited.then((code) => { exited = true; return code; })]),
      new Promise<never>((_, reject) => {
        abort = () => reject(signal.reason);
        signal.addEventListener("abort", abort, { once: true });
        if (signal.aborted) abort();
      }),
    ]);
    if (result[1] !== 0) throw new Error("Could not check the installed OpenCode version. Run opencode --version and retry.");
    return result[0].trim().match(/^(?:opencode\s+)?v?(\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?)$/i)?.[1];
  } finally {
    signal.removeEventListener("abort", abort);
    await cleanup();
  }
}
