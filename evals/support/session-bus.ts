import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { randomUUID } from "node:crypto";
import type { Subprocess } from "bun";
import { createTestProject } from "../helpers/fixtures";
import { LocalTestClient, type LocalConnectInfo } from "../helpers/local-client";
import { computeProjectId } from "../../bridge/src/project-id";
import { readHostFile, type HostFile } from "../../bridge/src/host-discovery";
import { join, resolve } from "node:path";
import { Database } from "bun:sqlite";
import { createMessage, type AbMessage } from "../../bridge/src/protocol";
import { renderNotify, renderReply } from "../../bridge/src/session-bus/delivery";
import {
  MAX_QUEUED_LINES,
  QueuedLineSchema,
  type QueuedLine,
} from "../../bridge/src/session-bus/delivery-queue";
import { busDbPath } from "../../bridge/src/session-bus/bus-db";
import type { RelayClient } from "../helpers/relay-client";

/**
 * Session-bus test glue: the PTY sink, the persisted-session reader, and the
 * loopback HTTP callers every bus scenario needs.
 *
 * Outside `evals/helpers/` for the reason `stream.ts` is — the harness is a
 * frozen shared surface.
 */

const BRIDGE_ROOT = resolve(import.meta.dir, "../..");
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
//
// It also announces itself the way a mounted TUI does — bracketed paste and
// then a glyph, which is what `GuestReadiness` (bridge/src/submit-gate.ts) reads
// as a guest that is reading. A sink that writes nothing never latches, so every
// submit in every bus scenario would wait out `SUBMIT_READY_TIMEOUT_MS` and then
// take the unheld path — leaving the gated path with no coverage at all. One
// write, because readiness credits paint by its POSITION relative to the mode:
// whether ConPTY delivers this as one read or ten changes nothing.
export const SINK_SCRIPT = `const fs = require("node:fs");
const { spawn } = require("node:child_process");
const sink = process.env.ANTGRID_EVAL_SINK;
const MARKER = ${JSON.stringify(HOOK_TRIGGER_MARKER)};
const RUN_HOOK = ${JSON.stringify(RUN_HOOK_SCRIPT)};
const BUN_EXE = ${JSON.stringify(BUN_EXECUTABLE)};
try { process.stdin.setRawMode(true); } catch {}
process.stdout.write("\\u001b[?2004h.");
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
 *  repo key, so two projects that must see each other need the SAME
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
 * the remote the directory and every send alike refuse `NOT_ADDRESSABLE`, on
 * ONE machine as much as two — a repo key is how a row is offered at all, not
 * only how two machines match. Pass this as `prepareProject`, which runs before
 * the agent boots: repository identity is resolved once at startup.
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

/**
 * Observe the bridge's delivery queue without running its writable database
 * initializer in this process. A WAL recovery lock is transient; undefined
 * tells a poll to retry instead of misreporting the queue as empty.
 */
export function persistedDeliveryLines(
  abDir: string,
  projectId: string,
): QueuedLine[] | undefined {
  const path = busDbPath(abDir);
  if (!existsSync(path)) return [];
  let db: Database | undefined;
  try {
    db = new Database(path, { readonly: true });
    const rows = db.query(
      "SELECT line FROM bus_deliveries WHERE projectId = ? ORDER BY seq DESC LIMIT ?",
    ).all(projectId, MAX_QUEUED_LINES) as Array<{ line: string }>;
    const lines: QueuedLine[] = [];
    for (const row of rows.reverse()) {
      let raw: unknown;
      try { raw = JSON.parse(row.line); } catch { continue; }
      const parsed = QueuedLineSchema.safeParse(raw);
      if (parsed.success) lines.push(parsed.data);
    }
    return lines;
  } catch (error) {
    const code = (error as { code?: string } | null)?.code ?? "";
    const message = error instanceof Error ? error.message : String(error);
    if (
      /^SQLITE_(?:BUSY|LOCKED)/.test(code)
      || /database (?:is )?(?:busy|locked)/i.test(message)
      || /no such table: bus_deliveries/i.test(message)
    ) {
      return undefined;
    }
    throw error;
  } finally {
    try { db?.close(); } catch { /* read-only probe owns no durable state */ }
  }
}

export function awaitDeliveryLines(
  abDir: string,
  projectId: string,
  sessionId: string,
  count: number,
  timeoutMs: number,
  what: string,
): Promise<QueuedLine[]> {
  return untilAsync(async () => {
    const snapshot = persistedDeliveryLines(abDir, projectId);
    if (snapshot === undefined) return undefined;
    const lines = snapshot.filter((line) => line.sessionId === sessionId);
    return lines.length === count ? lines : undefined;
  }, timeoutMs, what);
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

export interface LocalBridge {
  abDir: string;
  projectId: string;
  /** The checkout the bridge was booted over, for the probes that must read the
   *  repository itself rather than what the bridge says about it. */
  projectDir: string;
  sinkPath: string;
  client: LocalTestClient;
  /** Kill this bridge and boot a fresh process over the SAME `abDir` and
   *  project, then re-attach. Everything the bus persisted survives; only the
   *  process does not. */
  restart(): Promise<void>;
  teardown(): Promise<void>;
}

/**
 * Boot a bridge in LOCAL mode — the one mode with no relay registration at all,
 * so `machineId()` is null and every self-address falls back to the sentinel.
 *
 * Not `setupTestEnv`: that env exists to give a bridge a relay identity, which
 * is exactly the thing these scenarios must be without.
 */
export async function bootLocalBridge(): Promise<LocalBridge> {
  const project = createTestProject("basic", { __RELAY_URL__: "http://127.0.0.1:1" });
  await prepareBusProject(project.dir);
  const abDir = mkdtempSync(join(tmpdir(), "antgrid-bus-home-"));
  const sinkDir = mkdtempSync(join(tmpdir(), "antgrid-bus-sink-"));
  const sinkPath = join(sinkDir, "sink.txt");
  const projectId = computeProjectId(project.dir);
  const portFile = join(abDir, "api.port");
  const payload = {
    firstProject: { projectId, projectPath: project.dir, mode: "local" as const },
  };

  let proc!: Subprocess;
  let client!: LocalTestClient;

  /**
   * `stalePort` is the `api.port` the process being replaced was serving, given
   * only when it could not be removed — see `restart`.
   */
  async function spawnBridge(stalePort?: string): Promise<void> {
    const spawned = Bun.spawn(["bun", "run", resolve(BRIDGE_ROOT, "bridge/src/index.ts")], {
      cwd: project.dir,
      stdin: "pipe",
      stdout: "ignore",
      stderr: "ignore",
      env: {
        ...process.env,
        LOG_LEVEL: "error",
        ANTGRID_DIR: abDir,
        ANTGRID_EVAL_SINK: sinkPath,
      },
    });
    proc = spawned;
    // Past this line the process reaches a caller only through the `LocalBridge`
    // below, so a throw in the boot that follows would leave the bridge and its
    // whole PTY tree running with nothing left holding them — and the rows after
    // it then fight those ports for the rest of the process. Each unwind step is
    // guarded on its own: a cleanup that threw would replace the failure the
    // caller has to read.
    try {
      spawned.stdin.write(JSON.stringify(payload) + "\n");
      await spawned.stdin.end();

      const deadline = Date.now() + 20_000;
      let host: HostFile | null = null;
      while (Date.now() < deadline) {
        if (spawned.exitCode !== null) throw new Error(`bridge exited early with ${spawned.exitCode}`);
        const hf = readHostFile(join(abDir, "host.json"));
        // Matched on pid, not merely present: a restart re-reads the file the
        // dead process wrote until the fresh one overwrites it. `api.port` gets
        // the same treatment by value, because the host publishes host.json
        // before any core binds an API server — so a fresh pid is no evidence
        // that the port beside it is the fresh one.
        const port = existsSync(portFile) ? readFileSync(portFile, "utf8").trim() : null;
        if (hf && hf.pid === spawned.pid && port !== null && port !== stalePort) {
          host = hf;
          break;
        }
        await sleep(100);
      }
      if (!host) throw new Error("bridge did not publish host.json + a fresh api.port in 20s");

      const answer = await postJson(
        `http://127.0.0.1:${host.controlPort}/control`,
        { id: randomUUID(), type: "project:open", projectId, projectPath: project.dir, mode: "local" },
        host.token,
      );
      if (!answer.ok || !answer.connect) throw new Error(`project:open returned no connect info: ${JSON.stringify(answer)}`);
      client = new LocalTestClient();
      await client.connect(answer.connect as LocalConnectInfo);
    } catch (err) {
      try { client?.close(); } catch { /* a socket that never opened */ }
      try { await kill(); } catch { /* the process may already be gone */ }
      throw err;
    }
  }

  async function kill(): Promise<void> {
    if (process.platform === "win32") {
      const taskkill = `${process.env.SystemRoot ?? "C:\\Windows"}\\System32\\taskkill.exe`;
      try { Bun.spawnSync([taskkill, "/PID", String(proc.pid), "/T", "/F"]); } catch { /* best-effort */ }
    }
    proc.kill();
    await proc.exited;
  }

  // `spawnBridge` has already disposed of its own process; what is left is the
  // fixture and the temp directories, which no caller can reach once this
  // throws.
  try {
    await spawnBridge();
  } catch (err) {
    try { project.cleanup(); } catch { /* the PTYs may still hold handles */ }
    try { rmSync(abDir, { recursive: true, force: true }); } catch { /* same */ }
    try { rmSync(sinkDir, { recursive: true, force: true }); } catch { /* same */ }
    throw err;
  }

  return {
    abDir,
    projectId,
    projectDir: project.dir,
    sinkPath,
    get client() { return client; },
    async restart() {
      // Read BEFORE the kill, and used below: it is the only thing that tells a
      // dead process's port file from the fresh one when the removal cannot
      // happen — a sharing violation over a taskkill'd process's handles is the
      // realistic case, and a swallowed one leaves every later call talking to a
      // dead or OS-recycled port.
      const livePort = existsSync(portFile) ? await apiPort(abDir) : undefined;
      client.close();
      await kill();
      let removed = true;
      try { rmSync(portFile, { force: true }); } catch { removed = false; }
      await spawnBridge(removed ? undefined : livePort);
    },
    async teardown() {
      client.close();
      await kill();
      project.cleanup();
      try { rmSync(abDir, { recursive: true, force: true }); } catch { /* the PTYs may still hold handles */ }
      try { rmSync(sinkDir, { recursive: true, force: true }); } catch { /* same */ }
    },
  };
}

