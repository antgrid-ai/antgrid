import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  buildTitleContext, generateTitleFromContext, parseTitleFromOutput,
} from "../src/agents/title-generate";
import { handoffPrompt } from "../src/handoff/handoff-prompt";

function tmp() { return mkdtempSync(join(tmpdir(), "ab-tg-")); }

/**
 * Stands in for Bun.spawn: records the argv AND the options it was handed,
 * replays `stdout`, and exits with `exitCode` (default 0).
 *
 * The options are captured, not dropped, because two of `titleCmd`'s
 * invariants live only there — the per-agent `env` that keeps a naming run out
 * of the user's real session store, and the ANTGRID_TERMINAL_ID strip that
 * keeps it from firing the globally-installed hooks. Both are invisible in a
 * passing test unless something asserts on the spawn options.
 *
 * With `hang`, `exited` settles only on kill() — mirroring a real process that
 * outlives its budget, so the timeout path is what ends the call.
 */
function fakeSpawn(
  stdout: string, opts: { hang?: boolean; exitCode?: number } = {},
) {
  const calls: string[][] = [];
  const options: Array<Record<string, any>> = [];
  const spawn = ((cmd: string[], o?: Record<string, any>) => {
    calls.push(cmd);
    options.push(o ?? {});
    let onKill: (() => void) | undefined;
    return {
      stdout: new Response(stdout).body,
      exited: opts.hang
        ? new Promise<number>((res) => { onKill = () => res(143); })
        : Promise.resolve(opts.exitCode ?? 0),
      kill() { onKill?.(); },
    };
  }) as unknown as typeof Bun.spawn;
  return { spawn, calls, options };
}

/**
 * The two halves composed exactly as agent-core composes them. They ship apart
 * so the one-shot-per-session gate can sit between them, and every case below is
 * about the pair rather than either one — so the seam is restated here rather
 * than duplicated into each test.
 */
async function generateSessionTitle(opts: {
  tool: string;
  cwd: string;
  transcriptPath?: string;
  fallbackContext?: string;
  timeoutMs?: number;
  spawn?: typeof Bun.spawn;
  installedTools?: string[];
}): Promise<string | null> {
  const context = await buildTitleContext(opts);
  if (!context) return null;
  const result = await generateTitleFromContext(context, opts);
  return result.ok ? result.title : null;
}

describe("parseTitleFromOutput", () => {
  test("takes the last non-empty line, past CLI startup chatter", () => {
    expect(parseTitleFromOutput("Loading model...\nauth ok\n\nAdd retry to uploader\n"))
      .toBe("Add retry to uploader");
  });

  test("strips quotes, backticks, markdown emphasis and a Title: label", () => {
    expect(parseTitleFromOutput('"Fix the login bug"')).toBe("Fix the login bug");
    expect(parseTitleFromOutput("`Fix the login bug`")).toBe("Fix the login bug");
    expect(parseTitleFromOutput("**Fix the login bug**")).toBe("Fix the login bug");
    expect(parseTitleFromOutput("Title: Fix the login bug")).toBe("Fix the login bug");
    expect(parseTitleFromOutput("Fix the login bug.")).toBe("Fix the login bug");
  });

  // Rejecting beats truncating: the session already holds the user's first
  // message, which reads better than half a sentence.
  test("rejects a rambling answer rather than truncating it", () => {
    const prose = "Sure! Here is a title that describes what this session is all about in detail";
    expect(parseTitleFromOutput(prose)).toBeNull();
  });

  test("empty or whitespace-only output → null", () => {
    expect(parseTitleFromOutput("")).toBeNull();
    expect(parseTitleFromOutput("   \n\n  ")).toBeNull();
  });
});

