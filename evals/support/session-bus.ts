import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import type { AbMessage } from "../../bridge/src/protocol";
import type { RelayClient } from "../helpers/relay-client";

/**
 * Session-bus test glue: the PTY sink, the delivery-queue reader, and the
 * loopback HTTP callers every bus scenario needs.
 *
 * Outside `evals/helpers/` for the reason `stream.ts` is — the harness is a
 * frozen shared surface — and deliberately NOT extracted out of
 * `gate-session-bus.test.ts`, which stays self-contained: that suite is the
 * single-machine reference row, and a shared edit that broke it would take the
 * cross-machine rows down with it.
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

/** First header line of each delivery kind (`delivery.ts`'s renderers), minus
 *  the template-version suffix — the marker a sink text is counted for. */
export const TASK_MARKER = "[antgrid session bus] delivery: task";
export const WAKE_MARKER = "[antgrid session bus] delivery: wake";
export const CANCEL_MARKER = "[antgrid session bus] delivery: cancel";

export const sleep = (ms: number): Promise<void> => new Promise((r) => setTimeout(r, ms));

export function deliveriesPath(abDir: string, projectId: string): string {
  return join(abDir, "agents", encodeURIComponent(projectId), "session-bus", "deliveries.json");
}

/** The lines the bridge is holding for a session, as the queue persisted them.
 *  A line is written before delivery is attempted and removed only once the
 *  submit succeeded, so this file IS the held-vs-submitted distinction. */
export function queuedLines(abDir: string, projectId: string, sessionId: string): any[] {
  const path = deliveriesPath(abDir, projectId);
  if (!existsSync(path)) return [];
  try {
    const parsed = JSON.parse(readFileSync(path, "utf8"));
    return (parsed.lines ?? []).filter((l: any) => l.sessionId === sessionId);
  } catch {
    // A concurrent atomic rewrite is the only reader error worth tolerating.
    return [];
  }
}

/** One project's persisted session rows, read off disk rather than the wire:
 *  a delete has to be provable after the row has left every advert. */
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
