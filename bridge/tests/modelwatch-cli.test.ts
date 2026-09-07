// `antgrid calls`: what a reader is shown about the headless model calls this
// machine spawns, and what the run leaves behind on the host when it ends.
//
// The CLI is driven against a stand-in host rather than a real one — the point
// of every assertion here is the rendering and the arming protocol, and a real
// host would make both depend on whether a judge happened to run.
import { afterEach, beforeEach, describe, expect, it, spyOn } from "bun:test";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { runModelwatchCli } from "../src/cli/modelwatch";

type Record_ = Record<string, unknown>;

const HOST_TOKEN = "host-bearer-token-calls";

/** A host as this CLI sees one: a `/control` plane that answers the arming verb
 *  and a `/modelwatch` stream that replays a fixed capture and ends. Ending the
 *  stream is what a `--no-follow` snapshot and a host shutdown both look like
 *  from here, and it is what puts the disarm on the way out under test. */
function startFakeHost(opts: {
  events?: Record_[];
  /** Records sent AFTER the replay marker, which is the only way to put a call
   *  that was already running when the reader attached under test. */
  live?: Record_[];
  streamStatus?: number;
  armOk?: boolean;
} = {}): {
  dir: string;
  requests: Record_[];
  bearers: (string | null)[];
  stop: () => Promise<void>;
} {
  const requests: Record_[] = [];
  const bearers: (string | null)[] = [];
  const events = opts.events ?? [];
  const server = Bun.serve({
    hostname: "127.0.0.1",
    port: 0,
    fetch: async (req) => {
      const url = new URL(req.url);
      if (url.pathname === "/control") {
        const body = (await req.json()) as Record_;
        requests.push(body);
        if (opts.armOk === false) {
          return Response.json({ id: body.id, ok: false, error: { code: "NOPE", message: "refused" } }, { status: 400 });
        }
        const arms = (body.arms as string[] | undefined) ?? [];
        return Response.json({
          id: body.id,
          ok: true,
          type: "modelwatch:arm",
          prompts: body.enabled === true,
          context: body.enabled === true && arms.includes("context"),
          ttlMs: body.enabled === true ? 60_000 : 0,
        });
      }
      if (url.pathname === "/modelwatch") {
        bearers.push(req.headers.get("authorization"));
        if (opts.streamStatus && opts.streamStatus !== 200) {
          return new Response("no", { status: opts.streamStatus });
        }
        const replay = { recorded: events.length, evicted: 0, buffered: events.length, replayed: events.length };
        const body =
          events.map((e) => `data: ${JSON.stringify(e)}\n\n`).join("") +
          `event: replayed\ndata: ${JSON.stringify(replay)}\n\n` +
          (opts.live ?? []).map((e) => `data: ${JSON.stringify(e)}\n\n`).join("");
        return new Response(body, { headers: { "content-type": "text/event-stream" } });
      }
      return new Response("not found", { status: 404 });
    },
  });

  const dir = mkdtempSync(join(tmpdir(), "modelwatch-cli-"));
  writeFileSync(
    join(dir, "host.json"),
    JSON.stringify({
      version: 1,
      pid: process.pid,
      controlPort: server.port,
      token: HOST_TOKEN,
      startedAt: new Date().toISOString(),
      agentVersion: "0.0.0-test",
    }),
  );
  return {
    dir,
    requests,
    bearers,
    stop: async () => {
      server.stop(true);
      rmSync(dir, { recursive: true, force: true });
    },
  };
}

let prevAbDir: string | undefined;

/** Runs the CLI with stdout and stderr captured. `runModelwatchCli` sets
 *  ANTGRID_DIR from `--dir`, so the environment is put back afterwards. */
async function run(opts: Record_): Promise<{ code: number; out: string[]; err: string }> {
  prevAbDir = process.env.ANTGRID_DIR;
  const out: string[] = [];
  const err: string[] = [];
  const log = spyOn(console, "log").mockImplementation((...args: unknown[]) => { out.push(args.join(" ")); });
  const error = spyOn(console, "error").mockImplementation((...args: unknown[]) => { err.push(args.join(" ")); });
  try {
    const code = await runModelwatchCli(opts);
    return { code, out, err: err.join("\n") };
  } finally {
    log.mockRestore();
    error.mockRestore();
    if (prevAbDir === undefined) delete process.env.ANTGRID_DIR;
    else process.env.ANTGRID_DIR = prevAbDir;
  }
}

