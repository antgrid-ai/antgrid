// What the delivery path is allowed to say about itself, and what it is not.
//
// Two properties, and they pull against each other, which is why they are gated
// together. A delivery has to be FOLLOWABLE — one key that joins the queue row,
// the drain and the PTY write, so a line that stops somewhere names the segment
// that dropped it. And nothing on that path may write down a character of what
// was said. What a leak looks like is a PREFIX of a delivery rather than a
// whole one, which is why the scan below is over WINDOWS of the secret and not
// over the whole string.
import { afterAll, afterEach, beforeEach, expect, test } from "bun:test";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { HostServer } from "../src/host-server";
import { computeProjectId } from "../src/project-id";
import { createMessage, SessionMemberRefSchema } from "../src/protocol";
import { BUS_MESSAGE_TTL_MS, LOCAL_MACHINE_ID } from "../src/session-bus/constants";
import { SessionBusCoordinator } from "../src/session-bus/coordinator";
import { loadMailbox } from "../src/session-bus/mailbox";
import { SessionBusDeliveryQueue } from "../src/session-bus/delivery-queue";
import { lineKey } from "../src/line-key";
import { selfMachineLabel } from "../src/machine-label";
import { TerminalManager } from "../src/terminal-manager";
import { createConnState } from "../src/conn-state";
import { __setRootForTest } from "../src/logger";

// -- capture ----------------------------------------------------------------

const lines: string[] = [];
const capture = {
  write(s: string): boolean {
    lines.push(s);
    return true;
  },
};

/** Every new log site lands at `debug`; capturing at `trace` is what makes the
 *  sentinel scan a statement about EVERY level rather than about the one this
 *  process happens to run at. */
function captureAtEveryLevel(): void {
  lines.length = 0;
  __setRootForTest(capture, "trace");
}

afterAll(() => __setRootForTest(process.stdout));

// -- sentinels --------------------------------------------------------------

/** No hex digits and no vowels: a window of one of these can never collide with
 *  a sha, a uuid or ordinary prose, so a hit is a leak and never a coincidence.
 *  [label] has to be drawn from the same alphabet. */
const SENTINEL_FILL = "GHJKLMNPQRSTVWXYZ";

function sentinel(label: string, length: number): string {
  return label.padEnd(length, SENTINEL_FILL).slice(0, length);
}

/** Eight characters, because that is shorter than any "first N chars" prefix
 *  anyone would plausibly write and long enough that the alphabet above makes a
 *  false positive impossible. */
const WINDOW = 8;

function assertNoSentinelAnywhere(secrets: string[], captured: string[]): void {
  for (const secret of secrets) {
    for (let i = 0; i + WINDOW <= secret.length; i++) {
      const window = secret.slice(i, i + WINDOW);
      const leaked = captured.find((l) => l.includes(window));
      if (leaked) {
        throw new Error(`a log line carried ${WINDOW} characters of a delivery: ${leaked}`);
      }
    }
  }
}

function shasFor(captured: string[], msg: string): string[] {
  return captured
    .map((l) => JSON.parse(l) as { msg?: string; sha?: string })
    .filter((o) => o.msg === msg && typeof o.sha === "string")
    .map((o) => o.sha!);
}

// -- host harness -----------------------------------------------------------
// A real local exchange: `coordinator.message` -> `deliverLocal` ->
// `handleInbound` -> `emit` -> `lineForEvent` -> the delivery queue -> the
// injection. Nothing here is stubbed, which is the point: a sentinel scan over
// a fake path proves nothing about the path that writes the file.

let host: HostServer | null = null;
let abDir: string | undefined;
let prevAbDir: string | undefined;
let prevHostName: string | undefined;
const folders: string[] = [];

beforeEach(() => {
  prevAbDir = process.env.ANTGRID_DIR;
  prevHostName = process.env.ANTGRID_HOST_NAME;
  abDir = mkdtempSync(join(tmpdir(), "antgrid-buslog-"));
  process.env.ANTGRID_DIR = abDir;
});

