import { test, expect } from "bun:test";
import { existsSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { randomUUID } from "node:crypto";
import type { Subprocess } from "bun";
import { createTestProject } from "../helpers/fixtures";
import { LocalTestClient, type LocalConnectInfo } from "../helpers/local-client";
import { setMobileAccess } from "../helpers/harness";
import { computeProjectId } from "../../bridge/src/project-id";
import { readRepoKey } from "../../bridge/src/capability-card";
import { readHostFile, type HostFile } from "../../bridge/src/host-discovery";
import { createMessage, type AbMessage } from "../../bridge/src/protocol";
import { loadDeliveries } from "../../bridge/src/session-bus/delivery-queue";
import {
  LOCAL_MACHINE_ID,
  MAX_NOTIFIES_PER_PAIR_HOUR,
  NO_PROGRESS_EXCHANGES,
} from "../../bridge/src/session-bus/constants";
import {
  BUS_REPO_KEY,
  NOTIFY_MARKER,
  REPLY_MARKER,
  SINK_SCRIPT_NAME,
  apiPort,
  busCall,
  countMarkers,
  postJson,
  prepareBusProject,
  sinkText,
  sleep,
  untilAsync,
  type BusCall,
} from "../support/session-bus";

/**
 * The session bus with nothing underneath it: one bridge, no relay, no desktop
 * carrier, and the machine's remote-access switch off.
 *
 * That trio is the whole of §6.1 — two sessions one bridge spawned reach each
 * other with no network, no identity and no switch — and it is the one claim no
 * bridge unit test can make. A unit test builds the coordinator with `send` as a
 * closure and `self` supplied, so it proves the coordinator's arithmetic while
 * assuming away the two things §6.1 is about: that the bridge names itself when
 * nothing else will, and that the local arm of `dispatch` is what carries the
 * frame. Only a real process, booted with no relay at all, exercises either.
 *
 * Everything is driven over the LOOPBACK `/session-bus/*` routes, because that
 * is what an agent's MCP tools call: each tool is one HTTP call to the route
 * that took the decision, so a route asserted here is the tool asserted here.
 */

const ROOT = resolve(import.meta.dir, "../..");

/** How long a "it must NOT have arrived yet" window stays open. Long enough
 *  that an immediate delivery — the bug §7.2 guards against — would have landed
 *  many times over; the delivery queue drains on an edge, not on a timer, so
 *  waiting longer proves nothing more. */
const NOT_YET_MS = 1_500;

interface LocalBridge {
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
async function bootLocalBridge(): Promise<LocalBridge> {
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
    const spawned = Bun.spawn(["bun", "run", resolve(ROOT, "bridge/src/index.ts")], {
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
      // No `sessionBusCarrier` — this owner is a viewer, not the desktop app's
      // carrier leg, which is what leaves `carrierPresent()` false throughout.
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
async function localVerb(bridge: LocalBridge, msg: AbMessage): Promise<any> {
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
async function createSession(bridge: LocalBridge, name: string): Promise<string> {
  const created = await localVerb(bridge, createMessage("session:create", {
    requestId: randomUUID(),
    name,
    command: `node ${SINK_SCRIPT_NAME}`,
    mode: "terminal",
  }));
  return created.session.id as string;
}

async function startSession(bridge: LocalBridge, sessionId: string): Promise<void> {
  await localVerb(bridge, createMessage("session:start", { requestId: randomUUID(), sessionId }));
}

/**
 * Wait until this project offers rows at all.
 *
 * §5.1 resolves the repo key by spawning git, so for the first moments after a
 * boot the project is addressable-but-not-yet-read and every send answers
 * `UNKNOWN_PEER`. Gating on the directory answering keeps that startup race out
 * of every assertion below it.
 */
async function awaitAddressable(bridge: LocalBridge, terminalId: string): Promise<BusCall> {
  const deadline = Date.now() + 30_000;
  let last: BusCall | undefined;
  for (;;) {
    last = await busCall(bridge.abDir, "sessions", { terminalId });
    if (last.status === 200) return last;
    // Named rather than merely timed out: every reason the directory can refuse
    // is a different bug, and a bare timeout points at none of them.
    if (Date.now() >= deadline) {
      throw new Error(`directory never answered: ${last.status} ${JSON.stringify(last.body)}`);
    }
    await sleep(200);
  }
}

function localTarget(bridge: LocalBridge, sessionId: string): { projectId: string; sessionId: string } {
  // No `machineId`, which is the §6.1 address: an omitted machine IS this
  // machine, and this machine has no id to spell.
  return { projectId: bridge.projectId, sessionId };
}

function heldFor(bridge: LocalBridge, sessionId: string) {
  return loadDeliveries(bridge.abDir, bridge.projectId).lines.filter((l) => l.sessionId === sessionId);
}

test("a post reaches a sibling session's mailbox on a bridge with no relay identity, no carrier and remote access off", async () => {
  const bridge = await bootLocalBridge();
  try {
    const sender = await createSession(bridge, "sender");
    const target = await createSession(bridge, "target");
    await startSession(bridge, sender);
    await startSession(bridge, target);

    // Each leg of §6.1's trio witnessed before anything relies on it, because
    // all three fail OPEN in the same direction: a bridge that had quietly
    // acquired an identity, a carrier or the switch would pass every assertion
    // below while proving something else entirely.
    const directory = await awaitAddressable(bridge, sender);
    expect(directory.body.machineId).toBeNull();
    expect(directory.body.sessions.map((s: { sessionId: string }) => s.sessionId)).toContain(target);
    // §5.1's match key, read through the same probe the bus addresses by. The
    // local rows above do not carry it, so nothing else here would notice the
    // fixture's remote and the key two machines are matched on drifting apart —
    // and a drift costs no local row at all, only every cross-machine one.
    expect(await readRepoKey(bridge.projectDir)).toBe(BUS_REPO_KEY);

    const offMachine = {
      to: { machineId: "a-machine-this-bridge-has-never-met", projectId: bridge.projectId, sessionId: target },
      summary: "off-machine probe",
      text: "probe",
    };
    const switchedOff = await busCall(bridge.abDir, "post", { terminalId: sender, body: offMachine });
    expect(switchedOff.status).toBe(403);
    expect(switchedOff.body.code).toBe("REMOTE_ACCESS_OFF");

    // Flipped on only to reach the rung underneath it: with the switch off, the
    // carrier is never asked, so the absent desktop leg has no other witness.
    await setMobileAccess(bridge.abDir, true);
    const noCarrier = await busCall(bridge.abDir, "post", { terminalId: sender, body: offMachine });
    expect(noCarrier.status).toBe(503);
    expect(noCarrier.body.code).toBe("PEER_UNREACHABLE");
    await setMobileAccess(bridge.abDir, false);

    const posted = await busCall(bridge.abDir, "post", {
      terminalId: sender,
      body: { to: localTarget(bridge, target), summary: "the parser rewrite is on branch x", text: "look at lexer.ts" },
    });
    expect(posted.status).toBe(200);
    expect(posted.body.ok).toBe(true);
    expect(posted.body.sent).toBe(true);
    expect(posted.body.held).toBe(false);
    expect(posted.body.opensThread).toBe(true);
    // §4.3: the id is bridge-owned, and a sender never told it cannot answer on
    // the thread it just opened.
    const threadId = posted.body.threadId;
    expect(typeof threadId).toBe("string");
    expect(threadId.length).toBeGreaterThan(0);

    const inbox = await busCall(bridge.abDir, "inbox", { terminalId: target });
    expect(inbox.status).toBe(200);
    expect(inbox.body.dropped).toBe(0);
    expect(inbox.body.posts).toHaveLength(1);
    expect(inbox.body.posts[0].threadId).toBe(threadId);
    expect(inbox.body.posts[0].summary).toBe("the parser rewrite is on branch x");
    expect(inbox.body.posts[0].text).toEqual(["look at lexer.ts"]);
    expect(inbox.body.posts[0].from.sessionId).toBe(sender);

    // The agent's read spends the unread flag: a post handed over once must not
    // be handed over again.
    const drained = await busCall(bridge.abDir, "inbox", { terminalId: target });
    expect(drained.body.posts).toHaveLength(0);

    // §7.1: a post is read when its target chooses, so it owes the receiving
    // terminal no line at all.
    expect(countMarkers(sinkText(bridge.sinkPath), NOTIFY_MARKER)).toBe(0);

    // E6's receipt, and the only end-to-end proof it travels: the ack takes
    // `dispatch`'s LOCAL arm, and a build that let it fall through to the
    // ordinary send would drop it against no route and stamp nothing here.
    const entry = await untilAsync(async () => {
      const view = await busCall(bridge.abDir, "thread", { terminalId: sender, query: { threadId } });
      const out = (view.body.entries ?? []).find((e: { direction: string }) => e.direction === "out");
      return out?.deliveredAt === undefined ? undefined : out;
    }, 15_000, "the delivery receipt on the sender's own thread entry");
    expect(entry.peer.sessionId).toBe(target);
    // The sentinel the bridge named itself by, persisted into the thread row.
    expect(entry.peer.machineId).toBe(LOCAL_MACHINE_ID);
  } finally {
    await bridge.teardown();
  }
}, 180_000);

test("a notify waits for the target's next turn boundary and arrives there exactly once", async () => {
  const bridge = await bootLocalBridge();
  try {
    const sender = await createSession(bridge, "sender");
    const target = await createSession(bridge, "target");
    await startSession(bridge, sender);
    await startSession(bridge, target);
    await awaitAddressable(bridge, sender);

    const api = `http://127.0.0.1:${await apiPort(bridge.abDir)}`;
    // A turn-start naming a session the work-status reduction has not seen
    // running yet is HELD and promoted when it appears, so this needs no race
    // with `session:start`'s own bookkeeping.
    await postJson(`${api}/turn-start`, { terminalId: target });

    const notified = await busCall(bridge.abDir, "notify", {
      terminalId: sender,
      body: { to: localTarget(bridge, target), summary: "the migration is blocked on your schema", text: "which column wins?" },
    });
    expect(notified.status).toBe(200);
    expect(notified.body.sent).toBe(true);

    // Half one of §7.2, and the half an "it arrived" assertion never tests: mid
    // turn the line exists and has NOT been submitted.
    await sleep(NOT_YET_MS);
    expect(countMarkers(sinkText(bridge.sinkPath), NOTIFY_MARKER)).toBe(0);
    const held = heldFor(bridge, target);
    expect(held).toHaveLength(1);
    expect(held[0]!.kind).toBe("notify");

    // Half two: the closing edge, which is what a turn-ending notification is.
    await postJson(`${api}/notify`, { type: "task_complete", terminalId: target, message: randomUUID() });
    await untilAsync(
      async () => (countMarkers(sinkText(bridge.sinkPath), NOTIFY_MARKER) === 1 ? true : undefined),
      20_000,
      "the notify line at the turn boundary",
    );
    // ...and only once. The queue persists a line before submitting it and
    // removes it after, so a second drain would append a duplicate here rather
    // than fail anything.
    await sleep(NOT_YET_MS);
    expect(countMarkers(sinkText(bridge.sinkPath), NOTIFY_MARKER)).toBe(1);
    expect(heldFor(bridge, target)).toHaveLength(0);
  } finally {
    await bridge.teardown();
  }
}, 180_000);

test("a reply answers on the thread it was given and reaches the opener at its own turn boundary", async () => {
  const bridge = await bootLocalBridge();
  try {
    const asker = await createSession(bridge, "asker");
    const answerer = await createSession(bridge, "answerer");
    await startSession(bridge, asker);
    await startSession(bridge, answerer);
    await awaitAddressable(bridge, asker);

    const question = "which lock owns the queue";
    const posted = await busCall(bridge.abDir, "post", {
      terminalId: asker,
      body: { to: localTarget(bridge, answerer), summary: question, text: "see queue.ts" },
    });
    expect(posted.status).toBe(200);
    const threadId = posted.body.threadId;

    // The id the answerer replies on is the one it was HANDED, never one it
    // spelled: §4.3 makes the id bridge-owned, and a reply is the verb that
    // needs no address at all because the thread already records one.
    const inbox = await busCall(bridge.abDir, "inbox", { terminalId: answerer });
    expect(inbox.body.posts[0].threadId).toBe(threadId);

    const api = `http://127.0.0.1:${await apiPort(bridge.abDir)}`;
    await postJson(`${api}/turn-start`, { terminalId: asker });

    const replied = await busCall(bridge.abDir, "reply", {
      terminalId: answerer,
      body: { threadId, summary: "the writer lock does", text: "queue.ts holds it for the whole drain" },
    });
    expect(replied.status).toBe(200);
    expect(replied.body.sent).toBe(true);

    // A reply takes the interrupting verb (§7.1), so it waits for the asker's
    // boundary exactly as a notify does — and mid-turn it must not have landed.
    await sleep(NOT_YET_MS);
    expect(countMarkers(sinkText(bridge.sinkPath), REPLY_MARKER)).toBe(0);
    const held = heldFor(bridge, asker);
    expect(held).toHaveLength(1);
    // The template turns on whether the thread already existed AT THE RECEIVER,
    // which is the only thing separating an answer from a first contact.
    expect(held[0]!.kind).toBe("reply");

    await postJson(`${api}/notify`, { type: "task_complete", terminalId: asker, message: randomUUID() });
    await untilAsync(
      async () => (countMarkers(sinkText(bridge.sinkPath), REPLY_MARKER) === 1 ? true : undefined),
      20_000,
      "the reply line at the asker's turn boundary",
    );
    expect(countMarkers(sinkText(bridge.sinkPath), NOTIFY_MARKER)).toBe(0);
    // The question is not in the reply's body; it reaches the line only as the
    // thread context the delivery was rendered with, so a reply whose exchange
    // was resolved to the wrong thread would arrive naming nothing.
    expect(sinkText(bridge.sinkPath)).toContain(question);

    const view = await busCall(bridge.abDir, "thread", { terminalId: asker, query: { threadId } });
    expect(view.status).toBe(200);
    const answer = view.body.entries.find((e: { direction: string }) => e.direction === "in");
    expect(answer).toBeDefined();
    expect(answer.peer.sessionId).toBe(answerer);
    expect(view.body.entries.some((e: { direction: string }) => e.direction === "out")).toBe(true);
  } finally {
    await bridge.teardown();
  }
}, 180_000);

test("the pair budget refuses through the real verbs, survives a restart, and lifts only for a human", async () => {
  const bridge = await bootLocalBridge();
  try {
    const sender = await createSession(bridge, "sender");
    const rateTarget = await createSession(bridge, "rate-target");
    const stopped = await createSession(bridge, "never-started");
    const haltTarget = await createSession(bridge, "halt-target");
    await startSession(bridge, sender);
    await startSession(bridge, rateTarget);
    await startSession(bridge, haltTarget);
    await awaitAddressable(bridge, sender);

    // §7.3: a stopped session never reaches the boundary a notify waits for, so
    // the refusal has to hand the caller the verb that still reaches.
    const notRunning = await busCall(bridge.abDir, "notify", {
      terminalId: sender,
      body: { to: localTarget(bridge, stopped), summary: "are you there", text: "ping" },
    });
    expect(notRunning.status).toBe(409);
    expect(notRunning.body.code).toBe("NOT_RUNNING");
    expect(notRunning.body.error).toContain("antgrid_post");

    // §7.4's rolling-hour ceiling. Each of these opens its own thread, which is
    // progress — so what refuses below is the notify ceiling and never the halt.
    for (let i = 0; i < MAX_NOTIFIES_PER_PAIR_HOUR; i++) {
      const sent = await busCall(bridge.abDir, "notify", {
        terminalId: sender,
        body: { to: localTarget(bridge, rateTarget), summary: `urgent ${i}`, text: `body ${i}` },
      });
      expect(sent.status).toBe(200);
      expect(sent.body.ok).toBe(true);
    }
    const rateLimited = await busCall(bridge.abDir, "notify", {
      terminalId: sender,
      body: { to: localTarget(bridge, rateTarget), summary: "urgent again", text: "body again" },
    });
    expect(rateLimited.status).toBe(429);
    expect(rateLimited.body.code).toBe("NOTIFY_RATE");
    expect(rateLimited.body.error).toContain(String(MAX_NOTIFIES_PER_PAIR_HOUR));
    expect(rateLimited.body.error).toContain("post");

    // A post is unbudgeted by the ceiling, so the same pair still reaches.
    const stillReaches = await busCall(bridge.abDir, "post", {
      terminalId: sender,
      body: { to: localTarget(bridge, rateTarget), summary: "not urgent", text: "read when you can" },
    });
    expect(stillReaches.status).toBe(200);

    // §7.4's halt, on a pair of its own so the ceiling above cannot be what
    // stops it. The first send opens a thread (progress); every one after it
    // rides that same thread and publishes nothing, which is the exchange the
    // counter exists to notice.
    const opener = await busCall(bridge.abDir, "post", {
      terminalId: sender,
      body: { to: localTarget(bridge, haltTarget), summary: "round 0", text: "round 0" },
    });
    expect(opener.status).toBe(200);
    const threadId = opener.body.threadId;
    for (let i = 1; i < NO_PROGRESS_EXCHANGES; i++) {
      const sent = await busCall(bridge.abDir, "post", {
        terminalId: sender,
        body: { threadId, summary: `round ${i}`, text: `round ${i}` },
      });
      expect(sent.status).toBe(200);
      expect(sent.body.ok).toBe(true);
    }

    // The one a reader assumes is wrong: a POST is refused too. A halt that
    // gated only `notify` would leave the pair looping on the unbudgeted verb
    // forever and bound nothing (§8.2).
    const halted = await busCall(bridge.abDir, "post", {
      terminalId: sender,
      body: { to: localTarget(bridge, haltTarget), summary: "round again", text: "round again" },
    });
    expect(halted.status).toBe(429);
    expect(halted.body.code).toBe("NO_PROGRESS");
    expect(halted.body.error).toContain(String(NO_PROGRESS_EXCHANGES));
    expect(halted.body.error).toContain("human");

    // "Only a human clears it" is worth nothing if a crash clears it instead,
    // which is why the halt is forced to disk the moment it trips.
    await bridge.restart();
    const afterRestart = await untilAsync(async () => {
      const answer = await busCall(bridge.abDir, "post", {
        terminalId: sender,
        body: { to: localTarget(bridge, haltTarget), summary: "round after restart", text: "round after restart" },
      });
      // The fresh process has to re-read the repo key before it can resolve any
      // address at all; until it has, the refusal is about the row, not the pair.
      return answer.body.code === "UNKNOWN_PEER" ? undefined : answer;
    }, 30_000, "the restarted bridge to answer about the pair");
    expect(afterRestart.status).toBe(429);
    expect(afterRestart.body.code).toBe("NO_PROGRESS");

    // The one signal a bridge can observe that a human is looking. Nothing an
    // agent sends arrives as terminal input, which is what makes it unforgeable
    // — and this is its only regression anywhere.
    await startSession(bridge, sender);
    bridge.client.send(createMessage("terminal:input", { terminalId: sender, data: "\r" }));

    const cleared = await untilAsync(async () => {
      const answer = await busCall(bridge.abDir, "post", {
        terminalId: sender,
        body: { to: localTarget(bridge, haltTarget), summary: "round after the human", text: "round after the human" },
      });
      return answer.status === 200 ? answer : undefined;
    }, 20_000, "the human submit to lift the halt");
    expect(cleared.body.ok).toBe(true);
  } finally {
    await bridge.teardown();
  }
}, 300_000);
