import { afterEach, beforeEach, describe, expect, it } from "bun:test";
import { createHash } from "node:crypto";
import {
  Modelwatch,
  modelwatch,
  armPromptCapture,
  armContextCapture,
  isPromptCaptureArmed,
  isContextCaptureArmed,
  capturePrompt,
  captureStdout,
  __resetModelwatchForTest,
  MODELWATCH_TEXT_MAX_CHARS,
  type ModelCallEvent,
} from "../src/modelwatch";

/** A recorded attempt with only the fields a caller could not omit. */
function call(overrides: Partial<Omit<ModelCallEvent, "seq" | "at">> = {}) {
  return {
    callId: "c1",
    phase: "start" as const,
    purpose: "decision" as const,
    attempt: 1,
    requestedTool: "claude-code",
    actualTool: "claude-code",
    reach: "repo",
    ...overrides,
  };
}

/** The capacity a ring actually resolved. Private, and read through a cast on
 *  purpose: a bad `ANTGRID_MODELWATCH_CAPACITY` produces a ring that records
 *  nothing rather than one that throws, so the fallback has to be asserted
 *  directly and not inferred from behaviour that would look identical. */
function capacityOf(w: Modelwatch): number {
  return (w as unknown as { capacity: number }).capacity;
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

describe("Modelwatch ring", () => {
  it("keeps the newest calls, oldest first, and reports what it evicted", () => {
    const w = new Modelwatch(3);
    for (let i = 0; i < 5; i++) w.record(call({ callId: `c${i}` }));

    expect(w.snapshot().map((e) => e.callId)).toEqual(["c2", "c3", "c4"]);
    expect(w.buffered).toBe(3);
    expect(w.recorded).toBe(5);
    // The blind spot has to be reportable — a history that silently starts in
    // the middle reads as "no model ran before this".
    expect(w.evicted).toBe(2);
  });

  it("stamps seq and at, and honours a caller's own timestamp", () => {
    const w = new Modelwatch(4);
    w.record(call());
    w.record(call({ callId: "c2" }));
    w.record({ ...call({ callId: "c3" }), at: 1_700_000_000_000 });

    const seen = w.snapshot();
    expect(seen.map((e) => e.seq)).toEqual([1, 2, 3]);
    expect(seen[0].at).toBeGreaterThan(0);
    expect(seen[2].at).toBe(1_700_000_000_000);
  });

  it("honours a snapshot limit smaller than the ring", () => {
    const w = new Modelwatch(8);
    for (let i = 0; i < 5; i++) w.record(call({ callId: `c${i}` }));
    expect(w.snapshot(2).map((e) => e.callId)).toEqual(["c3", "c4"]);
  });

  it("delivers to subscribers and survives one that throws", () => {
    const w = new Modelwatch(4);
    const seen: string[] = [];
    w.subscribe(() => {
      throw new Error("watcher blew up");
    });
    const off = w.subscribe((e) => seen.push(e.callId));

    // The whole invariant of the feature: a watcher is an observer, and a broken
    // one must never be able to fail a model call.
    expect(() => w.record(call({ callId: "a" }))).not.toThrow();
    off();
    w.record(call({ callId: "b" }));

    expect(seen).toEqual(["a"]);
    // The throwing subscriber did not cost the ring the event either.
    expect(w.snapshot().map((e) => e.callId)).toEqual(["a", "b"]);
  });
});

describe("Modelwatch capacity override", () => {
  const KEY = "ANTGRID_MODELWATCH_CAPACITY";
  let saved: string | undefined;

  beforeEach(() => {
    saved = process.env[KEY];
  });
  afterEach(() => {
    if (saved === undefined) delete process.env[KEY];
    else process.env[KEY] = saved;
  });

  function withEnv(raw: string | undefined): Modelwatch {
    if (raw === undefined) delete process.env[KEY];
    else process.env[KEY] = raw;
    return new Modelwatch();
  }

  it("defaults to a ring sized for days of calls, not seconds of frames", () => {
    expect(capacityOf(withEnv(undefined))).toBe(2048);
  });

  it("honours a sane override, end to end", () => {
    const w = withEnv("3");
    expect(capacityOf(w)).toBe(3);
    for (let i = 0; i < 4; i++) w.record(call({ callId: `c${i}` }));
    expect(w.snapshot().map((e) => e.callId)).toEqual(["c1", "c2", "c3"]);
  });

  it("falls back rather than honouring a value that would silence the ring", () => {
    // The capacity is the modulus of every ring index, so none of these fails
    // loudly — each one produces a recorder that quietly keeps nothing.
    for (const raw of ["", " ", "lots", "12.5", "0", "-1", "1e-3", "NaN", "Infinity"]) {
      expect(capacityOf(withEnv(raw))).toBe(2048);
    }
  });

  it("clamps a value large enough to abort the bridge at import", () => {
    // `new Array(n)` throws RangeError past 2^32-1 and the process-global ring is
    // built at module scope on the spawn path, so an unclamped fat-fingered env
    // var would take the bridge down with an error naming an array length.
    const w = withEnv("99999999999");
    expect(capacityOf(w)).toBe(1_048_576);
    expect(() => w.record(call())).not.toThrow();
    expect(w.buffered).toBe(1);
  });
});

describe("Modelwatch prompt capture", () => {
  const PARTS = {
    scaffold: "Decide whether this session needs the user.",
    goal: "ship the release",
    backlogText: "the user's own words to their agent",
    context: "$ cat .env\nAPI_KEY=sk-not-a-real-key",
  };

  beforeEach(() => __resetModelwatchForTest());
  afterEach(() => __resetModelwatchForTest());

  it("records nothing until someone asks for it", () => {
    // Always-on metadata is what makes the ring affordable. Prompt text nobody
    // armed is the user's transcript kept in memory by default.
    expect(isPromptCaptureArmed()).toBe(false);
    expect(capturePrompt(PARTS)).toBeUndefined();
    expect(captureStdout("the model's answer")).toBeUndefined();
  });

  it("gives the parts we authored and reduces the ones we did not", () => {
    armPromptCapture(true, 60_000);
    const p = capturePrompt(PARTS)!;

    expect(p.scaffold).toBe(PARTS.scaffold);
    expect(p.goal).toBe(PARTS.goal);
    expect(p.backlogChars).toBe(PARTS.backlogText.length);
    expect(p.context).toEqual({
      sha256: createHash("sha256").update(PARTS.context).digest("hex"),
      chars: PARTS.context.length,
    });
    // The digest answers "was the retry given the same context" with nothing to
    // leak; the text itself is behind the second arm.
    expect(p.contextText).toBeUndefined();
    expect(JSON.stringify(p)).not.toContain("sk-not-a-real-key");
  });

  it("omits a part the caller did not supply rather than inventing one", () => {
    armPromptCapture(true, 60_000);
    const p = capturePrompt({ scaffold: "just the scaffold" })!;
    expect(p).toEqual({ scaffold: "just the scaffold" });
  });

  it("withholds the answer under the prompt arm alone", () => {
    // The decide prompt REQUIRES the judge to quote the context back
    // character-for-character, so an obedient answer contains the excerpt. If
    // stdout rode the prompt arm, arming prompts alone would put the transcript
    // in the ring through the model, past the arm that exists to withhold it.
    armPromptCapture(true, 60_000);
    expect(captureStdout(`{"evidence":"${PARTS.context}"}`)).toBeUndefined();
  });

  it("keeps stdout under both arms, so a shape rejection can be read back", () => {
    armPromptCapture(true, 60_000);
    armContextCapture(true, 60_000);
    expect(captureStdout('{"needsUser":true}')).toBe('{"needsUser":true}');
  });
});

describe("Modelwatch context capture", () => {
  const CONTEXT = "password: hunter2";

  beforeEach(() => __resetModelwatchForTest());
  afterEach(() => __resetModelwatchForTest());

  it("needs both arms, because arming one says nothing about the other", () => {
    // The context arm alone must not admit text: it is the second half of a
    // decision, not a replacement for the first.
    armContextCapture(true, 60_000);
    expect(isContextCaptureArmed()).toBe(true);
    expect(isPromptCaptureArmed()).toBe(false);
    expect(capturePrompt({ context: CONTEXT })).toBeUndefined();

    // The prompt arm alone gives the digest and the length, never the text.
    armContextCapture(false, 0);
    armPromptCapture(true, 60_000);
    expect(capturePrompt({ context: CONTEXT })!.contextText).toBeUndefined();

    armContextCapture(true, 60_000);
    expect(capturePrompt({ context: CONTEXT })!.contextText).toBe(CONTEXT);
  });

  it("truncates at the record site and counts the marker inside the cap", () => {
    armPromptCapture(true, 60_000);
    armContextCapture(true, 60_000);
    const huge = "x".repeat(50_000);

    const text = capturePrompt({ context: huge })!.contextText!;
    // The cap is what bounds the ring's memory, so a marker appended PAST it
    // would defeat the thing it reports.
    expect(text.length).toBeLessThanOrEqual(MODELWATCH_TEXT_MAX_CHARS);
    expect(text).toMatch(/…\[\+\d+ chars\]$/);
    expect(huge.startsWith(text.slice(0, 100))).toBe(true);
    // The digest and the length still describe the WHOLE excerpt — truncating
    // those would make the record disagree with the call that was actually made.
    expect(capturePrompt({ context: huge })!.context!.chars).toBe(50_000);

    const out = captureStdout(huge)!;
    expect(out.length).toBeLessThanOrEqual(MODELWATCH_TEXT_MAX_CHARS);
    expect(out).toMatch(/…\[\+\d+ chars\]$/);
  });

  it("copies text out of the string it was cut from, without rewriting it", () => {
    armPromptCapture(true, 60_000);
    armContextCapture(true, 60_000);
    // A capped field cut with `slice` is a VIEW onto its parent in JSC, so one
    // 4096-character capture off a chatty CLI's stdout keeps the whole of that
    // stdout alive for as long as the ring holds the event. The copy that closes
    // it must not be one that alters the text on the way through: an unpaired
    // surrogate is exactly what a UTF-8 round trip would turn into U+FFFD.
    const odd = "emoji 😀 then a lone surrogate \uD800 then more";
    expect(captureStdout(odd)).toBe(odd);
    expect(capturePrompt({ goal: odd })!.goal).toBe(odd);
  });
});

describe("Modelwatch arm lifetime", () => {
  beforeEach(() => __resetModelwatchForTest());
  afterEach(() => __resetModelwatchForTest());

  it("refuses an arm with no expiry", () => {
    // The dead man's switch: the only thing that ever disarms is the watcher
    // that armed it, and a watcher killed with SIGKILL sends no disarm.
    for (const ttl of [0, -1, Number.NaN, Number.POSITIVE_INFINITY]) {
      armPromptCapture(true, ttl);
      expect(isPromptCaptureArmed()).toBe(false);
      armContextCapture(true, ttl);
      expect(isContextCaptureArmed()).toBe(false);
    }
  });

  it("lapses on its own, and each arm lapses independently", async () => {
    armPromptCapture(true, 20);
    armContextCapture(true, 60_000);
    await sleep(120);

    expect(isPromptCaptureArmed()).toBe(false);
    expect(isContextCaptureArmed()).toBe(true);
    expect(capturePrompt({ scaffold: "after the window" })).toBeUndefined();
  });

  it("restarts the window on a re-arm", async () => {
    armPromptCapture(true, 20);
    armPromptCapture(true, 60_000);
    await sleep(120);
    expect(isPromptCaptureArmed()).toBe(true);
  });

  it("disarms idempotently", () => {
    armContextCapture(true, 60_000);
    armContextCapture(false, 0);
    armContextCapture(false, 0);
    expect(isContextCaptureArmed()).toBe(false);
  });
});

describe("Modelwatch arm lapse, on what was already recorded", () => {
  const SECRET = "AWS_SECRET_ACCESS_KEY=not-a-real-key";
  const GOAL = "ship the release";

  beforeEach(() => __resetModelwatchForTest());
  afterEach(() => __resetModelwatchForTest());

  /** One recorded attempt holding everything both arms admit. */
  function recordACapturedCall(): void {
    modelwatch.record(call({
      prompt: capturePrompt({ scaffold: "Decide.", goal: GOAL, context: SECRET }),
      stdout: captureStdout(`{"evidence":"${SECRET}"}`),
    }));
  }

  const ringText = () => JSON.stringify(modelwatch.snapshot());

  it("takes the text with it rather than only stopping the next capture", () => {
    armPromptCapture(true, 60_000);
    armContextCapture(true, 60_000);
    recordACapturedCall();
    expect(ringText()).toContain(SECRET);

    armPromptCapture(false, 0);

    // The ring is sized for days, so text left behind by a sixty-second window
    // outlives the arm by a week — and per the plan the snapshot is what a later
    // reader is replayed, with nothing of its own armed.
    expect(ringText()).not.toContain(SECRET);
    const [event] = modelwatch.snapshot();
    expect(event!.prompt).toBeUndefined();
    expect(event!.stdout).toBeUndefined();
    // The record still exists and is still measurable, which is the whole point
    // of a purge rather than a wipe.
    expect(event!.callId).toBe("c1");
  });

  it("purges on the TTL lapse too, not only on a disarm", async () => {
    // The lapse is the leg that matters: a watcher killed with SIGKILL sends no
    // disarm, and it is the only path a purge could be missing from.
    armPromptCapture(true, 20);
    armContextCapture(true, 20);
    recordACapturedCall();
    expect(ringText()).toContain(SECRET);

    await sleep(120);

    expect(isPromptCaptureArmed()).toBe(false);
    expect(ringText()).not.toContain(SECRET);
  });

  it("drops only what the surviving arm no longer admits", () => {
    armPromptCapture(true, 60_000);
    armContextCapture(true, 60_000);
    recordACapturedCall();

    armContextCapture(false, 0);

    const [event] = modelwatch.snapshot();
    // The prompt arm is still up, so the parts it admits stay — including the
    // digest, which is what identifies the excerpt without holding it.
    expect(event!.prompt!.goal).toBe(GOAL);
    expect(event!.prompt!.context!.sha256).toBe(
      createHash("sha256").update(SECRET).digest("hex"),
    );
    expect(event!.prompt!.contextText).toBeUndefined();
    expect(event!.stdout).toBeUndefined();
    expect(ringText()).not.toContain(SECRET);
  });
});

describe("__resetModelwatchForTest", () => {
  it("leaves no arm and no history standing for the next spec file", () => {
    armPromptCapture(true, 60_000);
    armContextCapture(true, 60_000);
    modelwatch.record(call());
    modelwatch.subscribe(() => {
      throw new Error("a subscriber the next file never registered");
    });

    __resetModelwatchForTest();

    // The suite shares one module cache, so an arm left standing here decides
    // whether the next file's calls carry prompt text — and the suite would then
    // pass or fail on file order.
    expect(isPromptCaptureArmed()).toBe(false);
    expect(isContextCaptureArmed()).toBe(false);
    expect(modelwatch.snapshot()).toEqual([]);
    expect(modelwatch.buffered).toBe(0);
    expect(modelwatch.recorded).toBe(0);
    expect(modelwatch.evicted).toBe(0);
    expect(() => modelwatch.record(call())).not.toThrow();
    __resetModelwatchForTest();
  });
});
