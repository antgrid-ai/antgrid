// The model-call recorder's surfaces: the two control verbs, the SSE
// feed the CLI and the viewer both read, and the one place this feature is
// deliberately narrower than netwatch — a browser may arm the prompt parts and
// may not arm the transcript.
import { afterEach, beforeEach, describe, expect, it } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { connect } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { ControlListener } from "../src/control-listener";
import type { ControlRequest, ControlResponse } from "../src/control-protocol";
import { HostServer } from "../src/host-server";
import {
  armContextCapture,
  isContextCaptureArmed,
  isPromptCaptureArmed,
  modelwatch,
  __resetModelwatchForTest,
  type ModelCallEvent,
} from "../src/modelwatch";
import { __resubscribeModelCallLogForTest } from "../src/modelwatch-log";
import { mintUiTicket, resetNetwatchUiCredentials } from "../src/netwatch-ui-session";

const HOST_TOKEN = "host-bearer-token-modelwatch";

/** The ceiling host-server clamps an arm to. Restated rather than imported: the
 *  constant is private to that module, and a test that reached in for it would
 *  pin the implementation instead of the answer a watcher is given. */
const MAX_TTL_MS = 3_600_000;

/** The context arm's own, shorter ceiling. Restated for the same reason, and
 *  separate because what the two arms admit is not comparable: one holds the
 *  scaffold we wrote, the other the transcript the user and their agent did. */
const CONTEXT_MAX_TTL_MS = 300_000;

/** Recognisable on sight in a recorded value. Stands in for what the context arm
 *  actually admits: the transcript and PTY excerpt a decision prompt is built
 *  around, which is whatever the user typed and whatever the agent read back. */
const SECRET = "sk-live-TRANSCRIPT-MUST-NOT-SURVIVE-A-DISARM";

type Recordable = Omit<ModelCallEvent, "seq" | "at"> & { at?: number };

const callEvent = (over: Partial<Recordable> = {}): Recordable => ({
  callId: "mw-1",
  phase: "start",
  purpose: "decision",
  attempt: 1,
  requestedTool: "claude-code",
  actualTool: "claude-code",
  reach: "repo",
  ...over,
});

let host: HostServer | null = null;
let listener: ControlListener | null = null;
let seen: ControlRequest[] = [];
let prevAbDir: string | undefined;
let abDir: string;

function ask(h: HostServer, req: Record<string, unknown>): Promise<any> {
  return (h as any).handleControl(req);
}

/** A listener whose handler only records what reached it: every assertion below
 *  is about the door, not about what the host would have done behind it. */
async function start(): Promise<number> {
  seen = [];
  listener = new ControlListener({
    token: HOST_TOKEN,
    handler: async (req: ControlRequest): Promise<ControlResponse> => {
      seen.push(req);
      if (req.type === "modelwatch:arm") {
        return { id: req.id, ok: true, type: "modelwatch:arm", prompts: true, context: false, ttlMs: 60_000 };
      }
      return { id: req.id, ok: true, type: "project:list", projects: [] };
    },
  });
  await listener.start();
  return listener.port;
}

/** A viewer session token, obtained the way the page obtains one. */
async function session(port: number): Promise<string> {
  const res = await fetch(`http://127.0.0.1:${port}/netwatch/ui/session`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ ticket: mintUiTicket() }),
  });
  expect(res.status).toBe(200);
  return ((await res.json()) as { token: string }).token;
}

function arm(port: number, token: string, body: Record<string, unknown>): Promise<Response> {
  return fetch(`http://127.0.0.1:${port}/netwatch/ui/arm`, {
    method: "POST",
    headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
    body: JSON.stringify(body),
  });
}

beforeEach(() => {
  // Pinned so the durable feed's writer has somewhere of its own to write —
  // unpinned under NODE_ENV=test it refuses, which is a behaviour this file
  // should not be relying on in either direction.
  prevAbDir = process.env.ANTGRID_DIR;
  abDir = mkdtempSync(join(tmpdir(), "antgrid-modelwatch-arm-"));
  process.env.ANTGRID_DIR = abDir;
  resetNetwatchUiCredentials();
  __resetModelwatchForTest();
  // The reset clears the ring's subscriber set wholesale, which leaves the log
  // module believing it is still attached; re-registering here and below is what
  // keeps this file from silently detaching the writer for every file after it.
  __resubscribeModelCallLogForTest();
});

