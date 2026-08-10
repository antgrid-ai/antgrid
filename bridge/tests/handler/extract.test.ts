// bridge/tests/handler/extract.test.ts
import { describe, it, expect } from "bun:test";
import {
  ExtractedItemSchema,
  MAX_ITEM_CHARS,
  buildExtractPrompt,
  parseItemsFromOutput,
} from "../../src/handler/extract";
import type { ExtractedItem } from "../../src/handler/extract";
import { runExtraction } from "../../src/handler/judge";

function output(items: unknown[]): string {
  return JSON.stringify({ items });
}

// Fake spawn: yields queued stdout strings, records invocations.
function fakeSpawn(outputs: string[]) {
  const calls: string[][] = [];
  const spawn = ((cmd: string[]) => {
    calls.push(cmd);
    const out = outputs[Math.min(calls.length - 1, outputs.length - 1)];
    return {
      stdout: new Response(out).body,
      exited: Promise.resolve(0),
      kill() {},
    };
  }) as unknown as typeof Bun.spawn;
  return { spawn, calls };
}

describe("§3.3 no ordering word, no dependency", () => {
  // The plan's named fixture. A spurious dependency here silently blocks work the
  // user wanted done; a missing one only means Handler does not wait.
  it('extracts "update the docs and run the tests" as two independent items', () => {
    const { items, error } = parseItemsFromOutput(output([
      { ref: "docs", text: "update the docs" },
      { ref: "tests", text: "run the tests" },
    ]));

    expect(error).toBeUndefined();
    expect(items).toHaveLength(2);
    expect(items!.map((i) => i.text)).toEqual(["update the docs", "run the tests"]);
    expect(items!.every((i) => i.dependsOn === undefined)).toBe(true);
  });

  it('extracts "run the tests after you update the docs" with a dependency pointing at the docs item', () => {
    const { items } = parseItemsFromOutput(output([
      { ref: "docs", text: "update the docs" },
      { ref: "tests", text: "run the tests", dependsOn: ["docs"] },
    ]));

    const tests = items!.find((i) => i.text === "run the tests")!;
    const docs = items!.find((i) => i.text === "update the docs")!;
    expect(tests.dependsOn).toEqual(["docs"]);
    expect(docs.dependsOn).toBeUndefined();
  });

  it("states the ordering-word rule in the prompt, with both worked examples", () => {
    const prompt = buildExtractPrompt("whatever the user typed");
    expect(prompt).toContain('"and" is NOT an ordering word');
    expect(prompt).toContain("update the docs and run the tests");
    expect(prompt).toContain("run the tests after you update the docs");
    expect(prompt).toContain("the default is NONE");
  });

  it("tells the extractor to split the instruction, never to plan the steps", () => {
    const prompt = buildExtractPrompt("run the tests");
    expect(prompt).toContain("NEVER break an item into the steps that achieve it");
    expect(prompt).toContain('"Run the tests" is ONE item');
  });

  it("closes by demanding a single JSON object", () => {
    expect(buildExtractPrompt("x")).toContain("Respond with ONLY a single JSON object");
  });
});

describe("§3.1 the instruction text is the whole input", () => {
  it("puts the user's text in the prompt verbatim", () => {
    expect(buildExtractPrompt("get the tests passing then open a PR"))
      .toContain("get the tests passing then open a PR");
  });

  // The text is untrusted user input and the prompt is a fixed budget: an
  // instruction long enough to crowd out the rules would leave them unconstrained.
  it("truncates an over-long instruction", () => {
    const tail = "TAIL_MARKER_AFTER_THE_CAP";
    const prompt = buildExtractPrompt("a".repeat(4_000) + tail);
    expect(prompt).not.toContain(tail);
    expect(prompt).toContain("Respond with ONLY a single JSON object");
    expect(prompt.length).toBeLessThan(4_000 + 4_000);
  });

  // Bounds the cap from BELOW, which the truncation test above cannot: a marker
  // the static prompt could also contain would make this pass for any cap, and
  // a shortened one would then silently truncate every real instruction.
  it("keeps an instruction that exactly fills the budget intact", () => {
    const marker = "ZQ_TAIL_MARKER";
    const text = "b".repeat(4_000 - marker.length) + marker;
    expect(buildExtractPrompt("")).not.toContain(marker);
    expect(buildExtractPrompt(text)).toContain(marker);
  });
});

