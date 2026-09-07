import { afterEach, beforeEach, describe, expect, it } from "bun:test";
import { createHash } from "node:crypto";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import { modelwatch, __resetModelwatchForTest, armContextCapture, armPromptCapture, type ModelCallEvent } from "../src/modelwatch";
import {
  MODEL_CALL_LOG_FIELDS,
  MODEL_CALL_LOG_HARD_MAX_BYTES,
  MODEL_CALL_LOG_MAX_BYTES,
  modelCallLogPath,
  modelCallLogRolledPath,
  __resubscribeModelCallLogForTest,
  __unsubscribeModelCallLogForTest,
} from "../src/modelwatch-log";

let abDir: string;
let prevAbDir: string | undefined;
let prevSwitch: string | undefined;

beforeEach(() => {
  prevAbDir = process.env.ANTGRID_DIR;
  prevSwitch = process.env.ANTGRID_MODELWATCH_LOG;
  abDir = mkdtempSync(join(tmpdir(), "antgrid-modelwatch-log-"));
  process.env.ANTGRID_DIR = abDir;
  // The ring reset clears its subscriber set wholesale, so the writer has to be
  // re-attached AFTER it: the suite shares one module cache across spec files,
  // and a writer left detached by an earlier reset makes every assertion here
  // pass or fail on file order rather than on behaviour.
  __resetModelwatchForTest();
  __resubscribeModelCallLogForTest();
});

afterEach(() => {
  __resetModelwatchForTest();
  // Left detached on the way out so this file's re-attach does not outlive it.
  // The developer's real state dir is not what this protects — `unpinnedTestProcess`
  // in the module itself is what does that, unconditionally and in whatever order
  // Bun happens to run the files in. What is left is the spec file that pins an
  // ANTGRID_DIR of its own and drives a model call for unrelated reasons: it would
  // find a model-calls.jsonl in a state dir it is making assertions about, and the
  // failure would be attributed to anything but this file.
  __unsubscribeModelCallLogForTest();
  if (prevAbDir === undefined) delete process.env.ANTGRID_DIR;
  else process.env.ANTGRID_DIR = prevAbDir;
  if (prevSwitch === undefined) delete process.env.ANTGRID_MODELWATCH_LOG;
  else process.env.ANTGRID_MODELWATCH_LOG = prevSwitch;
  rmSync(abDir, { recursive: true, force: true });
});

/** A recorded attempt with only the fields a caller could not omit. */
function call(overrides: Partial<Omit<ModelCallEvent, "seq" | "at">> = {}) {
  return {
    callId: "c1",
    phase: "end" as const,
    purpose: "decision" as const,
    attempt: 1,
    requestedTool: "claude-code",
    actualTool: "claude-code",
    reach: "repo",
    ...overrides,
  };
}

function lines(): string[] {
  const raw = readFileSync(modelCallLogPath(abDir), "utf8");
  return raw.length === 0 ? [] : raw.slice(0, -1).split("\n");
}

const SECRET_SCAFFOLD = "SCAFFOLD-SECRET-ba9f";
const SECRET_GOAL = "GOAL-SECRET-c31d";
const SECRET_CONTEXT = "CONTEXTTEXT-SECRET-77ae";
const SECRET_STDOUT = "STDOUT-SECRET-4f0b";
const SECRET_DETAIL = "OUTCOMEDETAIL-SECRET-90cc";

/**
 * Every field of the event, populated.
 *
 * Typed as `Required<...>` on purpose, and it is half of what this suite is for:
 * a field added to `ModelCallEvent` and forgotten everywhere else fails the
 * typecheck HERE, before anyone has to notice it on disk. The runtime key-set
 * assertion below is the other half — it catches the field that was added to
 * this fixture and quietly allowed through to the file.
 */
const everyField: Required<Omit<ModelCallEvent, "seq" | "at">> = {
  callId: "call-9f2a",
  phase: "end",
  purpose: "decision",
  attempt: 2,
  requestedTool: "cursor-agent",
  actualTool: "claude-code",
  reach: "repo",
  requestedModel: "claude-haiku-4-5",
  actualModel: "mai-code-1.1-flash",
  terminalId: "term-1",
  conversationId: "conv-1",
  projectId: "proj-1",
  wallMs: 4821,
  apiMs: 2600,
  exitCode: 0,
  timedOut: false,
  budgetMs: 45_000,
  remainingMs: 40_179,
  usage: {
    inputTokens: 16_550,
    cacheReadTokens: 12_288,
    cacheWriteTokens: 22_885,
    outputTokens: 41,
    money: { unit: "premium-requests", amount: 0.33 },
    numTurns: 1,
    permissionDenials: 0,
  },
  outcome: "shape-rejected",
  outcomeDetail: SECRET_DETAIL,
  promptChars: 11_842,
  stdoutChars: 214,
  prompt: {
    scaffold: SECRET_SCAFFOLD,
    goal: SECRET_GOAL,
    backlogChars: 91,
    context: { sha256: createHash("sha256").update(SECRET_CONTEXT).digest("hex"), chars: 11_000 },
    contextText: SECRET_CONTEXT,
  },
  stdout: SECRET_STDOUT,
};

