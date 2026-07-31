import { describe, expect, test } from "bun:test";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { generateSessionTitle, parseTitleFromOutput } from "../src/agents/title-generate";

function tmp() { return mkdtempSync(join(tmpdir(), "ab-tg-")); }

/**
 * Stands in for Bun.spawn: records the argv it was handed, replays `stdout`.
 * With `hang`, `exited` settles only on kill() — mirroring a real process that
 * outlives its budget, so the timeout path is what ends the call.
 */
function fakeSpawn(stdout: string, opts: { hang?: boolean } = {}) {
  const calls: string[][] = [];
  const spawn = ((cmd: string[]) => {
    calls.push(cmd);
    let onKill: (() => void) | undefined;
    return {
      stdout: new Response(stdout).body,
      exited: opts.hang ? new Promise<number>((res) => { onKill = () => res(143); }) : Promise.resolve(0),
      kill() { onKill?.(); },
    };
  }) as unknown as typeof Bun.spawn;
  return { spawn, calls };
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

  // An agent with no vetted headless one-shot has nothing to ask; cursor-agent
  // carries no `judge` in the registry.
  test("an agent with no judge → null, without spawning", async () => {
    const { spawn, calls } = fakeSpawn("Something\n");
    expect(await generateSessionTitle({
      tool: "cursor-agent", cwd: tmp(), fallbackContext: "do a thing", spawn,
    })).toBeNull();
    expect(calls).toHaveLength(0);
  });

  test("unknown tool → null", async () => {
    const { spawn } = fakeSpawn("Something\n");
    expect(await generateSessionTitle({
      tool: "not-an-agent", cwd: tmp(), fallbackContext: "x", spawn,
    })).toBeNull();
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
