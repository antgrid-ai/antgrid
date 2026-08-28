import { describe, expect, test } from "bun:test";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  buildTitleContext, generateTitleFromContext, parseTitleFromOutput,
} from "../src/agents/title-generate";

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
      const env = options[0]!.env as Record<string, string>;
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

// agent-core retries a "failed" within a small budget and never retries an
// "unavailable" (see TitleAttemptState), so which one a given failure produces
// decides whether a session can still be named later. Pinned here because the
// two are one `ok: false` to the type system and nothing else would catch a
// swap.
describe("failure reasons", () => {
  test("no installed agent can serve the call is 'unavailable'", async () => {
    const { spawn, calls } = fakeSpawn("Add retry to uploader");
    const r = await generateTitleFromContext("ctx", {
      tool: "kimi", spawn, installedTools: [],
    });
    expect(r).toEqual({ ok: false, reason: "unavailable" });
    // Nothing ran: the refusal is the machine's, not this attempt's.
    expect(calls.length).toBe(0);
  });

  test("a non-zero exit is 'failed', so the next turn may try again", async () => {
    const { spawn } = fakeSpawn("Invalid API key · Please run /login", { exitCode: 1 });
    const r = await generateTitleFromContext("ctx", {
      tool: "claude-code", spawn, installedTools: ["claude-code"],
    });
    expect(r).toEqual({ ok: false, reason: "failed" });
  });

  test("a clean exit with unusable output is 'failed', not a title", async () => {
    // Long enough to fail parseTitleFromOutput's cap — the spawn worked and the
    // model rambled.
    const { spawn } = fakeSpawn("Sure! Here is a title that goes on and on and " +
      "on well past any reasonable length for naming a session");
    const r = await generateTitleFromContext("ctx", {
      tool: "claude-code", spawn, installedTools: ["claude-code"],
    });
    expect(r).toEqual({ ok: false, reason: "failed" });
  });

  test("a usable title comes back as ok", async () => {
    const { spawn } = fakeSpawn("Add retry to uploader");
    const r = await generateTitleFromContext("ctx", {
      tool: "claude-code", spawn, installedTools: ["claude-code"],
    });
    expect(r).toEqual({ ok: true, title: "Add retry to uploader" });
  });
});
