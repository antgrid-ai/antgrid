import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { AGENTS, BY_HOOK_NAME } from "./agent-runtime";
import type { HookInvocation, HookPath, HookPost } from "antgrid-agents/hook-posts";
import type { HookProfile } from "antgrid-agents/contracts";

export type { HookInvocation, HookPath, HookPost };

export const MAX_HOOK_STDIN_BYTES = 64 * 1024;
// Fallback drain deadline for agents that emit hook JSON then hold stdin open
// (copilot does): the read normally resolves on stdin `end`, so this only bounds
// the hold-open case. Kept generous to match the deleted node scripts' ~4.5s
// budget — a 500ms cap truncated slow payloads and dropped the session id.
const HOOK_STDIN_TIMEOUT_MS = 4500;
// Upper bound on a single loopback POST. The deleted scripts were fire-and-forget
// (kernel-buffered, effectively unbounded); a 500ms abort dropped posts whenever
// the single-threaded bridge was busy > 500ms (e.g. /session-title reading a
// transcript). Loopback normally completes in milliseconds.
const HOOK_POST_TIMEOUT_MS = 4000;
const HOOK_OUTPUT_TIMEOUT_MS = 1500;
const MAX_HOOK_REPLY_BYTES = 1024;
const MAX_HOOK_OUTPUT_BYTES = 4096;

export interface HookRunnerDeps {
  env: Record<string, string | undefined>;
  readStdin: () => Promise<string>;
  readFile: (path: string) => string;
  post: (post: HookPost) => Promise<void>;
  request?: (post: HookPost) => Promise<unknown>;
  writeStdout?: (output: string) => void | Promise<void>;
}

function parsePort(raw: string | undefined): number | null {
  if (!raw || !/^\d+$/.test(raw.trim())) return null;
  const value = Number(raw.trim());
  return Number.isInteger(value) && value >= 1 && value <= 65535 ? value : null;
}

function resolvePort(
  hooks: HookProfile,
  deps: Pick<HookRunnerDeps, "env" | "readFile">,
): number | null {
  const direct = parsePort(deps.env.ANTGRID_API_PORT);
  if (direct !== null) return direct;
  if (!hooks.portFileFallback) return null;
  const dir = deps.env.ANTGRID_DIR || `${homedir()}/.antgrid`;
  try {
    return parsePort(deps.readFile(`${dir.replace(/[\\/]$/, "")}/api.port`));
  } catch {
    return null;
  }
}

/**
 * The hook dispatch boundary: hook name → registry key → the agent's own hook
 * profile. An unknown name, an agent with no hook profile, or an event outside
 * that profile's allowlist all drop the invocation before any payload is read.
 */
async function buildPosts(
  invocation: HookInvocation,
  deps: HookRunnerDeps,
): Promise<HookPost[]> {
  const key = BY_HOOK_NAME[invocation.agent];
  const hooks = key === undefined ? undefined : AGENTS[key].hooks;
  if (!hooks?.events.includes(invocation.event)) return [];
  const port = resolvePort(hooks, deps);
  if (port === null) return [];
  const posts = await hooks.toPosts(invocation, {
    port,
    terminalId: deps.env.ANTGRID_TERMINAL_ID,
    readStdin: deps.readStdin,
  });
  const runId = deps.env.ANTGRID_RUN_ID;
  return runId ? posts.map((post) => ({ ...post, body: { ...post.body, runId } })) : posts;
}

async function defaultPost(post: HookPost): Promise<void> {
  await fetch(hookUrl(post), {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(post.body),
    signal: AbortSignal.timeout(HOOK_POST_TIMEOUT_MS),
  });
}

function hookUrl(post: HookPost): string {
  const url = new URL(post.path, `http://127.0.0.1:${post.port}`);
  for (const [key, value] of Object.entries(post.query ?? {})) url.searchParams.set(key, value);
  return url.href;
}