/** One project verb over the loopback owner socket, answered on its own
 *  requestId — `session:result` carries no echo of the verb it answers. */
export async function localVerb(bridge: Pick<LocalBridge, "client">, msg: AbMessage): Promise<any> {
  const requestId = (msg as { requestId?: string }).requestId;
  const answer = new Promise<any>((resolveAnswer, reject) => {
    const timer = setTimeout(() => {
      off();
      reject(new Error(`timed out waiting for ${msg.type}`));
    }, 20_000);
    const off = bridge.client.on((m: AbMessage) => {
      if (m.type !== "session:result" || m.requestId !== requestId) return;
      clearTimeout(timer);
      off();
      if (!m.ok) reject(new Error(`${msg.type} refused: ${m.error} (${m.errorCode ?? "no code"})`));
      else resolveAnswer(m);
    });
  });
  bridge.client.send(msg);
  return answer;
}

/**
 * A session whose guest records exactly what the bridge submits to it.
 *
 * A custom command rather than a `tool`, because the fixture declares no agent
 * and these scenarios assert WHEN a line reaches a terminal — a real agent would
 * answer the line and make the count its own.
 */
export async function createSession(bridge: LocalBridge, name: string): Promise<string> {
  const created = await localVerb(bridge, createMessage("session:create", {
    requestId: randomUUID(),
    name,
    command: `node ${SINK_SCRIPT_NAME}`,
    mode: "terminal",
  }));
  return created.session.id as string;
}