afterEach(async () => {
  __setRootForTest(process.stdout);
  await host?.shutdown();
  host = null;
  if (prevAbDir === undefined) delete process.env.ANTGRID_DIR;
  else process.env.ANTGRID_DIR = prevAbDir;
  if (prevHostName === undefined) delete process.env.ANTGRID_HOST_NAME;
  else process.env.ANTGRID_HOST_NAME = prevHostName;
  if (abDir) await rmWithRetry(abDir);
  while (folders.length) await rmWithRetry(folders.pop()!);
});

// The core's watcher can hold a transient handle on a temp folder for a few ms
// past shutdown on Windows; teardown must never fail the assertions above.
async function rmWithRetry(path: string): Promise<void> {
  for (let i = 0; i < 20; i++) {
    try {
      rmSync(path, { recursive: true, force: true });
      return;
    } catch {
      await new Promise((r) => setTimeout(r, 25));
    }
  }
}

function tempFolder(projectName: string): string {
  const f = mkdtempSync(join(tmpdir(), "antgrid-buslog-p-"));
  folders.push(f);
  writeFileSync(join(f, "antgrid.yaml"), `name: ${projectName}\nagent:\n  tool: claude-code\n`);
  return f;
}

async function waitFor(pred: () => boolean, what: string, timeoutMs = 10_000): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (!pred()) {
    if (Date.now() > deadline) throw new Error(`timed out waiting for ${what}`);
    await new Promise((r) => setTimeout(r, 10));
  }
}

async function openLocalSession(
  h: HostServer,
  folder: string,
  name: string,
): Promise<{ projectId: string; sessionId: string }> {
  const projectId = computeProjectId(folder);
  const opened = await h.open(projectId, folder, "local");
  if (!opened.connect) throw new Error("expected a loopback connect info");
  const ws = new WebSocket(`ws://127.0.0.1:${opened.connect.port}`);
  await new Promise<void>((resolve, reject) => {
    ws.onopen = () => resolve();
    ws.onerror = (e) => reject(e);
  });
  const inbox: any[] = [];
  ws.onmessage = (ev) => inbox.push(JSON.parse(String(ev.data)));
  ws.send(JSON.stringify({ type: "hello", token: opened.connect.token, appPid: 1, appVersion: "test" }));
  await waitFor(() => inbox.some((m) => m.type === "ready"), `${name} loopback ready`);
  const requestId = crypto.randomUUID();
  ws.send(JSON.stringify(createMessage("session:create", { requestId, name })));
  await waitFor(
    () => inbox.some((m) => m.type === "session:result" && m.requestId === requestId),
    `${name} session:create result`,
  );
  const sessionId = inbox.find((m) => m.type === "session:result" && m.requestId === requestId).session.id as string;
  ws.close();
  return { projectId, sessionId };
}

function busCoordinatorOf(h: HostServer): SessionBusCoordinator {
  return (h as unknown as { sessionBus: SessionBusCoordinator }).sessionBus;
}

test(
  "no log line on the delivery path carries a character of the message, at any level",
  async () => {
    const machine = sentinel("MJNK", 24);
    const projectName = sentinel("PRJT", 24);
    const sessionName = sentinel("SSNM", 24);
    const summary = sentinel("SMRY", 40);
    const body = sentinel("TXTZ", 600);
    const unexpected = sentinel("NXPT", 40);
    process.env.ANTGRID_HOST_NAME = machine;

    host = new HostServer({});
    const { sessionId: sender } = await openLocalSession(host, tempFolder(projectName), sessionName);
    const target = await openLocalSession(host, tempFolder(sentinel("TMPQ", 12)), "target");

    captureAtEveryLevel();
    const res = busCoordinatorOf(host).message({
      sessionId: sender,
      verb: "notify",
      threadId: null,
      to: { machineId: LOCAL_MACHINE_ID, projectId: target.projectId, sessionId: target.sessionId },
      summary,
      parts: [{ kind: "text", text: body }],
      unexpected,
    });
    if (!("ok" in res) || !res.ok) throw new Error(`message refused: ${JSON.stringify(res)}`);

    const captured = [...lines];
    __setRootForTest(process.stdout);

    // The scan is only worth anything if the path it ran over actually spoke.
    expect(captured.length).toBeGreaterThan(0);
    assertNoSentinelAnywhere([machine, projectName, sessionName, summary, body, unexpected], captured);
  },
  30_000,
);