afterEach(async () => {
  await host?.shutdown();
  host = null;
  await listener?.stop();
  listener = null;
  __resetModelwatchForTest();
  __resubscribeModelCallLogForTest();
  if (prevAbDir === undefined) delete process.env.ANTGRID_DIR;
  else process.env.ANTGRID_DIR = prevAbDir;
  rmSync(abDir, { recursive: true, force: true });
});

describe("modelwatch:arm", () => {
  it("arms the arm it was given and reports the state of both", async () => {
    host = new HostServer({});
    const res = await ask(host, { id: "1", type: "modelwatch:arm", arms: ["prompts"], enabled: true, ttlMs: 60_000 });

    expect(res).toMatchObject({ ok: true, type: "modelwatch:arm", prompts: true, context: false, ttlMs: 60_000 });
    expect(isPromptCaptureArmed()).toBe(true);
    expect(isContextCaptureArmed()).toBe(false);
  });

  it("reports the arm it was not asked about, because that one decides the answer", async () => {
    host = new HostServer({});
    const res = await ask(host, { id: "1", type: "modelwatch:arm", arms: ["context"], enabled: true, ttlMs: 60_000 });

    // Transcript text and the model's own answer are admitted only while BOTH
    // arms are up, so a reply that echoed only the arm named would tell this
    // caller it had a capture that will record nothing at all.
    expect(res).toMatchObject({ ok: true, prompts: false, context: true });
  });

  it("arms both when both are named", async () => {
    host = new HostServer({});
    const res = await ask(host, { id: "1", type: "modelwatch:arm", arms: ["prompts", "context"], enabled: true, ttlMs: 60_000 });

    expect(res).toMatchObject({ ok: true, prompts: true, context: true, ttlMs: 60_000 });
  });

  it("refuses an arm with no window, and arms nothing while refusing", async () => {
    host = new HostServer({});
    for (const req of [
      { id: "1", type: "modelwatch:arm", arms: ["prompts"], enabled: true },
      { id: "2", type: "modelwatch:arm", arms: ["prompts", "context"], enabled: true, ttlMs: 0 },
    ]) {
      const res = await ask(host, req);
      expect(res.ok).toBe(false);
      expect(res.error.code).toBe("TTL_REQUIRED");
    }
    // The TTL is a dead man's switch, not a policy: the only thing that ever
    // disarms is the watcher that armed it, and one killed with SIGKILL sends no
    // disarm. Arming anyway and answering `ok` would leave the host holding
    // prompt text for the rest of its life with nothing able to stop it.
    expect(isPromptCaptureArmed()).toBe(false);
    expect(isContextCaptureArmed()).toBe(false);
  });

  it("serves an over-long window a shorter one instead of refusing it", async () => {
    host = new HostServer({});
    const at = await ask(host, { id: "1", type: "modelwatch:arm", arms: ["prompts"], enabled: true, ttlMs: MAX_TTL_MS });
    expect(at.ttlMs).toBe(MAX_TTL_MS);

    const past = await ask(host, { id: "2", type: "modelwatch:arm", arms: ["prompts"], enabled: true, ttlMs: MAX_TTL_MS * 1000 });
    // A `setTimeout` past the 32-bit millisecond max fires IMMEDIATELY rather
    // than late, so an unclamped arm would lapse on the spot while this reply
    // said it was armed. Shortening costs the watcher nothing — it re-arms while
    // it runs — where refusing would cost it the capture.
    expect(past.ttlMs).toBe(MAX_TTL_MS);
    expect(isPromptCaptureArmed()).toBe(true);
  });

  it("clamps the window it ARMS, not only the one it reports", async () => {
    host = new HostServer({});
    await ask(host, { id: "1", type: "modelwatch:arm", arms: ["prompts", "context"], enabled: true, ttlMs: MAX_TTL_MS * 1000 });
    modelwatch.record(callEvent({ prompt: { scaffold: "we wrote this part", contextText: SECRET } }));

    // A clamp applied to the reply and not to the timer is the exact failure the
    // ceiling exists to prevent, wearing the ceiling's own answer: `setTimeout`
    // past the 32-bit millisecond max fires IMMEDIATELY, so the arms would lapse
    // within a millisecond while this caller was told it had an hour — and the
    // lapse takes the ring's text with it. Everything an operator could look at
    // says armed; nothing is recorded.
    await Bun.sleep(25);

    expect(isPromptCaptureArmed()).toBe(true);
    expect(isContextCaptureArmed()).toBe(true);
    expect(JSON.stringify(modelwatch.snapshot())).toContain(SECRET);
  });

  it("gives the context arm a shorter window than the prompt arm", async () => {
    host = new HostServer({});
    // Between the two ceilings, so the answer says which one each arm took.
    const both = await ask(host, { id: "1", type: "modelwatch:arm", arms: ["prompts", "context"], enabled: true, ttlMs: 600_000 });
    // The reply reports the SHORTEST window this request armed, because its one
    // consumer is a heartbeat that has to re-arm before the first of them
    // lapses. The prompt arm did get the full 600s; nothing on the wire needs to
    // say so, and a watcher pacing itself off it would lose the context arm.
    expect(both.ttlMs).toBe(CONTEXT_MAX_TTL_MS);

    const promptsOnly = await ask(host, { id: "2", type: "modelwatch:arm", arms: ["prompts"], enabled: true, ttlMs: 600_000 });
    // The dangerous arm's ceiling must not quietly become everyone's. What it
    // bounds is not the live run — the heartbeat renews well inside either — but
    // how long an excerpt outlives the watcher that took it, and the scaffold we
    // wrote ourselves is not that.
    expect(promptsOnly.ttlMs).toBe(600_000);
  });

  it("disarms with no window at all, and takes the text already in the ring with it", async () => {
    host = new HostServer({});
    await ask(host, { id: "1", type: "modelwatch:arm", arms: ["prompts", "context"], enabled: true, ttlMs: 60_000 });
    modelwatch.record(callEvent({
      prompt: { scaffold: "we wrote this part", contextText: SECRET },
      stdout: SECRET,
    }));
    expect(JSON.stringify(modelwatch.snapshot())).toContain(SECRET);

    const res = await ask(host, { id: "2", type: "modelwatch:arm", arms: ["prompts", "context"], enabled: false });

    expect(res).toMatchObject({ ok: true, prompts: false, context: false, ttlMs: 0 });
    // A switch that bounds only what is ADMITTED bounds nothing about what is
    // RETAINED, and this ring is sized to hold days rather than seconds — so an
    // excerpt taken during a one-minute window would otherwise still be readable
    // a week later, by a reader who armed nothing.
    expect(JSON.stringify(modelwatch.snapshot())).not.toContain(SECRET);
  });
});