let seq = 0;
const at = Date.UTC(2026, 8, 7, 12, 0, 0);

/** The wall clock a row is stamped with, in this machine's zone — the renderer
 *  prints local time, so a fixture that computed UTC would pass only in Britain
 *  in winter. */
const hhmmss = (t: number): string => new Date(t).toTimeString().slice(0, 8);

const rec = (over: Record_ = {}): Record_ => ({
  seq: ++seq,
  at,
  callId: "abc123de-0000-4000-8000-000000000001",
  phase: "start",
  purpose: "decision",
  attempt: 1,
  requestedTool: "claude-code",
  actualTool: "claude-code",
  reach: "repo",
  ...over,
});

/**
 * One judge call as the recorder writes it: two attempts under one call id
 * against one shared budget, with what the first left recorded before the second
 * is dispatched.
 */
function retryPair(remainingMs: number): Record_[] {
  return [
    rec({ phase: "start", attempt: 1, promptChars: 9_000 }),
    rec({ phase: "end", attempt: 1, wallMs: 28_400, budgetMs: 45_000, exitCode: 0, timedOut: false, stdoutChars: 120 }),
    rec({ phase: "outcome", attempt: 1, outcome: "shape-rejected", remainingMs, outcomeDetail: "quote not in context" }),
    rec({ phase: "start", attempt: 2 }),
    rec({ phase: "end", attempt: 2, wallMs: 7_200, budgetMs: remainingMs, exitCode: 0, stdoutChars: 90 }),
    rec({ phase: "outcome", attempt: 2, outcome: "retried-parsed" }),
  ];
}

let fake: { dir: string; requests: Record_[]; bearers: (string | null)[]; stop: () => Promise<void> } | null = null;
let sigintHandlers = 0;

beforeEach(() => {
  sigintHandlers = process.listenerCount("SIGINT");
});

afterEach(async () => {
  await fake?.stop();
  fake = null;
  // Every run installs a SIGINT handler that defers Ctrl-C until the arms are
  // disarmed, and every run must take it away again. Asserted for the file
  // rather than in one test because each exit from `runModelwatchCli` is its own
  // path out. A handler left standing calls `process.exit(0)`, so after one
  // completed run inside a longer-lived process Ctrl-C exits 0 instead of taking
  // SIGINT's default — and each further run stacks another one.
  expect(process.listenerCount("SIGINT")).toBe(sigintHandlers);
});