test(
  "one join key follows a delivery from the queue into the drain",
  async () => {
    host = new HostServer({});
    const { sessionId: sender } = await openLocalSession(host, tempFolder("sender-project"), "sender");
    const target = await openLocalSession(host, tempFolder("target-project"), "target");

    captureAtEveryLevel();
    const res = busCoordinatorOf(host).message({
      sessionId: sender,
      verb: "notify",
      threadId: null,
      to: { machineId: LOCAL_MACHINE_ID, projectId: target.projectId, sessionId: target.sessionId },
      summary: "a summary",
      parts: [{ kind: "text", text: "a body" }],
    });
    if (!("ok" in res) || !res.ok) throw new Error(`message refused: ${JSON.stringify(res)}`);

    const captured = [...lines];
    __setRootForTest(process.stdout);

    const queued = shasFor(captured, "bus queue: held");
    const drained = shasFor(captured, "bus drain: inject returned");
    expect(queued).toHaveLength(1);
    expect(drained).toEqual(queued);
    expect(queued[0]).toMatch(/^[0-9a-f]{12}$/);

    // The target session was created and never started, so the injection
    // refuses on `!running` — the branch a delivery that vanishes most often
    // ends on, and one no stage below it is reached to report.
    const refusal = captured
      .map((l) => JSON.parse(l) as { msg?: string; sha?: string })
      .find((o) => o.msg === "bus inject: refused, session not running");
    expect(refusal?.sha).toBe(queued[0]);
  },
  30_000,
);

test(
  "an over-long machine name is clamped by the sender and its row survives a reload",
  async () => {
    const overLong = "M".repeat(400);
    process.env.ANTGRID_HOST_NAME = overLong;

    const label = selfMachineLabel();
    expect(label).toHaveLength(120);
    // The envelope bound, asserted directly: an inbound bus frame is admitted by
    // `parseMessageFast` on its type tag alone, so nothing on the receiving side
    // would ever reject an over-long label — it fails later, at `readRecords`,
    // which drops the row in silence.
    expect(
      SessionMemberRefSchema.safeParse({ machineId: "m", projectId: "p", sessionId: "s", machineLabel: label }).success,
    ).toBe(true);

    host = new HostServer({});
    const { sessionId: sender } = await openLocalSession(host, tempFolder("sender-project"), "sender");
    const target = await openLocalSession(host, tempFolder("target-project"), "target");

    const res = busCoordinatorOf(host).message({
      sessionId: sender,
      verb: "post",
      threadId: null,
      to: { machineId: LOCAL_MACHINE_ID, projectId: target.projectId, sessionId: target.sessionId },
      summary: "a summary",
      parts: [{ kind: "text", text: "a body" }],
    });
    if (!("ok" in res) || !res.ok) throw new Error(`message refused: ${JSON.stringify(res)}`);

    // The round trip, not the in-memory copy: the failure this guards against is
    // a row that is folded, acked and rendered and then vanishes on the next
    // cold load of that session.
    const reloaded = loadMailbox(abDir!, target.projectId, target.sessionId);
    expect(reloaded.posts).toHaveLength(1);
    // `from` on the row is the frame's ADDRESS and carries no labels; the
    // stamped ref rides the envelope, which is what the delivery wrapper reads.
    expect(reloaded.posts[0]!.envelope.metadata.peer.machineLabel).toBe(label);
  },
  30_000,
);