describe("the durable record is an allow-list", () => {
  it("writes no text field, with both arms armed and every field populated", () => {
    // Armed, so nothing about the arms can be offered as the reason the text is
    // missing: the file's rule is that no arm-gated field is ever written, not
    // that the arms happened to be down.
    armPromptCapture(true, 60_000);
    armContextCapture(true, 60_000);
    modelwatch.record(everyField);

    const raw = readFileSync(modelCallLogPath(abDir), "utf8");
    for (const secret of [SECRET_SCAFFOLD, SECRET_GOAL, SECRET_CONTEXT, SECRET_STDOUT, SECRET_DETAIL]) {
      expect(raw).not.toContain(secret);
    }
    // The digest is not the text, and it still does not go to disk — a field
    // whose presence depends on an arm has no place in a record that is always on.
    expect(raw).not.toContain(everyField.prompt.context!.sha256);
    expect(raw).not.toContain("contextText");
    expect(raw).not.toContain("scaffold");
  });

  it("writes exactly the allow-listed keys and no others", () => {
    armPromptCapture(true, 60_000);
    armContextCapture(true, 60_000);
    modelwatch.record(everyField);

    const parsed = JSON.parse(lines()[0]!) as Record<string, unknown>;
    // EQUALS, not "contains": a field added to the event and passed straight
    // through has to turn this red rather than reach a user's disk.
    expect(Object.keys(parsed).sort()).toEqual([...MODEL_CALL_LOG_FIELDS].sort());
  });

  it("keeps the counts, which say the same thing with nothing to leak", () => {
    modelwatch.record(everyField);
    const parsed = JSON.parse(lines()[0]!);
    expect(parsed.promptChars).toBe(11_842);
    expect(parsed.stdoutChars).toBe(214);
    expect(parsed.seq).toBe(1);
    expect(parsed.actualTool).toBe("claude-code");
    expect(parsed.requestedTool).toBe("cursor-agent");
  });

  it("omits usage until a wave names its fields here", () => {
    // The allow-list's whole purpose stated as an assertion: Wave 4 fills this
    // envelope in, and until someone decides field by field what of it belongs
    // on disk, none of it arrives there by default.
    modelwatch.record(everyField);
    expect(readFileSync(modelCallLogPath(abDir), "utf8")).not.toContain("inputTokens");
  });
});

describe("JSONL shape", () => {
  it("writes one newline-terminated JSON object per event", () => {
    modelwatch.record(call({ callId: "a" }));
    modelwatch.record(call({ callId: "b", phase: "outcome", outcome: "parsed" }));

    const raw = readFileSync(modelCallLogPath(abDir), "utf8");
    expect(raw.endsWith("\n")).toBe(true);
    const parsed = raw.slice(0, -1).split("\n").map((l) => JSON.parse(l));
    expect(parsed.map((p) => p.callId)).toEqual(["a", "b"]);
    expect(parsed.map((p) => p.seq)).toEqual([1, 2]);
  });
});