describe("antgrid calls rendering", () => {
  it("renders a retry as one call's second attempt, not as a second call", async () => {
    fake = startFakeHost({ events: retryPair(16_600) });
    const { code, out } = await run({ dir: fake.dir, follow: false });

    expect(code).toBe(0);
    // Six records, two attempts: the spawn's two rows and the caller's verdict
    // for each are one model call apiece, and rendering them separately would
    // leave the timing and the outcome of one call on different lines.
    expect(out).toHaveLength(2);
    const [first, second] = out;
    // The join key is what makes the second row a retry rather than an unrelated
    // call that happened to land next.
    expect(first).toContain("abc123de");
    expect(second).toContain("abc123de");
    expect(first).toContain(" #1");
    expect(second).toContain("↳#2");
    expect(first).toContain("shape-rejected");
    expect(second).toContain("retried-parsed");
  });

  it("shows what the first attempt left, and that the retry inherited exactly it", async () => {
    fake = startFakeHost({ events: retryPair(16_600) });
    const { out } = await run({ dir: fake.dir, follow: false });

    // The number the feature exists for: the two attempts share one budget, so
    // what the first leaves IS the whole of what the second gets — visible here
    // as the same figure ending one row and bounding the next.
    expect(out[0]).toContain("28.4s/45.0s");
    expect(out[0]).toContain("16.6s left for the retry");
    expect(out[1]).toContain("7.2s/16.6s");
  });

  it("keeps two calls apart when their records interleave", async () => {
    // Concurrency across sessions is unbounded — nothing caps judge spawns
    // across terminals and title generation rides no chain at all — so N
    // sessions ending turns together interleave the start/end/outcome records of
    // distinct calls. Every other fixture in this file is strictly sequential,
    // which leaves the join key carrying no weight: folded on the wrong key, two
    // concurrent calls collapse into one row wearing the wrong tool, the wrong
    // timings and the wrong budget, and the other call disappears.
    fake = startFakeHost({
      events: [
        rec({ callId: "aaaa1111-decide", phase: "start", attempt: 1 }),
        rec({ callId: "bbbb2222-title", phase: "start", purpose: "title", requestedTool: "codex", actualTool: "claude-code", reach: "none" }),
        rec({ callId: "aaaa1111-decide", phase: "end", attempt: 1, wallMs: 28_400, budgetMs: 45_000, exitCode: 0 }),
        rec({ callId: "bbbb2222-title", phase: "end", purpose: "title", requestedTool: "codex", actualTool: "claude-code", reach: "none", wallMs: 3_100, budgetMs: 45_000, exitCode: 0 }),
        rec({ callId: "aaaa1111-decide", phase: "outcome", attempt: 1, outcome: "shape-rejected", remainingMs: 16_600 }),
        rec({ callId: "bbbb2222-title", phase: "outcome", purpose: "title", requestedTool: "codex", actualTool: "claude-code", reach: "none", outcome: "named" }),
        rec({ callId: "aaaa1111-decide", phase: "start", attempt: 2 }),
        rec({ callId: "aaaa1111-decide", phase: "end", attempt: 2, wallMs: 7_200, budgetMs: 16_600, exitCode: 0 }),
        rec({ callId: "aaaa1111-decide", phase: "outcome", attempt: 2, outcome: "retried-parsed" }),
      ],
    });
    const { out } = await run({ dir: fake.dir, follow: false });

    expect(out).toHaveLength(3);
    expect(out[0]).toContain("aaaa1111");
    expect(out[0]).toContain("28.4s/45.0s");
    expect(out[0]).toContain("shape-rejected");
    // The title's own row carries the title's own tool, timing and verdict —
    // none of which belong to the decision whose records surrounded it.
    expect(out[1]).toContain("bbbb2222");
    expect(out[1]).toContain("codex→claude-code");
    expect(out[1]).toContain("3.1s/45.0s");
    expect(out[1]).toContain("named");
    expect(out[1]).not.toContain("28.4s");
    // The retry is indented under the call it retried, and under that call's id.
    expect(out[2]).toContain("aaaa1111");
    expect(out[2]).toContain("↳#2");
    expect(out[2]).toContain("7.2s/16.6s");
  });

  it("does not fold a retry into an attempt whose verdict never arrived", async () => {
    // The host sheds live records when this reader falls behind, and holds only
    // so many attempts open at once, so an attempt can lose its outcome record
    // and stay pending. Joined on the call id alone, the retry's records then
    // land on top of the attempt they retried — one row, the first attempt's
    // number, the second attempt's timings, and no sign a retry ever happened.
    fake = startFakeHost({
      events: [
        rec({ callId: "aaaa1111-decide", phase: "start", attempt: 1 }),
        rec({ callId: "aaaa1111-decide", phase: "end", attempt: 1, wallMs: 28_400, budgetMs: 45_000, exitCode: 0 }),
        rec({ callId: "aaaa1111-decide", phase: "start", attempt: 2 }),
        rec({ callId: "aaaa1111-decide", phase: "end", attempt: 2, wallMs: 7_200, budgetMs: 16_600, exitCode: 0 }),
        rec({ callId: "aaaa1111-decide", phase: "outcome", attempt: 2, outcome: "retried-parsed" }),
      ],
    });
    const { out, err } = await run({ dir: fake.dir, follow: false });

    expect(out).toHaveLength(2);
    // The retry completes first — its verdict arrived — and the attempt with no
    // verdict is flushed at the end of the run, under-described but present.
    expect(out[0]).toContain("↳#2");
    expect(out[0]).toContain("7.2s/16.6s");
    expect(out[1]).toContain(" #1");
    expect(out[1]).toContain("28.4s/45.0s");
    expect(err).toContain("1 calls, 2 attempts, 1 of them retries");
  });

  it("says outright when a first attempt left the retry unreachable", async () => {
    fake = startFakeHost({ events: retryPair(300) });
    const { out, err } = await run({ dir: fake.dir, follow: false });

    // 300ms cannot cover process startup and a vendor preamble, so the retry was
    // dispatched already dead. Without this the row reads as an ordinary retry
    // and the arithmetic is only visible under --json.
    expect(out[0]).toContain("unreachable");
    expect(err).toContain("retries left unreachable 1");
  });

  it("does not call a slow but successful attempt a starved retry", async () => {
    fake = startFakeHost({
      events: [
        rec({ phase: "start", attempt: 1 }),
        rec({ phase: "end", attempt: 1, wallMs: 5_600, budgetMs: 6_000, exitCode: 0, stdoutChars: 90 }),
        // The judge records what it had left on its SUCCESS leg too, which is
        // worth having — it is the measurement that says whether the budget is
        // set anywhere near the truth — but there was no retry for it to starve.
        rec({ phase: "outcome", attempt: 1, outcome: "parsed", remainingMs: 384 }),
      ],
    });
    const { out, err } = await run({ dir: fake.dir, follow: false });

    // Read as a starvation, every slow-and-correct judge call turns into a red
    // row, and a machine whose judge merely takes most of its budget reports its
    // every call as a dead retry — with the tally then contradicting itself on
    // the same screen: "0 of them retries" above "retries left unreachable 1".
    expect(out[0]).toContain("parsed");
    expect(out[0]).not.toContain("unreachable");
    expect(out[0]).not.toContain("left for the retry");
    expect(err).toContain("1 calls, 1 attempts, 0 of them retries");
    expect(err).toContain("retries left unreachable 0");
  });

  it("names the agent asked for beside the one that actually ran", async () => {
    fake = startFakeHost({
      events: [
        rec({ callId: "borrowed", purpose: "title", requestedTool: "codex", actualTool: "claude-code", reach: "none" }),
        rec({ callId: "borrowed", purpose: "title", phase: "outcome", requestedTool: "codex", actualTool: "claude-code", reach: "none", outcome: "named" }),
        ...retryPair(16_600),
      ],
    });
    const { out, err } = await run({ dir: fake.dir, follow: false });

    // A borrowed title bills a vendor this session never chose, and nothing else
    // on the machine counts it.
    expect(out[0]).toContain("codex→claude-code");
    expect(err).toContain("borrowed 1");
    // A call that ran on its own agent says so once, not twice.
    expect(out[1]).toContain("claude-code");
    expect(out[1]).not.toContain("→");
  });

  it("marks a call that named no model at all", async () => {
    fake = startFakeHost({
      events: [
        rec({ phase: "outcome", outcome: "parsed" }),
        rec({ callId: "with-model", phase: "outcome", requestedModel: "haiku-4.5", outcome: "parsed" }),
      ],
    });
    const { out, err } = await run({ dir: fake.dir, follow: false });

    // Absent is not unknown: it is the call that passed no --model and therefore
    // ran on whatever this machine's CLI defaults to, which for a three-word
    // naming task is the single largest cost lever there is.
    expect(out[0]).toContain("default");
    expect(out[1]).toContain("haiku-4.5");
    expect(err).toContain("on the CLI's default model 1");
  });

  it("prints a call that was running when the reader attached exactly once", async () => {
    // The case someone runs this command for: attach while a judge is mid-spawn.
    // Its `start` is in the replay and its `end` and verdict arrive live, so a
    // reader that flushed everything at the live marker would print it once as
    // "in flight" and again when it finished — one call, two rows, two entries
    // in every tally, and everything carried only on the `start` (`promptChars`,
    // and the prompt parts an arm admitted) stranded on the phantom.
    fake = startFakeHost({
      events: [rec({ phase: "start", attempt: 1, promptChars: 9_000 })],
      live: [
        rec({ phase: "end", at: at + 28_400, attempt: 1, wallMs: 28_400, budgetMs: 45_000, exitCode: 0, stdoutChars: 120 }),
        rec({ phase: "outcome", at: at + 28_400, attempt: 1, outcome: "parsed" }),
      ],
    });
    const { out, err } = await run({ dir: fake.dir });

    expect(out).toHaveLength(1);
    expect(out[0]).toContain("28.4s/45.0s");
    expect(out[0]).toContain("parsed");
    expect(out[0]).not.toContain("in flight");
    // The row wears the clock of the record that STARTED the attempt, never the
    // one that ended it, so rows read in the order the calls were made.
    expect(out[0]).toContain(hhmmss(at));
    expect(out[0]).not.toContain(hhmmss(at + 28_400));
    expect(err).toContain("1 calls, 1 attempts");
  });

  it("keeps a model's own words out of the operator's terminal", async () => {
    const esc = String.fromCharCode(27);
    fake = startFakeHost({
      events: [rec({ phase: "outcome", outcome: "unparsed", outcomeDetail: `before${esc}[2Jafter` })],
    });
    const { out } = await run({ dir: fake.dir, follow: false });

    // An outcomeDetail quotes the model's answer back, and a CLI's stdout can
    // repaint or retitle the window it is printed into.
    expect(out[0]).not.toContain(esc);
    expect(out[0]).toContain("before[2Jafter");
  });
});

