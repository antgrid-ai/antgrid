// bridge/src/handler/judge.ts
import { buildJudgeCommand, buildJudgePrompt, parseDecisionFromOutput, type HandlerDecision } from "./decision";

// Spawns the running agent's own CLI in non-interactive mode (reusing its auth) as a
// read-only judge. spawn is injectable for tests. Any failure → null (engine escalates).
export async function runJudge(opts: {
  tool: string; model?: string; guidance: string; context: string; cwd: string;
  spawn?: typeof Bun.spawn;
}): Promise<HandlerDecision | null> {
  const prompt = buildJudgePrompt(opts.guidance, opts.context);
  const cmd = buildJudgeCommand(opts.tool, opts.model, prompt);
  if (!cmd) return null;
  const spawn = opts.spawn ?? Bun.spawn;
  try {
    const proc = spawn(cmd, { cwd: opts.cwd, stdout: "pipe", stderr: "ignore" });
    const out = await new Response(proc.stdout).text();
    await proc.exited;
    return parseDecisionFromOutput(out);
  } catch {
    return null;
  }
}