describe("generateSessionTitle", () => {
  // The other half of the judge's cwd invariant (see tests/handler/judge.test.ts):
  // a naming spawn must NOT run in the session's tree. Everything it needs is in
  // the prompt, and the agents whose resume picker is scoped by directory would
  // otherwise file it where the user's own --continue finds it.
  test("spawns in a throwaway directory, never the caller's cwd", async () => {
    const { spawn, options } = fakeSpawn("Add retry to uploader");
    const callerCwd = tmp();
    await generateSessionTitle({
      tool: "claude-code", cwd: callerCwd, fallbackContext: "do a thing", spawn,
    });
    expect(options[0]?.cwd).toBeDefined();
    expect(options[0]?.cwd).not.toBe(callerCwd);
  });

  test("builds the prompt from the transcript and returns the parsed title", async () => {
    const d = tmp(); const p = join(d, "t.jsonl");
    writeFileSync(p,
      `{"type":"user","message":{"content":"add a retry to the uploader"}}\n` +
      `{"type":"assistant","message":{"content":[{"type":"text","text":"I'll add exponential backoff."}]}}\n`);
    const { spawn, calls } = fakeSpawn("Add upload retry backoff\n");
    const title = await generateSessionTitle({
      tool: "claude-code", cwd: d, transcriptPath: p, spawn,
    });
    expect(title).toBe("Add upload retry backoff");
    expect(calls).toHaveLength(1);
    // The conversation is inlined, so the judge needs no tool access and gets
    // no transcript path to follow.
    const prompt = calls[0]!.join(" ");
    expect(prompt).toContain("add a retry to the uploader");
    expect(prompt).not.toContain(p);
  });

  test("falls back to the caller's context when no transcript is readable", async () => {
    const d = tmp();
    const { spawn, calls } = fakeSpawn("Rename greeting text\n");
    const title = await generateSessionTitle({
      tool: "claude-code", cwd: d, fallbackContext: "rename the greeting in README", spawn,
    });
    expect(title).toBe("Rename greeting text");
    expect(calls[0]!.join(" ")).toContain("rename the greeting in README");
  });

  test("no context at all → null, without spawning", async () => {
    const { spawn, calls } = fakeSpawn("Something\n");
    expect(await generateSessionTitle({ tool: "claude-code", cwd: tmp(), spawn })).toBeNull();
    expect(calls).toHaveLength(0);
  });

  describe("a handoff target's transcript", () => {
    function transcript(dir: string, ...lines: object[]): string {
      const p = join(dir, "t.jsonl");
      writeFileSync(p, lines.map((line) => `${JSON.stringify(line)}\n`).join(""));
      return p;
    }
    const opening = (dir: string) => ({
      type: "user",
      message: { content: handoffPrompt({ sourceLabel: "Codex", excerptPath: join(dir, "excerpt.md"), rawPath: join(dir, "rollout.jsonl") }) },
    });

    test("is named from the work, never from Antgrid's handoff prompt", async () => {
      const d = tmp();
      const p = transcript(d, opening(d),
        { type: "assistant", message: { content: [{ type: "text", text: "Picking the uploader retry back up." }] } });
      const { spawn, calls } = fakeSpawn("Add upload retry\n");
      expect(await generateSessionTitle({ tool: "claude-code", cwd: d, transcriptPath: p, spawn })).toBe("Add upload retry");
      const sent = calls[0]!.join(" ");
      expect(sent).toContain("Picking the uploader retry back up.");
      expect(sent).not.toContain("handed off");
    });

    test("holding only the handoff prompt, has nothing to name yet", async () => {
      const d = tmp();
      const { spawn, calls } = fakeSpawn("Something\n");
      expect(await generateSessionTitle({ tool: "claude-code", cwd: d, transcriptPath: transcript(d, opening(d)), spawn })).toBeNull();
      expect(calls).toHaveLength(0);
    });
  });

  // kimi carries no headless entry — nobody has run its headless argv —
  // so its sessions are named by whichever installed agent has one, rather than
  // being the only ones left echoing the opening prompt.
  test("an agent with no titleCmd borrows an installed one", async () => {
    const { spawn, calls } = fakeSpawn("Something useful\n");
    expect(await generateSessionTitle({
      tool: "kimi", cwd: tmp(), fallbackContext: "do a thing", spawn,
      installedTools: ["claude-code"],
    })).toBe("Something useful");
    expect(calls).toHaveLength(1);
    expect(calls[0]![0]).toBe("claude");
  });

  test("no installed agent can name it → null, without spawning", async () => {
    const { spawn, calls } = fakeSpawn("Something\n");
    expect(await generateSessionTitle({
      tool: "kimi", cwd: tmp(), fallbackContext: "do a thing", spawn,
      installedTools: [],
    })).toBeNull();
    expect(calls).toHaveLength(0);
  });

  // Borrowing is scoped to agents we know: a tool that is not a registry key is
  // not a session we can describe.
  test("unknown tool → null, without spawning", async () => {
    const { spawn, calls } = fakeSpawn("Something\n");
    expect(await generateSessionTitle({
      tool: "not-an-agent", cwd: tmp(), fallbackContext: "x", spawn,
      installedTools: ["claude-code"],
    })).toBeNull();
    expect(calls).toHaveLength(0);
  });

  // These CLIs print their refusals to stdout, short enough to clear every one
  // of parseTitleFromOutput's checks. A `self`-ranked error string outranks the
  // first-message re-read and the attempt is never repeated, so the wrong name
  // would be permanent.
  test("a non-zero exit yields null, however title-shaped the stdout is", async () => {
    const { spawn } = fakeSpawn("Invalid API key\n", { exitCode: 1 });
    expect(await generateSessionTitle({
      tool: "claude-code", cwd: tmp(), fallbackContext: "do a thing", spawn,
    })).toBeNull();
  });

  // Both are declared on AgentSpec.titleCmd and neither has any other witness:
  // OPENCODE_DB keeps the run out of the session store the transcript reader
  // also READS, and the strip keeps it from firing the globally-installed
  // opencode/agy hooks for a conversation that does not exist.
  test("the spawn carries the agent's env and never ANTGRID_TERMINAL_ID", async () => {
    process.env.ANTGRID_TERMINAL_ID = "term-1";
    try {
      const { spawn, options } = fakeSpawn("Name the thing\n");
      expect(await generateSessionTitle({
        tool: "opencode", cwd: tmp(), fallbackContext: "do a thing", spawn,
      })).toBe("Name the thing");
      const env = options.at(-1)!.env as Record<string, string>;
      expect(env.OPENCODE_DB).toBe(":memory:");
      expect("ANTGRID_TERMINAL_ID" in env).toBe(false);
    } finally {
      delete process.env.ANTGRID_TERMINAL_ID;
    }
  });

  test("a timeout yields null rather than a half-written title", async () => {
    const { spawn } = fakeSpawn("Add upload retry\n", { hang: true });
    const title = await generateSessionTitle({
      tool: "claude-code", cwd: tmp(), fallbackContext: "do a thing", spawn, timeoutMs: 10,
    });
    expect(title).toBeNull();
  });

  test("a spawn that throws is swallowed", async () => {
    const spawn = (() => { throw new Error("ENOENT"); }) as unknown as typeof Bun.spawn;
    expect(await generateSessionTitle({
      tool: "claude-code", cwd: tmp(), fallbackContext: "do a thing", spawn,
    })).toBeNull();
  });
});

