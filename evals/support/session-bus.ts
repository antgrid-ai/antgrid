import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";
import type { AbMessage } from "../../bridge/src/protocol";
import { renderNotify, renderReply } from "../../bridge/src/session-bus/delivery";
import type { RelayClient } from "../helpers/relay-client";

/**
 * Session-bus test glue: the PTY sink, the persisted-session reader, and the
 * loopback HTTP callers every bus scenario needs.
 *
 * Outside `evals/helpers/` for the reason `stream.ts` is — the harness is a
 * frozen shared surface.
 */

const RUN_HOOK_SCRIPT = resolve(import.meta.dir, "run-hook.ts");
// This process IS the bun binary running the eval suite (`bun test`), so its
// own execPath is a reliable absolute path to spawn a sibling `bun run` from —
// unlike a bare "bun", which depends on the sink PTY's inherited PATH agreeing
// with this one.
const BUN_EXECUTABLE = process.execPath;

// Framing for a simulated hook call written into the sink PTY's own stdin (see
// `hookTriggerData`). Never appears in real delivered content — the delivery
// templates are plain prose — so scanning the raw stdin stream for it is safe
// alongside the sink's own verbatim logging.
const HOOK_TRIGGER_MARKER = "ANTGRID_HOOK";

// The receiving session's PTY is a stdin sink rather than an agent: these
// scenarios assert WHEN a line reaches the terminal, so the guest only has to
// record what it was given. Raw mode keeps the ConPTY line discipline from
// holding the write back until a newline the bridge never sends on its own.
//
// It ALSO doubles as a hook trigger: a chunk containing `HOOK_TRIGGER_MARKER`
// spawns `run-hook.ts` as ITS OWN child — inheriting this PTY's real
// `ANTGRID_RUN_ID`/`ANTGRID_API_PORT`/`ANTGRID_TERMINAL_ID`, exactly as a real
// agent's hook subprocess does — instead of a test faking the loopback POST
// body directly, which `acceptsHookRun`'s runId-staleness gate now refuses
// (see `hookTriggerData`'s doc).
export const SINK_SCRIPT = `const fs = require("node:fs");
const { spawn } = require("node:child_process");
const sink = process.env.ANTGRID_EVAL_SINK;
const MARKER = ${JSON.stringify(HOOK_TRIGGER_MARKER)};
const RUN_HOOK = ${JSON.stringify(RUN_HOOK_SCRIPT)};
const BUN_EXE = ${JSON.stringify(BUN_EXECUTABLE)};
try { process.stdin.setRawMode(true); } catch {}
process.stdin.on("data", (d) => {
  try { fs.appendFileSync(sink, d); } catch {}
  const text = d.toString("utf8");
  const idx = text.indexOf(MARKER);
  if (idx === -1) return;
  try {
    const spec = JSON.parse(text.slice(idx + MARKER.length));
    const child = spawn(BUN_EXE, ["run", RUN_HOOK, spec.agent, spec.event], {
      env: process.env,
      stdio: ["ignore", "ignore", "ignore"],
    });
    child.unref();
  } catch {}
});
process.stdin.resume();
setInterval(() => {}, 1 << 30);
`;
export const SINK_SCRIPT_NAME = "antgrid-eval-sink.cjs";

/**
 * The `terminal:input` payload that simulates one real agent hook firing for
 * the receiving sink session, written raw into its PTY's stdin.
 *
 * This is the faithful alternative to POSTing `/turn-start`/`/notify` on the
 * loopback API directly: a bare loopback POST with no `runId` is exactly what
 * `SessionManager.acceptsHookRun` exists to reject as stale, and a bare
 * terminal-mode sink session has no real agent hook config to fire it for
 * real. Routing the trigger through the sink's OWN stdin lets `run-hook.ts`
 * spawn as that session's own child process, inheriting the correct
 * `ANTGRID_RUN_ID` the bridge stamped on it at spawn.
 */
