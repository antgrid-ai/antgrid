// bridge/tests/handler/judge.test.ts
import { describe, it, expect } from "bun:test";
import { runDecision, runPlan, PLAN_TIMEOUT_MS } from "../../src/handler/judge";

const BRIEF = {
  taskSummary: "t", willHandle: ["a"], wakeFor: ["b"], thenItems: [] as string[],
};
const GOOD = JSON.stringify({ decision: "continue", confidence: 0.9, reason: "ok" });

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

describe("runDecision", () => {
  it("parses a valid decision on first attempt", async () => {
    const { spawn, calls } = fakeSpawn([GOOD]);
    const d = await runDecision({ tool: "claude-code", brief: BRIEF, ledgerText: "", context: "C", cwd: ".", spawn });
    expect(d?.decision).toBe("continue");
    expect(calls.length).toBe(1);
  });
  it("retries once with the validation error, then fails closed", async () => {
    const { spawn, calls } = fakeSpawn(["garbage", "still garbage"]);
    const d = await runDecision({ tool: "claude-code", brief: BRIEF, ledgerText: "", context: "C", cwd: ".", spawn });
    expect(d).toBeNull();
    expect(calls.length).toBe(2);
    // Retry prompt carries the error marker.
    expect(calls[1].join(" ")).toContain("was not a valid JSON object");
  });
  it("returns null for tools without a judge", async () => {
    const d = await runDecision({ tool: "gemini", brief: BRIEF, ledgerText: "", context: "C", cwd: "." });
    expect(d).toBeNull();
  });
  it("only forwards transcriptPath into the prompt for readonly tiers", async () => {
    const ro = fakeSpawn([GOOD]);
    await runDecision({ tool: "claude-code", brief: BRIEF, ledgerText: "", context: "C", transcriptPath: "/t.jsonl", cwd: ".", spawn: ro.spawn });
    expect(ro.calls[0].join(" ")).toContain("/t.jsonl");
    const tr = fakeSpawn([GOOD]);
    await runDecision({ tool: "opencode", brief: BRIEF, ledgerText: "", context: "C", transcriptPath: "/t.jsonl", cwd: ".", spawn: tr.spawn });
    expect(tr.calls[0].join(" ")).not.toContain("/t.jsonl");
  });

  it("fails closed on timeout WITHOUT retrying", async () => {
    // A proc whose stdout only closes when kill() fires (i.e. a hung judge).
    const calls: string[][] = [];
    const spawn = ((cmd: string[]) => {
      calls.push(cmd);
      let close!: () => void;
      let resolveExit!: (code: number) => void;
      return {
        stdout: new ReadableStream({ start(c) { close = () => c.close(); } }),
        exited: new Promise<number>((r) => { resolveExit = r; }),
        kill() { close(); resolveExit(1); },
      };
    }) as unknown as typeof Bun.spawn;
    const d = await runDecision({
      tool: "claude-code", brief: BRIEF, ledgerText: "", context: "C",
      cwd: ".", timeoutMs: 50, spawn,
    });
    expect(d).toBeNull();
    expect(calls.length).toBe(1); // no retry leg after a timeout
  });
});

describe("runPlan", () => {
  it("parses a valid brief and fails closed after one retry", async () => {
    const brief = JSON.stringify({ taskSummary: "s", willHandle: ["w"], wakeFor: ["k"], thenItems: [] });
    const ok = fakeSpawn([brief]);
    expect((await runPlan({ tool: "claude-code", context: "C", cwd: ".", spawn: ok.spawn }))?.taskSummary).toBe("s");
    const bad = fakeSpawn(["nope", "nope"]);
    expect(await runPlan({ tool: "claude-code", context: "C", cwd: ".", spawn: bad.spawn })).toBeNull();
    expect(bad.calls.length).toBe(2);
  });

  // A real claude plan call measures ~25s and codex ~17s, on a short context.
  // The budget has to clear that with room, and the app's _kPlanTimeout backstop
  // (handler_briefing_sheet.dart) has to stay above it or the sheet gives up
  // before the bridge's own fallback lands.
  it("budgets a plan call well past a real judge's measured latency", () => {
    expect(PLAN_TIMEOUT_MS).toBeGreaterThanOrEqual(40_000);
    expect(PLAN_TIMEOUT_MS).toBeLessThan(50_000); // app backstop is 50s
  });
});