export async function startSession(bridge: LocalBridge, sessionId: string): Promise<void> {
  await localVerb(bridge, createMessage("session:start", { requestId: randomUUID(), sessionId }));
}

/** Flip a machine's agent-reach switch through the loopback control verb the
 *  desktop toggle drives. */
export async function setAgentReach(abDir: string, enabled: boolean): Promise<void> {
  const hf = readHostFile(join(abDir, "host.json"));
  if (!hf) throw new Error(`no host.json in ${abDir}`);
  const res = await postJson(
    `http://127.0.0.1:${hf.controlPort}/control`,
    { id: `bus-reach-${randomUUID()}`, type: "agent-reach:set", enabled },
    hf.token,
  );
  if (!res.ok || res.enabled !== enabled) throw new Error(`agent-reach:set ${enabled} failed: ${JSON.stringify(res)}`);
}

async function controlVerb(abDir: string, body: Record<string, unknown>): Promise<any> {
  const hf = readHostFile(join(abDir, "host.json"));
  if (!hf) throw new Error(`no host.json in ${abDir}`);
  return postJson(`http://127.0.0.1:${hf.controlPort}/control`, { id: `bus-grants-${randomUUID()}`, ...body }, hf.token);
}

/** Lower this machine's owner-set grants through the loopback verb the CLI
 *  drives. There is no raise counterpart: raising needs the owner's session. */
export async function lowerGrants(
  abDir: string,
  patch: { orchestrator?: false; busControl?: false },
): Promise<{ grants: { orchestrator: boolean; busControl: boolean }; reachEnabled: boolean; level: string }> {
  const res = await controlVerb(abDir, { type: "bus-grants:lower", ...patch });
  if (!res.ok) throw new Error(`bus-grants:lower failed: ${JSON.stringify(res)}`);
  return res;
}

/** The grants the web authority holds for a machine, read with that machine's
 *  own credential, so a lowering the bridge never delivered shows here. */
export async function authorityGrants(
  licenseUrl: string,
  auth: { clientId: string; clientSecret: string },
): Promise<{ orchestrator: boolean; busControl: boolean }> {
  const basic = Buffer.from(`${auth.clientId}:${auth.clientSecret}`).toString("base64");
  const minted = await fetch(`${licenseUrl}/api/auth/oauth2/token`, {
    method: "POST", headers: { authorization: `Basic ${basic}`, "content-type": "application/x-www-form-urlencoded" },
    body: "grant_type=client_credentials",
  }).then((r) => r.json()) as { access_token: string };
  const res = await fetch(`${licenseUrl}/account/devices/me/session-bus`, {
    headers: { authorization: `Bearer ${minted.access_token}` },
  });
  if (!res.ok) throw new Error(`session-bus read failed: ${res.status}`);
  return await res.json() as { orchestrator: boolean; busControl: boolean };
}