export function hookTriggerData(agent: string, event: string): string {
  return `${HOOK_TRIGGER_MARKER}${JSON.stringify({ agent, event })}`;
}

/** The marker `run-hook.ts` appends to the sink once it has attempted its
 *  simulated hook POST — not that the bridge accepted it, since hooks are
 *  advisory and swallow their own failures, but enough to know the async spawn
 *  chain (PTY → sink script → `run-hook.ts` → loopback POST) has actually run,
 *  which no fixed sleep can promise across machines. */
export function hookDoneMarker(event: string): string {
  return `HOOK_DONE:${event}`;
}

/** The origin every bus project is given. A session is addressed through its
 *  repo key (spec 5.1), so two projects that must see each other need the SAME
 *  remote — and one with no remote at all offers no row on either machine. */
export const BUS_REMOTE_URL = "https://github.com/antgrid/Eval-Fixture.git";
/** What `normalizeRemoteUrl` (bridge/src/capability-card.ts) makes of it — a
 *  lowercase `host/path` with the scheme and the `.git` suffix dropped. This
 *  is the value two machines match a session's project on. */
export const BUS_REPO_KEY = "github.com/antgrid/eval-fixture";

// The head of each delivered line, taken from the renderer rather than
// restated: a copied header keeps matching a template that has since changed,
// and the version it carries is exactly what a drifted copy would hide.
const MARKER_PROBE = {
  peer: { machineId: "probe", projectId: "probe", sessionId: "probe" },
  threadId: null,
  summary: "probe",
};
export const NOTIFY_MARKER = renderNotify(MARKER_PROBE).split("\n")[0]!;
export const REPLY_MARKER = renderReply(MARKER_PROBE).split("\n")[0]!;

export const sleep = (ms: number): Promise<void> => new Promise((r) => setTimeout(r, ms));

async function git(cwd: string, args: string[]): Promise<void> {
  const proc = Bun.spawn(["git", ...args], { cwd, stdout: "ignore", stderr: "pipe" });
  if (await proc.exited !== 0) throw new Error(await new Response(proc.stderr).text());
}

/**
 * The project every bus scenario runs against: the stdin sink guest, and a
 * repository the Capability Card can normalise into a match key.
 *
 * Both halves are load-bearing and neither is obvious from a failure. Without
 * the remote the directory refuses outright (`NOT_ADDRESSABLE`) and every send
 * answers `UNKNOWN_PEER`, on ONE machine as much as two — a repo key is how a
 * row is offered at all, not only how two machines match. Pass this as
 * `prepareProject`, which runs before the agent boots: repository identity is
 * resolved once at startup.
 */
export async function prepareBusProject(dir: string): Promise<void> {
  writeFileSync(join(dir, SINK_SCRIPT_NAME), SINK_SCRIPT);
  await git(dir, ["init"]);
  await git(dir, ["config", "user.email", "eval@antgrid.local"]);
  await git(dir, ["config", "user.name", "Antgrid Eval"]);
  await git(dir, ["add", "."]);
  await git(dir, ["commit", "-m", "initial"]);
  await git(dir, ["remote", "add", "origin", BUS_REMOTE_URL]);
}

/** One project's persisted session rows, read off disk rather than the wire:
 *  an advert is a push, so what it stopped carrying is no evidence of what the
 *  bridge actually kept. */
export function persistedSessions(abDir: string, projectId: string): any[] {
  const path = join(abDir, "agents", projectId, "sessions.json");
  if (!existsSync(path)) return [];
  try {
    return JSON.parse(readFileSync(path, "utf8")).sessions ?? [];
  } catch {
    return [];
  }
}

export function sinkText(path: string): string {
  return existsSync(path) ? readFileSync(path, "utf8") : "";
}

export function countMarkers(text: string, marker: string): number {
  return text.split(marker).length - 1;
}

