import { z } from "zod";
import { agentHost, processGroupSpawn, withAgentHost } from "../../host";
import { prepareCliTerminalLaunch, type PreparedTerminalLaunch, type TerminalLaunchRequest } from "../terminal-launch";
import { toolSpawnArgs } from "../windows-argv";

const SessionList = z.array(z.object({ id: z.string().min(1) }));
const NativeId = z.string().regex(/^[A-Za-z0-9][A-Za-z0-9_-]*$/);

type RunCli = (args: string[], request: TerminalLaunchRequest) => Promise<string>;

export function parseKimiForkId(output: string, sourceId: string): string {
  const matches = [...output.matchAll(/^Forked to ([A-Za-z0-9_-]+)(?: \("[^\r\n]*"\))? in \d+ms\r?$/gm)];
  if (matches.length !== 1 || matches[0]![1] === sourceId || !NativeId.safeParse(matches[0]![1]).success) {
    throw new Error("Kimi did not report an independent fork ID. Recover the fork in Kimi before retrying.");
  }
  return NativeId.parse(matches[0]![1]);
}

/** CLI fork preserves its source workspace; --cwd only controls source lookup. */
export async function prepareKimiTerminal(
  request: TerminalLaunchRequest,
  runCli?: RunCli,
): Promise<PreparedTerminalLaunch> {
  if (request.conversation.kind === "fresh") return prepareCliTerminalLaunch(request);
  if (request.conversation.kind === "fork" && request.initialPrompt?.trim()) throw new Error("Send a prompt after the Kimi fork opens.");
  const sourceId = NativeId.parse(request.conversation.kind === "fork" ? request.conversation.sourceSessionId : request.conversation.sessionId);
  const host = runCli ? undefined : agentHost();
  const run = runCli ?? ((args, req) => withAgentHost(host!, () => runKimiCli(args, req)));
  // Archived conversations are listed only on request, yet `--session` and `fork` still open them.
  const sessions = SessionList.parse(JSON.parse(await run(["session", "list", "--cwd", request.cwd, "--archived", "--json"], request)));
  // Gone from Kimi's store, or kept under another directory: a refusal here
  // would fail every later Start of this slot the same way.
  if (!sessions.some(session => session.id === sourceId)) {
    return prepareCliTerminalLaunch({ ...request, conversation: { kind: "fresh" } });
  }
  if (request.conversation.kind === "resume") return prepareCliTerminalLaunch(request);
  const resumeLaunch = (nativeId: string) => prepareCliTerminalLaunch({
    ...request,
    conversation: { kind: "resume", sessionId: nativeId },
  });
  // Build and validate the eventual invocation before the provider mutation.
  const pending = resumeLaunch(sourceId);
  return {
    ...pending,
    resumed: false,
    createNativeFork: async () => {
      const output = await run(["fork", "--yes", sourceId], request);
      const nativeId = parseKimiForkId(output, sourceId);
      return { nativeId, launch: host ? withAgentHost(host, () => resumeLaunch(nativeId)) : resumeLaunch(nativeId) };
    },
  };
}

async function runKimiCli(args: string[], request: TerminalLaunchRequest): Promise<string> {
  request.signal.throwIfAborted();
  const host = agentHost();
  const command = request.tool ? "kimi" : request.configured.command;
  // `kimi fork` fires SessionStart for the new session, and the injected
  // identity hook posts whenever this is set: a bridge running inside an
  // Antgrid terminal would bind the fork's id and title to that terminal.
  const { ANTGRID_TERMINAL_ID: _terminal, ...env } = process.env;
  const launch = toolSpawnArgs(command, args, env);
  const proc = Bun.spawn(launch.cmd, {
    cwd: request.cwd,
    env: launch.env,
    ...processGroupSpawn(),
    stdin: "ignore", stdout: "pipe", stderr: "ignore",
  });
  let finished = false;
  let termination: Promise<void> | undefined;
  const terminate = () => finished ? Promise.resolve() : termination ??= host.killChildTree({ pid: proc.pid, kill: () => proc.kill() });
  request.scope.registerCleanup(terminate);
  const timeout = setTimeout(() => { void terminate().catch(() => {}); }, 30_000);
  try {
    const reader = proc.stdout.getReader();
    const chunks: Uint8Array[] = [];
    let bytes = 0;
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      bytes += value.length;
      if (bytes > 4 * 1024 * 1024) throw new Error("Kimi session metadata exceeded the output limit.");
      chunks.push(value);
    }
    const code = await proc.exited;
    finished = true;
    request.signal.throwIfAborted();
    if (termination || code !== 0) throw new Error("Kimi could not complete the native session operation. Check the installed CLI version and its session store.");
    return Buffer.concat(chunks).toString("utf8");
  } finally {
    clearTimeout(timeout);
    await terminate();
  }
}