test("the join key reaches the pty write, and that site carries none of the line", async () => {
  const manager = new TerminalManager(() => {}, undefined, createConnState());
  try {
    const terminalId = manager.spawn({ terminalId: "walk-1" });
    const queue = new SessionBusDeliveryQueue({
      abDir: abDir!,
      projectId: "p-walk",
      canDeliver: () => true,
      // The key travels with the line, exactly as the pty adapter attaches it
      // in `agent-core.ts`: the PTY site has no way to tell a rendered delivery
      // from a human's typing, so which of the two it is has to arrive with it.
      inject: (line) => {
        manager.submit(terminalId, line.text, lineKey(line.text).sha);
        return "submitted";
      },
    });

    // The scan above stops at the injection, because its target session is never
    // started. This is the only test that drives the submit through to a real
    // PTY — and that site is the one log site handed the submitted line itself,
    // and the one shared with a human's own composer send.
    const delivery = sentinel("LVRY", 400);
    const typed = sentinel("TYPZ", 40);
    captureAtEveryLevel();
    queue.queue({ id: "m-walk", sessionId: terminalId, kind: "notify", text: delivery });
    // What a composer send looks like arriving at the same site.
    manager.submit(terminalId, typed);
    const captured = [...lines];
    __setRootForTest(process.stdout);

    const queued = shasFor(captured, "bus queue: held");
    expect(queued).toHaveLength(1);
    expect(shasFor(captured, "bus drain: inject returned")).toEqual(queued);
    // Keyed off the line as the queue held it, never off the paste-wrapped text
    // the plan produces — a key taken after the wrap would name a string no
    // earlier stage ever held, and the walk would end one line short.
    expect(shasFor(captured, "submit: writing to the pty")).toEqual(queued);
    // Two submits reached the PTY and exactly one of them is joinable. A digest
    // of a short typed line is guessable, so `host.log` gets no key for text a
    // human authored — which is also why the walk cannot be gated by counting
    // the write lines instead.
    expect(captured.filter((l) => l.includes("submit: writing to the pty"))).toHaveLength(2);
    assertNoSentinelAnywhere([delivery, typed], captured);
  } finally {
    manager.killAll();
  }
});

test("an adapter that throws with the line quoted back logs neither", () => {
  // The delivery adapter can reach a model driver, and a driver that rejects a
  // request throws with the request in the message — which is the line.
  const secret = sentinel("THRWN", 200);
  const queue = new SessionBusDeliveryQueue({
    abDir: abDir!,
    projectId: "p-throw",
    canDeliver: () => true,
    inject: (l) => { throw new Error(`rejected by the model: ${l.text}`); },
  });

  captureAtEveryLevel();
  queue.queue({ id: "m-throw", sessionId: "s-throw", kind: "notify", text: secret });
  const captured = [...lines];
  __setRootForTest(process.stdout);

  expect(captured.some((l) => l.includes("could not deliver"))).toBe(true);
  assertNoSentinelAnywhere([secret], captured);
});

test("a held message that expires without ever leaving is named, and named without its body", () => {
  // The one loss on the send path with no surface at all: the send answered
  // `{sent:false, held:true}`, which reads everywhere as on its way, and six
  // hours later the row is gone with nothing said. Widening which sends can
  // reach that state — a reply that resolves through a route rather than a row
  // can — is what makes the silence worth a warn rather than a debug line.
  let clock = 1_000;
  const secretSummary = sentinel("SKRTSMRY", 32);
  const secretBody = sentinel("SKRTTXTZ", 64);
  const coordinator = new SessionBusCoordinator({
    abDir: abDir!,
    projectIdFor: () => "p1",
    self: (sessionId) =>
      sessionId === "s-sender"
        ? {
          key: { machineId: "m1", projectId: "p1", sessionId },
          ref: { machineId: "m1", projectId: "p1", sessionId },
        }
        : null,
    // Nothing carries it, ever: the state a machine with no route home and no
    // desktop attached is in for as long as it stays that way.
    send: () => false,
    now: () => clock,
  });
  try {
    captureAtEveryLevel();
    const res = coordinator.message({
      sessionId: "s-sender",
      verb: "post",
      threadId: null,
      to: { machineId: "m2", projectId: "p2", sessionId: "s-target" },
      summary: secretSummary,
      parts: [{ kind: "text", text: secretBody }],
    });
    if (!("ok" in res) || !res.ok) throw new Error(`message refused: ${JSON.stringify(res)}`);
    expect(res.held).toBe(true);

    clock += BUS_MESSAGE_TTL_MS + 1;
    coordinator.pump();

    const said = lines.filter((l) => l.includes(res.messageId) && l.includes("expired"));
    expect(said).toHaveLength(1);
    expect(said[0]).toContain("s-target");
    // Ids identify; the envelope does not travel. `host.log` is a durable file
    // users are asked to send, and a loss notice is no more entitled to the
    // message than a delivery line is.
    assertNoSentinelAnywhere([secretSummary, secretBody], lines);
  } finally {
    coordinator.stop();
  }
});