describe("parseItemsFromOutput fails closed, never throws", () => {
  it("reports prose with no JSON object", () => {
    const r = parseItemsFromOutput("Sure! I'd split that into a couple of things.");
    expect(r.items).toBeNull();
    expect(r.error).toBeTruthy();
  });

  it("reports truncated JSON", () => {
    const r = parseItemsFromOutput('{"items":[{"ref":"a","text":"update the docs"');
    expect(r.items).toBeNull();
    expect(r.error).toBeTruthy();
  });

  it("reports a JSON object of the wrong shape", () => {
    for (const bad of [
      '{"decision":"continue","confidence":0.9,"reason":"ok"}',
      '{"items":"update the docs"}',
      '{"items":[{"id":"i1","text":"update the docs","status":"queued"}]}',
      '{"items":[{"ref":"a","text":"update the docs","dependsOn":"b"}]}',
      '{"items":[{"ref":"","text":"update the docs"}]}',
    ]) {
      const r = parseItemsFromOutput(bad);
      expect(r.items).toBeNull();
      expect(r.error).toBeTruthy();
    }
  });

  // An empty backlog is never terminal, so a session armed on one could never wrap
  // up; the caller falls back to the raw instruction as a single item instead.
  it("reports an empty item list rather than returning it", () => {
    const r = parseItemsFromOutput('{"items":[]}');
    expect(r.items).toBeNull();
    expect(r.error).toBeTruthy();
  });

  it("finds the object when the model wraps it in prose", () => {
    const r = parseItemsFromOutput(`Here you go:\n${output([{ ref: "a", text: "run the tests" }])}\nAnything else?`);
    expect(r.items).toHaveLength(1);
  });

  it("keeps a condition without turning it into a dependency", () => {
    const { items } = parseItemsFromOutput(output([
      { ref: "issue", text: "file an issue", condition: "the build is red" },
    ]));
    expect(items![0]!.condition).toBe("the build is red");
    expect(items![0]!.dependsOn).toBeUndefined();
  });
});

describe("the extractor never mints ids", () => {
  it("has no id, status or createdAt in its schema", () => {
    const parsed = ExtractedItemSchema.safeParse({
      ref: "a", text: "run the tests", id: "i1", status: "queued", createdAt: 1,
    });
    expect(parsed.success).toBe(true);
    // Zod strips what the schema does not declare, so an id the extractor tried to
    // set cannot reach the engine and collide with an item already in the backlog.
    expect(parsed.data as object).toEqual({ ref: "a", text: "run the tests" });
  });

  it("drops an id the model attached to an item in its output", () => {
    const { items } = parseItemsFromOutput(output([
      { ref: "a", text: "run the tests", id: "i1", status: "done" },
    ]));
    expect(items![0]).toEqual({ ref: "a", text: "run the tests" } as ExtractedItem);
  });
});

describe("dependsOn is resolved against this batch only", () => {
  // A dangling id reads as unsatisfied in nextActionable, so an item carrying one
  // is queued, undrivable and non-terminal forever.
  it("drops a dependsOn entry naming a ref that is not in the batch", () => {
    const { items } = parseItemsFromOutput(output([
      { ref: "docs", text: "update the docs" },
      { ref: "pr", text: "open a PR", dependsOn: ["docs", "deploy"] },
    ]));
    expect(items![1]!.dependsOn).toEqual(["docs"]);
  });

  it("omits dependsOn entirely when every entry was dangling", () => {
    const { items } = parseItemsFromOutput(output([
      { ref: "pr", text: "open a PR", dependsOn: ["ghost"] },
    ]));
    expect(items![0]!.dependsOn).toBeUndefined();
  });

  it("drops a self-reference", () => {
    const { items } = parseItemsFromOutput(output([
      { ref: "pr", text: "open a PR", dependsOn: ["pr"] },
    ]));
    expect(items![0]!.dependsOn).toBeUndefined();
  });

  // Refs are labels, not identifiers: a repeated one is a lazy model, not two
  // copies of one item, so both items survive and the engine mints each its own id.
  it("keeps both items when a ref is repeated", () => {
    const { items } = parseItemsFromOutput(output([
      { ref: "x", text: "update the docs" },
      { ref: "x", text: "run the tests" },
    ]));
    expect(items!.map((i) => i.text)).toEqual(["update the docs", "run the tests"]);
  });
});