async function defaultRequest(post: HookPost): Promise<unknown> {
  const response = await fetch(hookUrl(post), {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(post.body),
    redirect: "error",
    signal: AbortSignal.timeout(HOOK_OUTPUT_TIMEOUT_MS),
  });
  if (!response.ok || !response.body) {
    await response.body?.cancel();
    return null;
  }
  const reader = response.body.getReader();
  const chunks: Uint8Array[] = [];
  let bytes = 0;
  try {
    while (true) {
      const part = await reader.read();
      if (part.done) break;
      bytes += part.value.byteLength;
      if (bytes > MAX_HOOK_REPLY_BYTES) return null;
      chunks.push(part.value);
    }
    return JSON.parse(Buffer.concat(chunks).toString("utf8"));
  } finally {
    await reader.cancel();
  }
}

async function writeHookOutput(invocation: HookInvocation, deps: HookRunnerDeps): Promise<void> {
  const key = BY_HOOK_NAME[invocation.agent];
  const hooks = key === undefined ? undefined : AGENTS[key].hooks;
  const stdout = hooks?.stdout;
  if (!hooks?.events.includes(invocation.event) || !stdout?.events.includes(invocation.event)) return;
  const port = parsePort(deps.env.ANTGRID_API_PORT);
  const terminalId = deps.env.ANTGRID_TERMINAL_ID;
  const runId = deps.env.ANTGRID_RUN_ID;
  if (port === null || !terminalId?.trim() || !runId?.trim() || !deps.request || !deps.writeStdout) return;
  const response = await deps.request(stdout.request({ port, terminalId, runId }));
  const output = stdout.formatResponse(response);
  if (output === null) return;
  const parsed = stdout.outputSchema.safeParse(output);
  if (!parsed.success) return;
  const serialized = JSON.stringify(parsed.data);
  if (Buffer.byteLength(serialized, "utf8") <= MAX_HOOK_OUTPUT_BYTES) await deps.writeStdout(`${serialized}\n`);
}

function defaultDeps(): HookRunnerDeps {
  return {
    env: process.env,
    readStdin: () => readHookStdin(process.stdin),
    readFile: (path) => readFileSync(path, "utf8"),
    post: defaultPost,
    request: defaultRequest,
    writeStdout: (output) => new Promise((resolve, reject) => {
      process.stdout.write(output, (error) => error ? reject(error) : resolve());
    }),
  };
}

export async function runHookInvocation(
  invocation: HookInvocation,
  deps: HookRunnerDeps = defaultDeps(),
): Promise<void> {
  try {
    await Promise.allSettled([
      buildPosts(invocation, deps).then((posts) => Promise.allSettled(posts.map((post) => deps.post(post)))),
      writeHookOutput(invocation, deps),
    ]);
  } catch {
    // Hooks are advisory; an integration failure must never block the agent.
  }
}

export function readHookStdin(
  stdin: NodeJS.ReadableStream,
  timeoutMs: number = HOOK_STDIN_TIMEOUT_MS,
): Promise<string> {
  return new Promise((resolve) => {
    const chunks: Buffer[] = [];
    let bytes = 0;
    let settled = false;
    const onData = (chunk: string | Buffer) => {
      if (bytes >= MAX_HOOK_STDIN_BYTES) return;
      const buffer = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
      const remaining = MAX_HOOK_STDIN_BYTES - bytes;
      const accepted = buffer.subarray(0, remaining);
      chunks.push(accepted);
      bytes += accepted.length;
    };
    const finish = () => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      // Detach every listener and unref the handle so a stdin the agent left
      // open can't keep this short-lived hook process alive past resolution.
      stdin.removeListener("data", onData);
      stdin.removeListener("end", finish);
      stdin.removeListener("error", finish);
      (stdin as NodeJS.ReadableStream & { unref?: () => void }).unref?.();
      resolve(Buffer.concat(chunks, bytes).toString("utf8"));
    };
    stdin.on("data", onData);
    stdin.once("end", finish);
    stdin.once("error", finish);
    const timer = setTimeout(finish, timeoutMs);
  });
}
