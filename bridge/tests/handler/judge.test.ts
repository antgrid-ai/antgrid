// bridge/tests/handler/judge.test.ts
import { describe, it, expect } from "bun:test";
import { runDecision } from "../../src/handler/judge";

const GOAL = "migrate the auth module";
const BACKLOG_TEXT = "- id=i1 [queued] run the tests";
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
    const d = await runDecision({ tool: "claude-code", goal: GOAL, backlogText: BACKLOG_TEXT, context: "C", cwd: ".", spawn });
    expect(d?.decision).toBe("continue");
    expect(calls.length).toBe(1);
  });
  it("puts the goal and the backlog in front of the judge", async () => {
    const { spawn, calls } = fakeSpawn([GOOD]);
    await runDecision({ tool: "claude-code", goal: GOAL, backlogText: BACKLOG_TEXT, context: "C", cwd: ".", spawn });
    const prompt = calls[0].join(" ");
    expect(prompt).toContain(GOAL);
    expect(prompt).toContain(BACKLOG_TEXT);
  });
  it("retries once with the validation error, then fails closed", async () => {
    const { spawn, calls } = fakeSpawn(["garbage", "still garbage"]);
    const d = await runDecision({ tool: "claude-code", goal: GOAL, backlogText: "", context: "C", cwd: ".", spawn });
    expect(d).toBeNull();
    expect(calls.length).toBe(2);
    // Retry prompt carries the error marker.
    expect(calls[1].join(" ")).toContain("was not a valid JSON object");
  });
  it("returns null for tools without a judge", async () => {
    const d = await runDecision({ tool: "gemini", goal: GOAL, backlogText: "", context: "C", cwd: "." });
    expect(d).toBeNull();
  });
  it("only forwards transcriptPath into the prompt for readonly tiers", async () => {
    const ro = fakeSpawn([GOOD]);
    await runDecision({ tool: "claude-code", goal: GOAL, backlogText: "", context: "C", transcriptPath: "/t.jsonl", cwd: ".", spawn: ro.spawn });
    expect(ro.calls[0].join(" ")).toContain("/t.jsonl");
    const tr = fakeSpawn([GOOD]);
    await runDecision({ tool: "opencode", goal: GOAL, backlogText: "", context: "C", transcriptPath: "/t.jsonl", cwd: ".", spawn: tr.spawn });
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
      tool: "claude-code", goal: GOAL, backlogText: "", context: "C",
      cwd: ".", timeoutMs: 50, spawn,
    });
    expect(d).toBeNull();
    expect(calls.length).toBe(1); // no retry leg after a timeout
  });
});

// The registry declares the override; this is the wiring that has to apply it.
describe("judge env overrides", () => {
  function envCapturingSpawn(out: string) {
    const envs: (Record<string, string> | undefined)[] = [];
    const spawn = ((_cmd: string[], opts: { env?: Record<string, string> }) => {
      envs.push(opts.env);
      return { stdout: new Response(out).body, exited: Promise.resolve(0), kill() {} };
    }) as unknown as typeof Bun.spawn;
    return { spawn, envs };
  }

  // Merged, never substituted: Bun.spawn REPLACES the environment when `env` is
  // passed, so handing it the override alone would strip PATH and the agent's
  // own credentials out from under the judge — which fails as "no judge output"
  // rather than as anything that names the environment.
  it("merges the agent's judge env over the inherited one", async () => {
    const { spawn, envs } = envCapturingSpawn(GOOD);
    await runDecision({ tool: "opencode", goal: GOAL, backlogText: "", context: "C", cwd: ".", spawn });
    expect(envs[0]?.OPENCODE_DB).toBe(":memory:");
    const inherited = Object.keys(process.env)[0];
    expect(envs[0]?.[inherited]).toBe(process.env[inherited]);
  });

  // An agent that declares none must get NO env object — passing an empty one
  // would be a full environment wipe, not a no-op.
  it("passes no env at all for an agent that declares none", async () => {
    const { spawn, envs } = envCapturingSpawn(GOOD);
    await runDecision({ tool: "claude-code", goal: GOAL, backlogText: "", context: "C", cwd: ".", spawn });
    expect(envs[0]).toBeUndefined();
  });
});