describe("the item cap protects the decide prompt's context budget", () => {
  it("truncates over-cap output instead of rejecting the batch", () => {
    const many = Array.from({ length: 45 }, (_, n) => ({ ref: `r${n}`, text: `item ${n}` }));
    const { items, error } = parseItemsFromOutput(output(many));
    expect(error).toBeUndefined();
    expect(items).toHaveLength(20);
    expect(items![0]!.text).toBe("item 0");
    expect(items![19]!.text).toBe("item 19");
  });

  // Truncation must not leave a survivor pointing at an item that was dropped.
  it("drops a surviving item's dependency on a truncated one", () => {
    const many = Array.from({ length: 25 }, (_, n) => ({ ref: `r${n}`, text: `item ${n}` }));
    many[0] = { ref: "r0", text: "item 0", dependsOn: ["r24"] } as (typeof many)[number];
    const { items } = parseItemsFromOutput(output(many));
    expect(items![0]!.dependsOn).toBeUndefined();
  });

  it("states the cap in the prompt as well", () => {
    expect(buildExtractPrompt("x")).toContain("at most 20 items");
  });
});

// The item cap bounds how many items reach the decide prompt; this bounds how
// big each one is. Without it a model echoing its whole input across the batch
// puts ~80,000 chars in front of a judge whose transcript budget is 12,000.
describe("an item is a line, not a document", () => {
  it("rejects an item whose text is over the per-item cap", () => {
    const r = parseItemsFromOutput(output([{ ref: "a", text: "x".repeat(MAX_ITEM_CHARS + 1) }]));
    expect(r.items).toBeNull();
    expect(r.error).toBeTruthy();
  });

  it("rejects an over-long condition too", () => {
    const r = parseItemsFromOutput(output([
      { ref: "a", text: "file an issue", condition: "y".repeat(MAX_ITEM_CHARS + 1) },
    ]));
    expect(r.items).toBeNull();
    expect(r.error).toBeTruthy();
  });

  it("keeps an item sitting exactly on the cap", () => {
    const text = "x".repeat(MAX_ITEM_CHARS);
    const { items } = parseItemsFromOutput(output([{ ref: "a", text }]));
    expect(items![0]!.text).toBe(text);
  });

  it("states the length rule in the prompt, so the retry leg can be obeyed", () => {
    expect(buildExtractPrompt("x")).toContain(`under ${MAX_ITEM_CHARS} characters`);
  });
});

describe("runExtraction", () => {
  const GOOD = output([
    { ref: "docs", text: "update the docs" },
    { ref: "tests", text: "run the tests" },
  ]);

  it("parses items on the first attempt", async () => {
    const { spawn, calls } = fakeSpawn([GOOD]);
    const items = await runExtraction({ tool: "claude-code", text: "update the docs and run the tests", cwd: ".", spawn });
    expect(items?.map((i) => i.ref)).toEqual(["docs", "tests"]);
    expect(calls.length).toBe(1);
  });

  it("puts the instruction text in front of the judge", async () => {
    const { spawn, calls } = fakeSpawn([GOOD]);
    await runExtraction({ tool: "claude-code", text: "update the docs and run the tests", cwd: ".", spawn });
    expect(calls[0]!.join(" ")).toContain("update the docs and run the tests");
  });

  // §3.1: the input is the user's words and nothing else. A transcript path here
  // would reintroduce the context tier Phase 2 deleted.
  it("never passes a transcript path", async () => {
    const { spawn, calls } = fakeSpawn([GOOD]);
    await runExtraction({ tool: "claude-code", text: "run the tests", cwd: ".", spawn });
    expect(calls[0]!.join(" ")).not.toContain(".jsonl");
    expect(calls[0]!.join(" ")).not.toContain("transcript");
  });

  it("retries once with the validation error, then fails closed", async () => {
    const { spawn, calls } = fakeSpawn(["garbage", "still garbage"]);
    const items = await runExtraction({ tool: "claude-code", text: "run the tests", cwd: ".", spawn });
    expect(items).toBeNull();
    expect(calls.length).toBe(2);
    expect(calls[1]!.join(" ")).toContain("was not a valid JSON object");
  });

  // No verified headless judge for the tool means no extraction; the caller arms on
  // the raw instruction as a single item rather than failing.
  it("returns null for tools without a judge, without spawning", async () => {
    const { spawn, calls } = fakeSpawn([GOOD]);
    // kilo is a registry agent whose spec declares no judge — an unknown tool
    // would exercise the missing-spec branch instead, and stop covering this one
    // the day that name gains a spec.
    const items = await runExtraction({ tool: "kilo", text: "run the tests", cwd: ".", spawn });
    expect(items).toBeNull();
    expect(calls.length).toBe(0);
  });
});