describe("rotation", () => {
  /** A body of valid JSONL at least as large as the cap, so a roll can be shown
   *  to have preserved what it moved rather than merely to have moved something. */
  function fillToCap(marker: string): void {
    const line = `${JSON.stringify({ marker })}\n`;
    writeFileSync(
      modelCallLogPath(abDir),
      line.repeat(Math.ceil(MODEL_CALL_LOG_MAX_BYTES / line.length)),
      "utf8",
    );
  }

  it("leaves a log under the cap alone", () => {
    modelwatch.record(call());
    modelwatch.record(call({ callId: "c2" }));
    expect(existsSync(modelCallLogRolledPath(abDir))).toBe(false);
    expect(lines()).toHaveLength(2);
  });

  it("rolls at the cap, losing no record across the boundary", () => {
    fillToCap("pre-roll");
    modelwatch.record(call({ callId: "after-roll" }));

    const live = lines();
    expect(live).toHaveLength(1);
    expect(JSON.parse(live[0]!).callId).toBe("after-roll");

    const rolled = readFileSync(modelCallLogRolledPath(abDir), "utf8");
    expect(rolled.length).toBeGreaterThanOrEqual(MODEL_CALL_LOG_MAX_BYTES);
    const rolledLines = rolled.slice(0, -1).split("\n");
    expect(JSON.parse(rolledLines[0]!).marker).toBe("pre-roll");
    expect(JSON.parse(rolledLines[rolledLines.length - 1]!).marker).toBe("pre-roll");
  });

  it("keeps exactly one rolled generation", () => {
    fillToCap("first");
    modelwatch.record(call({ callId: "r1" }));
    fillToCap("second");
    modelwatch.record(call({ callId: "r2" }));

    expect(readdirSync(abDir).sort()).toEqual(["model-calls.1.jsonl", "model-calls.jsonl"]);
    const rolled = readFileSync(modelCallLogRolledPath(abDir), "utf8");
    expect(JSON.parse(rolled.slice(0, rolled.indexOf("\n"))).marker).toBe("second");
    expect(JSON.parse(lines()[0]!).callId).toBe("r2");
  });

  it("skips a rotation the OS refuses and still appends", () => {
    // A directory standing where the rolled file goes makes renameSync fail the
    // way a held file handle does on Windows, with no stub in the way. The
    // record must still land: an observer that could not rotate is not an
    // observer that stops observing.
    fillToCap("held");
    mkdirSync(modelCallLogRolledPath(abDir));
    writeFileSync(join(modelCallLogRolledPath(abDir), "holder"), "x", "utf8");

    expect(() => modelwatch.record(call({ callId: "unrotated" }))).not.toThrow();

    const raw = readFileSync(modelCallLogPath(abDir), "utf8");
    expect(raw.length).toBeGreaterThan(MODEL_CALL_LOG_MAX_BYTES);
    const last = raw.slice(0, -1).split("\n").pop()!;
    expect(JSON.parse(last).callId).toBe("unrotated");
  });

  it("compacts onto its own tail once a refusal that never lifts passes the hard ceiling", () => {
    // The same wedge as the test above, left in place rather than treated as
    // transient: nothing renames over a non-empty directory on any platform, so
    // rotation can never succeed again on this install. Tolerating that with no
    // second bound is what would let the observer fill the user's disk.
    mkdirSync(modelCallLogRolledPath(abDir));
    writeFileSync(join(modelCallLogRolledPath(abDir), "holder"), "x", "utf8");

    const body = (marker: string, bytes: number): string => {
      const line = `${JSON.stringify({ marker })}\n`;
      return line.repeat(Math.ceil(bytes / line.length));
    };
    // Oldest half first, so "the tail survives" is a claim about position rather
    // than about which of two markers happens to be left.
    writeFileSync(
      modelCallLogPath(abDir),
      body("evicted", MODEL_CALL_LOG_MAX_BYTES) + body("kept", MODEL_CALL_LOG_MAX_BYTES + 4096),
      "utf8",
    );
    const before = statSync(modelCallLogPath(abDir)).size;
    expect(before).toBeGreaterThan(MODEL_CALL_LOG_HARD_MAX_BYTES);

    expect(() => modelwatch.record(call({ callId: "after-compaction" }))).not.toThrow();

    const after = statSync(modelCallLogPath(abDir)).size;
    expect(after).toBeLessThanOrEqual(MODEL_CALL_LOG_HARD_MAX_BYTES);
    expect(after).toBeLessThan(before);

    // Parsed, not scanned: a cut taken at a fixed byte offset rather than at a
    // record boundary leaves a file the reader this feature exists for cannot
    // read, and a substring search would not notice.
    const parsed = lines().map((l) => JSON.parse(l) as Record<string, unknown>);
    expect(parsed[parsed.length - 1]!.callId).toBe("after-compaction");
    expect(parsed.some((p) => p.marker === "kept")).toBe(true);
    expect(parsed.some((p) => p.marker === "evicted")).toBe(false);
  });
});

describe("the observer never breaks the observed", () => {
  it("swallows a write failure and keeps the ring recording", () => {
    // A directory where the log file goes: appendFileSync cannot write to it on
    // any platform, which is a stand-in for the full volume and the file another
    // process holds open.
    mkdirSync(modelCallLogPath(abDir));

    expect(() => modelwatch.record(call({ callId: "doomed" }))).not.toThrow();
    expect(() => modelwatch.record(call({ callId: "doomed-2" }))).not.toThrow();

    expect(modelwatch.buffered).toBe(2);
    expect(modelwatch.snapshot().map((e) => e.callId)).toEqual(["doomed", "doomed-2"]);
  });
});