export async function until<T>(fn: () => T | undefined, timeoutMs: number, what: string): Promise<T> {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    const hit = fn();
    if (hit !== undefined) return hit;
    if (Date.now() >= deadline) throw new Error(`timed out waiting for ${what}`);
    await sleep(25);
  }
}

/** The bridge's local API port, re-read on every call: a restart rewrites
 *  `api.port` with a freshly allocated one. */
export async function apiPort(abDir: string): Promise<string> {
  return (await Bun.file(join(abDir, "api.port")).text()).trim();
}

export async function postJson(url: string, body: unknown, bearer?: string): Promise<any> {
  const res = await fetch(url, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      ...(bearer ? { authorization: `Bearer ${bearer}` } : {}),
    },
    body: JSON.stringify(body),
  });
  const text = await res.text();
  try { return JSON.parse(text); } catch { throw new Error(`${url} -> ${res.status} ${text.slice(0, 200)}`); }
}

export async function getJson(url: string): Promise<any> {
  const res = await fetch(url);
  const text = await res.text();
  try { return JSON.parse(text); } catch { throw new Error(`${url} -> ${res.status} ${text.slice(0, 200)}`); }
}

/** One loopback session-bus call and both halves of its answer.
 *
 *  The STATUS travels beside the body because a refusal is two facts, not one:
 *  the `code` an agent reads and the status `session-bus/errors.ts` maps it to.
 *  Nothing here reads either — a caller that only learned "it failed" would
 *  pass its assertion for any refusal at all. */
export interface BusCall {
  status: number;
  body: any;
}

/**
 * Call one `/session-bus/*` route on a bridge's loopback API.
 *
 * `terminalId` IS the caller: every route resolves membership from it, and for
 * an agent session the terminal id and the session id are one value. A POST is
 * made iff `body` is given.
 */
export async function busCall(
  abDir: string,
  path: string,
  opts: { terminalId: string; body?: unknown; query?: Record<string, string> },
): Promise<BusCall> {
  const port = await apiPort(abDir);
  const params = new URLSearchParams({ terminalId: opts.terminalId, ...opts.query });
  const url = `http://127.0.0.1:${port}/session-bus/${path}?${params.toString()}`;
  const res = await fetch(
    url,
    opts.body === undefined
      ? {}
      : { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(opts.body) },
  );
  const text = await res.text();
  try {
    return { status: res.status, body: JSON.parse(text) };
  } catch {
    throw new Error(`${url} -> ${res.status} ${text.slice(0, 200)}`);
  }
}

/** One project verb, answered on its own requestId. `session:result` carries no
 *  echo of the verb, so the id is the only thing tying reply to request. */
export async function sessionVerbResult(app: RelayClient, streamId: string, msg: AbMessage): Promise<any> {
  app.sendOnStream(streamId, msg);
  const requestId = (msg as any).requestId;
  return app.waitFor(
    (m: any) => m._streamId === streamId && m.type === "session:result" && m.requestId === requestId,
    15_000,
  );
}

/** As `sessionVerbResult`, for the calls a scenario expects to succeed. */
export async function sessionVerb(app: RelayClient, streamId: string, msg: AbMessage): Promise<any> {
  const res = await sessionVerbResult(app, streamId, msg);
  if (!res.ok) throw new Error(`${(msg as any).type} refused: ${res.error} (${res.errorCode ?? "no code"})`);
  return res;
}

/** As `until`, for a probe that has to go over the wire. Sequential by
 *  construction: an HTTP view polled concurrently would let a slow answer land
 *  after a later, fresher one. */
export async function untilAsync<T>(
  fn: () => Promise<T | undefined>,
  timeoutMs: number,
  what: string,
): Promise<T> {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    const hit = await fn();
    if (hit !== undefined) return hit;
    if (Date.now() >= deadline) throw new Error(`timed out waiting for ${what}`);
    await sleep(100);
  }
}