describe("antgrid calls filtering and output modes", () => {
  const mixed = (): Record_[] => [
    rec({ callId: "title-call", purpose: "title", phase: "outcome", outcome: "named" }),
    rec({ callId: "decide-call", purpose: "decision", phase: "outcome", outcome: "parsed" }),
    rec({ callId: "extract-call", purpose: "extraction", phase: "outcome", outcome: "parsed" }),
  ];

  it("shows only the kind of call it was asked for", async () => {
    fake = startFakeHost({ events: mixed() });
    const { code, out } = await run({ dir: fake.dir, follow: false, purpose: "decision" });

    expect(code).toBe(0);
    expect(out).toHaveLength(1);
    // The id column is a call's first eight characters, which is all a row
    // prints of it — enough to join two attempts by eye, and to `--json`.
    expect(out[0]).toContain("decide-c");
    expect(out.join("\n")).not.toContain("title");
  });

  it("refuses a purpose that is not one of the three", async () => {
    fake = startFakeHost({ events: [] });
    const { code, err } = await run({ dir: fake.dir, follow: false, purpose: "titles" });

    expect(code).toBe(1);
    expect(err).toContain("title, decision, extraction");
  });

  it("emits the records themselves under --json, one per record", async () => {
    fake = startFakeHost({ events: retryPair(16_600) });
    const { code, out, err } = await run({ dir: fake.dir, follow: false, json: true });

    expect(code).toBe(0);
    // Not the rendered attempts: a reader piping this into a tool of their own
    // wants what the recorder wrote, and joining two records into one row here
    // would be this CLI deciding what that tool gets to see.
    expect(out).toHaveLength(6);
    expect(JSON.parse(out[0])).toMatchObject({ phase: "start", attempt: 1 });
    expect(JSON.parse(out[5])).toMatchObject({ phase: "outcome", outcome: "retried-parsed" });
    // The summary is a rendering, so it stays off a machine-readable stream.
    expect(err).not.toContain("attempts");
  });

  it("shows captured text on screen and keeps it out of the export file", async () => {
    const secret = "sk-live-TRANSCRIPT-IN-THE-PROMPT";
    fake = startFakeHost({
      events: [
        rec({
          phase: "start",
          promptChars: 400,
          prompt: {
            scaffold: "Decide whether the agent is done.",
            context: { sha256: "9f2a1c3d4e5f60718293a4b5c6d7e8f9", chars: 11_840 },
            contextText: secret,
          },
        }),
        rec({ phase: "end", wallMs: 1_200, budgetMs: 45_000, exitCode: 0, stdoutChars: 40, stdout: secret }),
        rec({ phase: "outcome", outcome: "parsed" }),
      ],
    });
    const file = join(fake.dir, "calls.jsonl");
    const { code, out } = await run({ dir: fake.dir, follow: false, export: file });

    expect(code).toBe(0);
    // The arms put the text in front of the operator for the length of one run.
    expect(out[0]).toContain(secret);
    expect(out[0]).toContain("9f2a1c3d4e5f");
    // A file outlives the run, the window and the arm's own dead man's switch,
    // and an export is written to be pasted into a bug report.
    const exported = readFileSync(file, "utf8");
    expect(exported).not.toContain(secret);
    expect(exported).toContain('"outcome":"parsed"');
    expect(JSON.parse(exported.split("\n")[0]).prompt).toBeUndefined();
  });

  it("writes the durable feed's field list to the export, and nothing beyond it", async () => {
    const quoted = "sk-live-QUOTED-BACK-BY-THE-JUDGE";
    fake = startFakeHost({
      events: [
        rec({
          phase: "outcome",
          outcome: "shape-rejected",
          remainingMs: 16_600,
          // A Zod issue quoting the judge's own JSON. The judge is required to
          // quote the transcript back character for character, so its text is
          // the user's text one hop removed — which is why modelwatch-log.ts
          // names this field as the one that looks safe and is not.
          outcomeDetail: `Invalid enum value. Received '${quoted}'`,
          // Stands in for a field the record gains later. Under a deny-list it
          // reaches the file the moment it exists, with nobody editing the
          // export at all — the vendors' usage envelopes being the obvious one.
          usage: { inputTokens: 16_550 },
        }),
      ],
    });
    const file = join(fake.dir, "calls.jsonl");
    const { code, out } = await run({ dir: fake.dir, follow: false, export: file });

    expect(code).toBe(0);
    // On the operator's own screen for the length of one run, as the arms and
    // the ring's eviction bound it.
    expect(out[0]).toContain(quoted);

    const raw = readFileSync(file, "utf8");
    const line = JSON.parse(raw.trim());
    expect(line.outcome).toBe("shape-rejected");
    expect(line.remainingMs).toBe(16_600);
    expect(line.outcomeDetail).toBeUndefined();
    expect(line.usage).toBeUndefined();
    expect(raw).not.toContain(quoted);
  });
});