// AgentSpec.cheapNamingModel (agents/types.ts): the model a naming call defaults
// to per SERVING agent, not per requested one. Pinned against the real registry
// entries rather than a fixture — the position `model` lands in is exactly what
// each agent's own `cmd` was verified against (see registry.ts), so a fixture
// would only prove this file's own fake cmd, not the shipped one.
describe("cheapNamingModel", () => {
  // Every entry here also declares a usage descriptor, which appends its own
  // flag (an --output-format/--json/--format json, or copilot's random-pathed
  // --usage-output-file) to the same argv this pins — off for this block so
  // what is asserted is --model's position, not modelwatch's unrelated flags.
  // ANTGRID_NAMING_MODEL is cleared for the same reason it exists: an operator
  // who exported it would otherwise turn this whole block red, and the cases
  // that need a value set one themselves.
  //
  // Both are SAVED and restored, never deleted: bun loads a workspace's test
  // files into one process and both switches are read per spawn, so a plain
  // delete would silently revoke, partway through the run, the setting the
  // operator asked for.
  const prior: Record<string, string | undefined> = {};
  const swap = (name: string, value?: string) => {
    if (value === undefined) delete process.env[name];
    else process.env[name] = value;
  };
  beforeEach(() => {
    prior.usage = process.env.ANTGRID_MODELWATCH_USAGE;
    prior.naming = process.env.ANTGRID_NAMING_MODEL;
    process.env.ANTGRID_MODELWATCH_USAGE = "0";
    delete process.env.ANTGRID_NAMING_MODEL;
  });
  afterEach(() => {
    swap("ANTGRID_MODELWATCH_USAGE", prior.usage);
    swap("ANTGRID_NAMING_MODEL", prior.naming);
  });

  // kimi declares no headless entry at all, so it has no cheapNamingModel of its
  // own either — a "haiku" in this argv could only have come from claude-code,
  // the agent that actually served the borrowed call.
  test("a borrowed call gets the serving agent's model, never the requested agent's", async () => {
    const { spawn, calls } = fakeSpawn("Something useful\n");
    await generateTitleFromContext("ctx", {
      tool: "kimi", spawn, installedTools: ["claude-code"],
    });
    expect(calls).toHaveLength(1);
    expect(calls[0]).toEqual(expect.arrayContaining(["--model", "haiku"]));
  });

  test("an explicit opts.model wins over the serving agent's default", async () => {
    const { spawn, calls } = fakeSpawn("Something useful\n");
    await generateTitleFromContext("ctx", {
      tool: "claude-code", model: "claude-opus-5", spawn, installedTools: ["claude-code"],
    });
    expect(calls[0]).toEqual(expect.arrayContaining(["--model", "claude-opus-5"]));
    expect(calls[0]).not.toContain("haiku");
  });

  // A caller names a model and a tool together, so the pairing is void the
  // moment the call borrows: a claude slug reaching `codex exec -m` is not
  // rejected locally — it reaches the API and comes back 400. kimi declares no
  // headless entry, which is what makes this call borrow at all.
  test("a caller's model is dropped on a borrow, not forwarded to the other vendor", async () => {
    const { spawn, calls } = fakeSpawn("Something useful\n");
    await generateTitleFromContext("ctx", {
      tool: "kimi", model: "haiku", spawn, installedTools: ["codex"],
    });
    expect(calls[0]![0]).toBe("codex");
    expect(calls[0]).not.toContain("haiku");
    // Not merely dropped — replaced by the entry the SERVING vendor verified.
    expect(calls[0]!.slice(-3, -1)).toEqual(["-m", "gpt-5.6-luna"]);
  });

  // Every entry here was verified against ONE account, and what an account can
  // reach is account-specific. The switch is what a user whose vendor moved
  // underneath them can reach without a new build — naming refuses a session for
  // good after two failures, so there has to be one.
  test("ANTGRID_NAMING_MODEL=0 spawns naming with no --model at all", async () => {
    process.env.ANTGRID_NAMING_MODEL = "0";
    const { spawn, calls } = fakeSpawn("Something useful\n");
    await generateTitleFromContext("ctx", {
      tool: "claude-code", spawn, installedTools: ["claude-code"],
    });
    expect(calls[0]).not.toContain("--model");
    expect(calls[0]).not.toContain("haiku");
    // The switch drops the flag, nothing else: the rest of the verified argv is
    // untouched.
    expect(calls[0]![0]).toBe("claude");
    expect(calls[0]).toContain("--no-session-persistence");
  });

  // Off-only. A slug here could not know which vendor ends up serving a borrowed
  // call, which is the mismatch the whole resolution exists to prevent, so any
  // value but "0" leaves the declared default in place rather than replacing it.
  test("ANTGRID_NAMING_MODEL is an off switch, never a substitute slug", async () => {
    process.env.ANTGRID_NAMING_MODEL = "some-other-model";
    const { spawn, calls } = fakeSpawn("Something useful\n");
    await generateTitleFromContext("ctx", {
      tool: "claude-code", spawn, installedTools: ["claude-code"],
    });
    expect(calls[0]!.slice(-2)).toEqual(["--model", "haiku"]);
    expect(calls[0]).not.toContain("some-other-model");
  });

  // The `list`-visibility slugs in a ChatGPT account's ~/.codex/models_cache.json
  // under codex-cli 0.163.0. A slug outside it is refused by the API with a 400
  // ("not supported when using Codex with a ChatGPT account"), so every codex
  // title call exits 1 and burns one of the session's title attempts.
  const CODEX_0_163_LISTED = [
    "gpt-6.1-sol", "gpt-6-astra", "gpt-6-sol", "gpt-6-luna", "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna",
  ];
  test("codex names with a model its ChatGPT-account catalog lists", async () => {
    const { spawn, calls } = fakeSpawn("t\n");
    await generateTitleFromContext("ctx", { tool: "codex", spawn, installedTools: ["codex"] });
    const argv = calls[0]!;
    expect(CODEX_0_163_LISTED).toContain(argv[argv.indexOf("-m") + 1]);
  });

  // opencode and its fork kilo serve whatever providers the user configured, so
  // naming asks the installed CLI for the model it titles its own sessions with.
  // The probes answer in opencode 1.19.5's own output shapes, which kilo 7.8.x
  // shares; the resolution rules themselves are covered by
  // opencode-naming-model.test.ts in antgrid-agents.
  function opencodeSpawn(answers: { config: object; models: string; stateDir: string }) {
    const calls: string[][] = [];
    const options: Array<Record<string, any>> = [];
    const spawn = ((cmd: string[], o?: Record<string, any>) => {
      calls.push(cmd);
      options.push(o ?? {});
      const key = cmd.slice(1, 3).join(" ");
      const stdout = key === "debug config" ? JSON.stringify(answers.config, null, 2)
        : key === "debug paths" ? `home       /scratch\nstate      ${answers.stateDir}\n`
        : key === "models --verbose" ? answers.models
        : "Name the task\n";
      return { stdout: new Response(stdout).body, exited: Promise.resolve(0), kill() {} };
    }) as unknown as typeof Bun.spawn;
    return { spawn, calls, options };
  }
  const verboseModel = (providerID: string, id: string, family: string, release_date: string) =>
    `${providerID}/${id}\n${JSON.stringify({ id, providerID, family, release_date, name: id, status: "active" }, null, 2)}\n`;
  function stateDirWithRecent(providerID: string, modelID: string): string {
    const dir = tmp();
    writeFileSync(join(dir, "model.json"), JSON.stringify({ recent: [{ providerID, modelID }] }));
    return dir;
  }

  test("opencode names with the small model opencode itself would title with", async () => {
    const { spawn, calls, options } = opencodeSpawn({
      config: {},
      stateDir: stateDirWithRecent("anthropic", "claude-sonnet-5"),
      models: [
        verboseModel("anthropic", "claude-sonnet-5", "claude-sonnet", "2026-08-01"),
        verboseModel("anthropic", "claude-haiku-5-5", "claude-haiku", "2026-08-01"),
        verboseModel("anthropic", "claude-haiku-4-5", "claude-haiku", "2025-10-15"),
      ].join(""),
    });
    const result = await generateTitleFromContext("ctx", { tool: "opencode", spawn, installedTools: ["opencode"] });
    expect(result).toMatchObject({ ok: true, title: "Name the task" });
    const run = calls.at(-1)!;
    expect(run.slice(0, 2)).toEqual(["opencode", "run"]);
    expect(run.slice(-3, -1)).toEqual(["--model", "anthropic/claude-haiku-5-5"]);
    // The probes resolve the config the naming run sees: same binary, same env.
    expect(calls.slice(0, -1).map((argv) => argv[0])).toEqual(["opencode", "opencode", "opencode"]);
    for (const o of options) expect(o.env.OPENCODE_DB).toBe(":memory:");
  });

  // A ChatGPT sign-in's openai catalog has no small family, so opencode's own
  // titling falls back to the session's model; so does this.
  test("opencode with no small model for its provider names on its own default", async () => {
    const { spawn, calls } = opencodeSpawn({
      config: {},
      stateDir: stateDirWithRecent("openai", "gpt-6.1-sol"),
      models: verboseModel("openai", "gpt-6.1-sol", "gpt-sol", "2026-09-29"),
    });
    await generateTitleFromContext("ctx", { tool: "opencode", spawn, installedTools: ["opencode"] });
    expect(calls.at(-1)!.slice(0, 2)).toEqual(["opencode", "run"]);
    expect(calls.at(-1)).not.toContain("--model");
  });

  test("ANTGRID_NAMING_MODEL=0 skips opencode's model probes entirely", async () => {
    process.env.ANTGRID_NAMING_MODEL = "0";
    const { spawn, calls } = opencodeSpawn({ config: { small_model: "openai/gpt-5-nano" }, stateDir: tmp(), models: "" });
    await generateTitleFromContext("ctx", { tool: "opencode", spawn, installedTools: ["opencode"] });
    expect(calls.length).toBe(1);
    expect(calls[0]).not.toContain("--model");
  });

  // kilo-auto/small is an id, not a family, so only kilo's own rule finds it —
  // opencode's family search would take the gemini-flash beside it.
  test("kilo names with kilo-auto/small on a kilo provider, probing the kilo binary", async () => {
    const { spawn, calls, options } = opencodeSpawn({
      config: {},
      stateDir: stateDirWithRecent("kilo", "kilo-auto/balanced"),
      models: [
        verboseModel("kilo", "kilo-auto/balanced", "", "2026-11-03"),
        verboseModel("kilo", "kilo-auto/small", "", "2026-11-03"),
        verboseModel("kilo", "google/gemini-3-flash", "gemini-flash", "2026-10-01"),
      ].join(""),
    });
    await generateTitleFromContext("ctx", { tool: "kilo", spawn, installedTools: ["kilo"] });
    expect(calls.slice(0, -1).map((argv) => argv[0])).toEqual(["kilo", "kilo", "kilo"]);
    for (const o of options) expect(o.env.KILO_DB).toBe(":memory:");
    expect(calls.at(-1)!.slice(-3, -1)).toEqual(["--model", "kilo/kilo-auto/small"]);
  });

  // The fallback is the argv exactly as verified, with nothing but --model left out.
  test("an agent whose resolver finds no model spawns its bare verified argv", async () => {
    const { spawn, calls } = opencodeSpawn({ config: {}, stateDir: tmp(), models: "" });
    await generateTitleFromContext("ctx", { tool: "kilo", spawn, installedTools: ["kilo"] });
    expect(calls.at(-1)).toEqual([
      "kilo", "run", "--agent", "plan", expect.stringContaining("ctx"),
    ]);
  });

  // Each agent's `cmd` places --model at a different, independently-verified
  // spot in the argv (immediately after --allowedTools' value for claude,
  // immediately before the positional prompt for codex, and for opencode's
  // resolved model above). The default must reach that exact spot, not merely
  // appear somewhere in the argv.
  test("the default model lands where that agent's cmd places --model", async () => {
    const claude = fakeSpawn("t\n");
    await generateTitleFromContext("ctx", {
      tool: "claude-code", spawn: claude.spawn, installedTools: ["claude-code"],
    });
    expect(claude.calls[0]!.slice(-2)).toEqual(["--model", "haiku"]);

    const codex = fakeSpawn("t\n");
    await generateTitleFromContext("ctx", {
      tool: "codex", spawn: codex.spawn, installedTools: ["codex"],
    });
    expect(codex.calls[0]!.slice(-3, -1)).toEqual(["-m", "gpt-5.6-luna"]);
  });
});