/**
 * Everything above this point runs against a writer THIS FILE attached by hand
 * in `beforeEach`, because `__resetModelwatchForTest` clears the ring's
 * subscriber set wholesale. That seam is necessary and it is also a blind spot
 * wide enough to hide the feature: with the side-effect import deleted from
 * `agents/headless.ts` — the one line that makes any of this happen in a shipped
 * bridge — every assertion in this file still passes, and so does the full
 * suite. A bundler that drops a side-effect import, or a tidy-up that moves that
 * line, would ship a bridge whose durable feed is permanently empty with nothing
 * red to show for it.
 *
 * So these two run in a FRESH process, which is the only place the question can
 * be asked: this one's module cache has held the writer since the first import.
 */
describe("the production wiring", () => {
  /**
   * A bun process that imports the spawn chokepoint and records one event.
   *
   * It imports `agents/headless.ts` and nothing else from this feature, so the
   * writer is attached only if that file still pulls the module in. `modelwatch`
   * itself is imported for the recorder handle alone — it attaches nothing.
   */
  function runProbe(env: Record<string, string>): { exitCode: number; stderr: string } {
    const src = (...parts: string[]) => JSON.stringify(pathToFileURL(join(import.meta.dir, "..", "src", ...parts)).href);
    const script = join(abDir, "wiring-probe.ts");
    writeFileSync(
      script,
      [
        `import { modelwatch } from ${src("modelwatch.ts")};`,
        `import ${src("agents", "headless.ts")};`,
        `modelwatch.record({`,
        `  callId: "wired", phase: "start", purpose: "title", attempt: 1,`,
        `  requestedTool: "kimi", actualTool: "claude-code", reach: "none",`,
        `});`,
        "",
      ].join("\n"),
      "utf8",
    );
    const proc = Bun.spawnSync([process.execPath, script], { env, stdout: "pipe", stderr: "pipe" });
    return { exitCode: proc.exitCode, stderr: proc.stderr.toString() };
  }

  /** The parent's own env, minus everything this feature reads off it, so each
   *  case states its whole configuration rather than inheriting half of it. */
  function baseEnv(): Record<string, string> {
    const env = { ...process.env } as Record<string, string>;
    delete env.ANTGRID_DIR;
    delete env.ANTGRID_MODELWATCH_LOG;
    delete env.NODE_ENV;
    return env;
  }

  it("attaches through agents/headless.ts alone, with no test seam involved", () => {
    const state = join(abDir, "child-state");
    const { exitCode, stderr } = runProbe({ ...baseEnv(), ANTGRID_DIR: state });
    expect(stderr).toBe("");
    expect(exitCode).toBe(0);

    const raw = readFileSync(join(state, "model-calls.jsonl"), "utf8");
    expect(JSON.parse(raw.slice(0, -1)).callId).toBe("wired");
  });

  it("writes nothing from a bun test process that named no state dir", () => {
    // The corruption this guards against, at its root: `bun test
    // tests/handler/judge.test.ts` pulls this module in transitively, and
    // without the refusal it appends seventy fabricated records — scripted
    // spawns, `wallMs: 0` — to the developer's real `~/.antgrid`. HOME is
    // redirected so a regression lands in a temp dir rather than in the very
    // file it is about.
    const home = join(abDir, "child-home");
    mkdirSync(home);
    const { exitCode, stderr } = runProbe({
      ...baseEnv(), NODE_ENV: "test", HOME: home, USERPROFILE: home,
    });
    expect(stderr).toBe("");
    expect(exitCode).toBe(0);

    // Not merely no log file: `appendModelCall` creates the state dir on its way
    // to writing one, so its absence is what proves nothing was attempted.
    expect(existsSync(join(home, ".antgrid"))).toBe(false);
  });
});

describe("the kill switch", () => {
  it("writes nothing at all when ANTGRID_MODELWATCH_LOG=0", () => {
    process.env.ANTGRID_MODELWATCH_LOG = "0";
    modelwatch.record(call());
    // Not merely an empty file: the state dir is not even touched.
    expect(readdirSync(abDir)).toEqual([]);
    expect(modelwatch.buffered).toBe(1);
  });

  it("takes effect on a running process, in both directions", () => {
    process.env.ANTGRID_MODELWATCH_LOG = "0";
    modelwatch.record(call({ callId: "off" }));
    delete process.env.ANTGRID_MODELWATCH_LOG;
    modelwatch.record(call({ callId: "on" }));

    const written = lines().map((l) => JSON.parse(l).callId);
    expect(written).toEqual(["on"]);
  });
});