describe("antgrid calls arming", () => {
  it("arms prompt capture and disarms it when the stream ends", async () => {
    fake = startFakeHost({ events: retryPair(16_600) });
    const { code } = await run({ dir: fake.dir, prompts: true });

    expect(code).toBe(0);
    // The arm is a dead man's switch the watcher holds open; the disarm is what
    // stops the host recording prompt text — and drops what it already recorded.
    expect(fake.requests.map((r) => [r.type, r.arms, r.enabled])).toEqual([
      ["modelwatch:arm", ["prompts"], true],
      ["modelwatch:arm", ["prompts"], false],
    ]);
  });

  it("asks for both arms when the transcript is wanted", async () => {
    fake = startFakeHost({ events: [] });
    await run({ dir: fake.dir, context: true });

    // The transcript and the model's answer are admitted only while the prompt
    // arm is up too, so honouring --context literally would arm the dangerous
    // capture and then record nothing through it.
    expect(fake.requests[0].arms).toEqual(["prompts", "context"]);
    expect(fake.requests[1]).toMatchObject({ arms: ["prompts", "context"], enabled: false });
  });

  it("disarms on the way out of a failed run too", async () => {
    fake = startFakeHost({ events: [], streamStatus: 500 });
    const { code, err } = await run({ dir: fake.dir, prompts: true });

    expect(code).toBe(1);
    expect(err).toContain("HTTP 500");
    // The arm landed before the stream was refused. An exit that skipped the
    // disarm would leave this host recording prompt text until the TTL lapsed,
    // with the watcher that armed it already gone.
    expect(fake.requests.map((r) => r.enabled)).toEqual([true, false]);
  });

  it("sends no disarm for a capture the host never armed", async () => {
    fake = startFakeHost({ events: [], armOk: false });
    const { code, err } = await run({ dir: fake.dir, prompts: true });

    expect(code).toBe(1);
    expect(err).toContain("could not arm");
    // Only what was actually armed is held: a run that disarmed a capture it
    // never got would be turning off a window someone else opened.
    expect(fake.requests.map((r) => r.enabled)).toEqual([true]);
  });

  it("refuses to arm for a snapshot that is already in the ring", async () => {
    fake = startFakeHost({ events: [] });
    const { code, err } = await run({ dir: fake.dir, prompts: true, follow: false });

    // Arming records the future, so with no stream to follow the window would
    // open and close around a snapshot it could never have filled.
    expect(code).toBe(1);
    expect(err).toContain("--prompts/--context need a live stream");
    expect(fake.requests).toEqual([]);
  });

  it("presents the host bearer to the stream, and nothing else", async () => {
    fake = startFakeHost({ events: [] });
    await run({ dir: fake.dir, follow: false });

    // host.json's token is the whole of the loopback plane's authentication.
    expect(fake.bearers).toEqual([`Bearer ${HOST_TOKEN}`]);
  });

  it("says where it looked when no host is running", async () => {
    const dir = mkdtempSync(join(tmpdir(), "modelwatch-cli-empty-"));
    try {
      const { code, err } = await run({ dir, follow: false });
      expect(code).toBe(1);
      expect(err).toContain("no running host found");
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});