// agent-core retries a "failed" within a small budget and never retries an
// "unavailable" (see TitleAttemptState), so which one a given failure produces
// decides whether a session can still be named later. Pinned here because the
// two are one `ok: false` to the type system and nothing else would catch a
// swap. Every arm also carries the attribution the caller records its outcome
// against, and `actualTool` is pinned because it is the only thing that names a
// borrow — an outcome filed under the vendor that did not run is worse than none.
describe("failure reasons", () => {
  test("no installed agent can serve the call is 'unavailable'", async () => {
    const { spawn, calls } = fakeSpawn("Add retry to uploader");
    const r = await generateTitleFromContext("ctx", {
      tool: "kimi", spawn, installedTools: [],
    });
    expect(r).toEqual({
      ok: false, reason: "unavailable",
      callId: expect.any(String), actualTool: "kimi", reach: "none",
    });
    // Nothing ran: the refusal is the machine's, not this attempt's.
    expect(calls.length).toBe(0);
  });

  // Refused BEFORE the spawn, and deliberately not as 'unavailable': this agent
  // has a verified argv, so reporting the machine as unable to name it would
  // send a reader looking for an install that is already there.
  test("a vendor that bills per call is 'skipped', with nothing spawned", async () => {
    const { spawn, calls } = fakeSpawn("Add retry to uploader");
    const r = await generateTitleFromContext("ctx", {
      tool: "github-copilot", spawn, installedTools: ["github-copilot"],
    });
    expect(r).toEqual({
      ok: false, reason: "skipped",
      callId: expect.any(String), actualTool: "github-copilot", reach: "readonly",
    });
    expect(calls.length).toBe(0);
  });

  // Read off the agent that would SERVE the call, never the one whose session
  // it is: a borrowed call bills the vendor that runs it, so a kimi session
  // landing on copilot would spend copilot's unit.
  test("a borrow onto a per-call-billed vendor is skipped too", async () => {
    const { spawn, calls } = fakeSpawn("Add retry to uploader");
    const r = await generateTitleFromContext("ctx", {
      tool: "kimi", spawn, installedTools: ["github-copilot"],
    });
    expect(r).toEqual({
      ok: false, reason: "skipped",
      callId: expect.any(String), actualTool: "github-copilot", reach: "readonly",
    });
    expect(calls.length).toBe(0);
  });

  test("a non-zero exit is 'failed', so the next turn may try again", async () => {
    const { spawn } = fakeSpawn("Invalid API key · Please run /login", { exitCode: 1 });
    const r = await generateTitleFromContext("ctx", {
      tool: "claude-code", spawn, installedTools: ["claude-code"],
    });
    expect(r).toEqual({
      ok: false, reason: "failed",
      callId: expect.any(String), actualTool: "claude-code", reach: "readonly",
    });
  });

  test("a clean exit with unusable output is 'failed', not a title", async () => {
    // Long enough to fail parseTitleFromOutput's cap — the spawn worked and the
    // model rambled.
    const { spawn } = fakeSpawn("Sure! Here is a title that goes on and on and " +
      "on well past any reasonable length for naming a session");
    const r = await generateTitleFromContext("ctx", {
      tool: "claude-code", spawn, installedTools: ["claude-code"],
    });
    expect(r).toEqual({
      ok: false, reason: "failed",
      callId: expect.any(String), actualTool: "claude-code", reach: "readonly",
    });
  });

  test("a usable title comes back as ok", async () => {
    const { spawn } = fakeSpawn("Add retry to uploader");
    const r = await generateTitleFromContext("ctx", {
      tool: "claude-code", spawn, installedTools: ["claude-code"],
    });
    expect(r).toEqual({
      ok: true, title: "Add retry to uploader",
      callId: expect.any(String), actualTool: "claude-code", reach: "readonly",
    });
  });
});
