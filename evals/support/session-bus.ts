import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
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

// The receiving session's PTY is a stdin sink rather than an agent: these
// scenarios assert WHEN a line reaches the terminal, so the guest only has to
// record what it was given. Raw mode keeps the ConPTY line discipline from
// holding the write back until a newline the bridge never sends on its own.
export const SINK_SCRIPT = `const fs = require("node:fs");
const sink = process.env.ANTGRID_EVAL_SINK;
try { process.stdin.setRawMode(true); } catch {}
process.stdin.on("data", (d) => { try { fs.appendFileSync(sink, d); } catch {} });
process.stdin.resume();
setInterval(() => {}, 1 << 30);
`;
export const SINK_SCRIPT_NAME = "antgrid-eval-sink.cjs";

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
