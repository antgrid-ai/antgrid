// bridge/tests/handler/judge.test.ts
import { describe, it, expect } from "bun:test";
import { runDecision, runExtraction } from "../../src/handler/judge";

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
    let timedOut = 0;
    const d = await runDecision({
      tool: "claude-code", goal: GOAL, backlogText: BACKLOG_TEXT, context: "C", cwd: ".", spawn,
      onTimeout: () => { timedOut += 1; },
    });
    expect(d?.decision).toBe("continue");
    expect(calls.length).toBe(1);
    expect(timedOut).toBe(0);
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
    let timedOut = 0;
    const d = await runDecision({
      tool: "claude-code", goal: GOAL, backlogText: "", context: "C",
      cwd: ".", timeoutMs: 50, spawn, onTimeout: () => { timedOut += 1; },
    });
    expect(d).toBeNull();
    expect(calls.length).toBe(1); // no retry leg after a timeout
    // The null above is the same value a failed spawn returns, so this hook is the
    // only thing that can tell the caller which leg spent the whole budget.
    expect(timedOut).toBe(1);
  });

  // The shape rules live in the caller's gate, so a judge that breaks one has
  // produced perfectly valid JSON. Re-asking is the only thing that lets it
  // learn the rule the prompt now states.
  it("re-asks once when a parsed decision fails the caller's shape rule", async () => {
    const bad = JSON.stringify({
      decision: "handle", confidence: 0.9, reason: "r",
      action: { kind: "slash_command", value: "/etc/hosts" },
    });
    const { spawn, calls } = fakeSpawn([bad, GOOD]);
    const d = await runDecision({
      tool: "claude-code", goal: GOAL, backlogText: "", context: "C", cwd: ".", spawn,
      retryIfShape: (x) => x.action?.value === "/etc/hosts" ? "slash command value is not a simple verb" : null,
    });
    expect(calls.length).toBe(2);
    expect(d?.decision).toBe("continue");
    expect(calls[1].join(" ")).toContain("valid JSON, but the harness refused");
    expect(calls[1].join(" ")).toContain("slash command value is not a simple verb");
  });

  // Never null: null reads as a judge outage upstream, which parks the session
  // instead of escalating the decision with its own text attached.
  it("spends exactly one shape retry and returns the second answer anyway", async () => {
    const bad = JSON.stringify({
      decision: "handle", confidence: 0.9, reason: "r",
      action: { kind: "slash_command", value: "/etc/hosts" },
    });
    const { spawn, calls } = fakeSpawn([bad, bad]);
    const d = await runDecision({
      tool: "claude-code", goal: GOAL, backlogText: "", context: "C", cwd: ".", spawn,
      retryIfShape: () => "still not a simple verb",
    });
    expect(calls.length).toBe(2);
    expect(d).not.toBeNull();
  });

  // The shape hook second-guesses a value that PARSED, so a first attempt that
  // produced none never reaches it and the retry it earns is the JSON one. The
  // second attempt is final either way, so nothing consults the hook again.
  it("does not consult retryIfShape for output that never parsed", async () => {
    const seen: string[] = [];
    const { spawn, calls } = fakeSpawn(["garbage", GOOD]);
    const d = await runDecision({
      tool: "claude-code", goal: GOAL, backlogText: "", context: "C", cwd: ".", spawn,
      retryIfShape: (x) => { seen.push(x.decision); return null; },
    });
    expect(seen).toEqual([]);
    expect(d?.decision).toBe("continue");
    expect(calls[1].join(" ")).toContain("was not a valid JSON object");
  });

  it("passes the supervised agent and the catalog into the prompt", async () => {
    const { spawn, calls } = fakeSpawn([GOOD]);
    await runDecision({
      tool: "claude-code", goal: GOAL, backlogText: "", context: "C", cwd: ".", spawn,
      agentTool: "codex", commands: [{ id: "skill:x", name: "x" }],
    });
    expect(calls[0].join(" ")).toContain("codex");
    expect(calls[0].join(" ")).toContain("/x");
  });
});