describe("modelwatch:ui", () => {
  it("mints a ticket for the viewer the frame feed already has", async () => {
    host = new HostServer({});
    await host.startControlPlane();

    const res = await ask(host, { id: "1", type: "modelwatch:ui" });

    expect(res.ok).toBe(true);
    // A tab on that document rather than a second page, so a URL of its own here
    // would point at something nobody wrote. The ticket rides the FRAGMENT,
    // which no browser sends to a server and no proxy logs.
    expect(res.url).toMatch(/^http:\/\/127\.0\.0\.1:\d+\/netwatch\/ui#t=[0-9a-f]+$/);
    expect(res.expiresInMs).toBeGreaterThan(0);
  });

  it("refuses while the loopback plane is not bound", async () => {
    host = new HostServer({});

    const res = await ask(host, { id: "1", type: "modelwatch:ui" });

    // The port in that URL is the one the caller is already talking to. With no
    // listener there is no port to name, and inventing one would hand back a
    // window that opens on nothing.
    expect(res.ok).toBe(false);
    expect(res.error.code).toBe("NO_CONTROL_PLANE");
  });
});

describe("GET /modelwatch", () => {
  it("replays the ring on connect and says what it did not send", async () => {
    modelwatch.record(callEvent({ callId: "replay-1" }));
    modelwatch.record(callEvent({ callId: "replay-2", phase: "end", wallMs: 812 }));
    const port = await start();

    const res = await fetch(`http://127.0.0.1:${port}/modelwatch?follow=0`, {
      headers: { authorization: `Bearer ${HOST_TOKEN}` },
    });

    expect(res.status).toBe(200);
    expect(res.headers.get("content-type")).toBe("text/event-stream");
    const body = await res.text();
    // The call worth reading about — the judge that timed out, the title that
    // named itself after an error message — has already happened by the time
    // anyone attaches, so a feed that only followed would be empty exactly then.
    expect(body).toContain("replay-1");
    expect(body).toContain("replay-2");
    expect(body).toContain("event: replayed");
    expect(body).toContain('"replayed":2');
  });

  it("streams a call recorded after the reader attached", async () => {
    const port = await start();
    const res = await fetch(`http://127.0.0.1:${port}/modelwatch`, {
      headers: { authorization: `Bearer ${HOST_TOKEN}` },
    });
    const reader = res.body!.getReader();
    await readUntil(reader, "event: replayed");

    modelwatch.record(callEvent({ callId: "live-1", purpose: "title" }));

    expect(await readUntil(reader, "live-1")).toContain('"purpose":"title"');
    await reader.cancel();
  });

  it("does not answer a name that merely resolves to this address", async () => {
    const port = await start();
    // The shape of DNS rebinding: the socket lands here, but the document
    // believes its origin is somewhere the attacker controls.
    expect(status(await rawGet(port, "/modelwatch", "modelwatch.example.com"))).toBe("404");
    // The name it WAS published at gets as far as the credential check, which is
    // what shows the 404 above came from the guard rather than the bearer.
    expect(status(await rawGet(port, "/modelwatch", `127.0.0.1:${port}`))).toBe("401");
  });

  it("refuses a cross-site fetch even with a valid session", async () => {
    const port = await start();
    const token = await session(port);
    const res = await fetch(`http://127.0.0.1:${port}/modelwatch?follow=0`, {
      headers: { authorization: `Bearer ${token}`, "sec-fetch-site": "cross-site" },
    });
    expect(res.status).toBe(404);
  });

  it("refuses an Origin this listener never published", async () => {
    const port = await start();
    const token = await session(port);
    const res = await fetch(`http://127.0.0.1:${port}/modelwatch?follow=0`, {
      headers: { authorization: `Bearer ${token}`, origin: "https://calls.example.com" },
    });
    expect(res.status).toBe(404);
  });

  it("refuses a reader holding neither credential", async () => {
    const port = await start();
    expect((await fetch(`http://127.0.0.1:${port}/modelwatch?follow=0`)).status).toBe(401);
    const forged = await fetch(`http://127.0.0.1:${port}/modelwatch?follow=0`, {
      headers: { authorization: `Bearer ${"a".repeat(64)}` },
    });
    expect(forged.status).toBe(401);
  });

  it("reads the feed on a viewer session token", async () => {
    const port = await start();
    const token = await session(port);
    const res = await fetch(`http://127.0.0.1:${port}/modelwatch?follow=0`, {
      headers: { authorization: `Bearer ${token}` },
    });
    expect(res.status).toBe(200);
  });
});

describe("arming modelwatch from the viewer", () => {
  it("arms the prompt parts", async () => {
    const port = await start();
    const token = await session(port);

    const res = await arm(port, token, { id: "ui-arm", type: "modelwatch:arm", arms: ["prompts"], enabled: true, ttlMs: 300_000 });

    expect(res.status).toBe(200);
    expect(await res.json()).toMatchObject({ ok: true, type: "modelwatch:arm" });
    expect(seen.map((r) => r.type)).toEqual(["modelwatch:arm"]);
  });

  it("refuses the context arm, distinguishably from a verb it cannot reach at all", async () => {
    const port = await start();
    const token = await session(port);

    const context = await arm(port, token, { id: "ctx", type: "modelwatch:arm", arms: ["prompts", "context"], enabled: true, ttlMs: 300_000 });
    const elsewhere = await arm(port, token, { id: "stop", type: "project:stop", projectId: "p1" });

    // Netwatch's armable bodies are typed frames with a redaction list covering
    // the credential-bearing ones. This arm admits transcript and PTY scrollback
    // with no type and no list that could make it safe, and a session is one
    // pasted URL away from a page the operator never opened.
    expect(context.status).toBe(403);
    const refusal = (await context.json()) as { error: { code: string } };
    expect(refusal.error.code).toBe("CONTEXT_ARM_FORBIDDEN");

    expect(elsewhere.status).toBe(403);
    const unreachable = (await elsewhere.json()) as { error: { code: string } };
    // Two different answers on purpose: a viewer must be able to say the context
    // arm needs the CLI, where a shared code would send the operator looking for
    // a permission problem that is not there.
    expect(unreachable.error.code).not.toBe(refusal.error.code);
    // Refused at the door in both cases: nothing downstream had to know a viewer
    // exists, and nothing was armed on the way to saying no.
    expect(seen).toEqual([]);
  });

  it("refuses the prompt arm too, once the context arm is the one already up", async () => {
    const port = await start();
    const token = await session(port);
    // A state the CLI never leaves a host in — it always arms the pair — but one
    // a direct `/control` call reaches, and the host answers it happily with
    // `{prompts:false, context:true}` while recording nothing.
    armContextCapture(true, 60_000);

    const res = await arm(port, token, { id: "p", type: "modelwatch:arm", arms: ["prompts"], enabled: true, ttlMs: 300_000 });

    // From there the transcript is one permitted-looking POST away: text is
    // admitted iff BOTH arms are up, so arming the harmless-sounding half is
    // what starts recording it. A refusal keyed on the word "context" would let
    // a page that got at a session do exactly that, which is the single POST
    // this narrowing exists to prevent.
    expect(res.status).toBe(403);
    expect(((await res.json()) as { error: { code: string } }).error.code).toBe("CONTEXT_ARM_FORBIDDEN");
    expect(seen).toEqual([]);
  });

  it("still lets the viewer turn the context arm off", async () => {
    const port = await start();
    const token = await session(port);

    const res = await arm(port, token, { id: "off", type: "modelwatch:arm", arms: ["context"], enabled: false });

    // The hazard is admitting text. A viewer that can only ever stop a capture
    // is not one, and refusing here would leave a window open that the page in
    // front of the operator can see and cannot close.
    expect(res.status).toBe(200);
    expect(seen.map((r) => r.type)).toEqual(["modelwatch:arm"]);
  });
});

/** Reject rather than hang: a stream assertion that simply never resolves fails
 *  as a suite-wide timeout naming no test. */
function withTimeout<T>(p: Promise<T>, ms: number, what: string): Promise<T> {
  let timer: ReturnType<typeof setTimeout>;
  return Promise.race([
    p.finally(() => clearTimeout(timer)),
    new Promise<never>((_, reject) => {
      timer = setTimeout(() => reject(new Error(`timed out waiting for ${what}`)), ms);
    }),
  ]);
}

async function readUntil(reader: ReadableStreamDefaultReader<Uint8Array>, needle: string): Promise<string> {
  const decoder = new TextDecoder();
  let seenText = "";
  while (!seenText.includes(needle)) {
    const { value, done } = await withTimeout(reader.read(), 5_000, `${needle} on /modelwatch`);
    if (done) throw new Error(`stream ended before ${needle}; saw ${seenText}`);
    seenText += decoder.decode(value, { stream: true });
  }
  return seenText;
}

function status(reply: string): string {
  return reply.split(" ")[1];
}

/** A request with a Host header of our choosing. `fetch` derives Host from the
 *  URL and will not be told otherwise, and Host is the field the rebinding
 *  guard reads. */
function rawGet(port: number, path: string, hostHeader: string): Promise<string> {
  const CRLF = String.fromCharCode(13, 10);
  return new Promise((resolve, reject) => {
    const sock = connect(port, "127.0.0.1", () => {
      sock.write(`GET ${path} HTTP/1.1${CRLF}Host: ${hostHeader}${CRLF}Connection: close${CRLF}${CRLF}`);
    });
    let out = "";
    sock.setTimeout(5_000, () => sock.destroy(new Error("timed out")));
    sock.on("data", (chunk) => { out += chunk.toString(); });
    sock.on("end", () => resolve(out));
    sock.on("error", reject);
  });
}