// The registry declares the override; this is the wiring that has to apply it.
// The judge is the one caller that MUST run in the working tree: reading it is
// the work. A naming spawn deliberately runs in a throwaway directory instead
// (headlessScratchCwd), and nothing but these assertions stops that from being
// reused here — where it would leave the judge reasoning about an empty dir and
// still returning a confident verdict.
describe("judge cwd", () => {
  function cwdCapturingSpawn(out: string) {
    const cwds: (string | undefined)[] = [];
    const spawn = ((_cmd: string[], opts: { cwd?: string }) => {
      cwds.push(opts.cwd);
      return { stdout: new Response(out).body, exited: Promise.resolve(0), kill() {} };
    }) as unknown as typeof Bun.spawn;
    return { spawn, cwds };
  }

  it("spawns a decision in the cwd it was handed", async () => {
    const { spawn, cwds } = cwdCapturingSpawn(GOOD);
    await runDecision({
      tool: "claude-code", goal: GOAL, backlogText: "", context: "C",
      cwd: "/checkout/here", spawn,
    });
    expect(cwds[0]).toBe("/checkout/here");
  });

  it("spawns an extraction in the cwd it was handed", async () => {
    const { spawn, cwds } = cwdCapturingSpawn('{"items":[]}');
    await runExtraction({ tool: "claude-code", text: "do a thing", cwd: "/checkout/here", spawn });
    expect(cwds[0]).toBe("/checkout/here");
  });
});

describe("judge env overrides", () => {
  function envCapturingSpawn(out: string) {
    const envs: (Record<string, string> | undefined)[] = [];
    const spawn = ((_cmd: string[], opts: { env?: Record<string, string> }) => {
      envs.push(opts.env);
      return { stdout: new Response(out).body, exited: Promise.resolve(0), kill() {} };
    }) as unknown as typeof Bun.spawn;
    return { spawn, envs };
  }

  // A key the test owns, rather than whichever one `process.env` happens to
  // enumerate first: the runner DELETES keys from the spawn env
  // (ANTGRID_TERMINAL_ID always, the TLS/proxy overrides on demand), so probing
  // an arbitrary inherited key can pick one of those and fail a correct
  // implementation depending on how the box is configured.
  const MARKER = "ANTGRID_TEST_INHERITED_MARKER";
  async function withInheritedMarker(run: () => Promise<void>): Promise<void> {
    const prior = process.env[MARKER];
    process.env[MARKER] = "kept";
    try { await run(); } finally {
      if (prior === undefined) delete process.env[MARKER];
      else process.env[MARKER] = prior;
    }
  }

  // Merged, never substituted: Bun.spawn REPLACES the environment when `env` is
  // passed, so handing it the override alone would strip PATH and the agent's
  // own credentials out from under the judge — which fails as "no judge output"
  // rather than as anything that names the environment.
  it("merges the agent's judge env over the inherited one", async () => {
    const { spawn, envs } = envCapturingSpawn(GOOD);
    await withInheritedMarker(async () => {
      await runDecision({ tool: "opencode", goal: GOAL, backlogText: "", context: "C", cwd: ".", spawn });
    });
    expect(envs[0]?.OPENCODE_DB).toBe(":memory:");
    expect(envs[0]?.[MARKER]).toBe("kept");
  });

  // An agent that declares none still gets the FULL inherited environment, never
  // an empty object: Bun.spawn substitutes rather than merges, so an empty env is
  // a wipe that takes PATH and the agent's credentials with it.
  it("inherits the whole environment for an agent that declares none", async () => {
    const { spawn, envs } = envCapturingSpawn(GOOD);
    await withInheritedMarker(async () => {
      await runDecision({ tool: "claude-code", goal: GOAL, backlogText: "", context: "C", cwd: ".", spawn });
    });
    expect(envs[0]?.[MARKER]).toBe("kept");
  });

  // Stripped by the shared runner for every headless spawn, whatever the agent
  // declares: agy and opencode install their Antgrid hooks GLOBALLY, and this is
  // the only thing keeping a supervisor pass from posting session/notify traffic
  // for a conversation that does not exist.
  it("strips ANTGRID_TERMINAL_ID from every judge spawn", async () => {
    const prior = process.env.ANTGRID_TERMINAL_ID;
    process.env.ANTGRID_TERMINAL_ID = "term-1";
    try {
      const { spawn, envs } = envCapturingSpawn(GOOD);
      await runDecision({ tool: "claude-code", goal: GOAL, backlogText: "", context: "C", cwd: ".", spawn });
      expect(envs[0]).toBeDefined();
      expect(envs[0]?.ANTGRID_TERMINAL_ID).toBeUndefined();
    } finally {
      if (prior === undefined) delete process.env.ANTGRID_TERMINAL_ID;
      else process.env.ANTGRID_TERMINAL_ID = prior;
    }
  });
});
