import { spawnSync } from "node:child_process";
import { copyFileSync, existsSync, mkdirSync, readFileSync } from "node:fs";
import { dirname } from "node:path";
import {
  SetupPlanFileSchema,
  formatSetupStepMarker,
  writeSetupResult,
  type SetupPlanFile,
  type SetupPlanStep,
} from "../worktrees/checkout-setup";

/**
 * The child half of `worktree.setup`: the bridge re-invoked under its own PTY,
 * one process for the whole run so the scrollback of the step that failed is
 * still there when the user expands the log.
 *
 * It inherits the PTY, so everything it has to say goes to stdout — the
 * bridge's structured logger writes to the host's own stream and would never
 * reach the transcript the user is looking at.
 */
export async function runWorktreeSetupCli(opts: { plan: string }): Promise<number> {
  let plan: SetupPlanFile;
  try {
    plan = SetupPlanFileSchema.parse(JSON.parse(readFileSync(opts.plan, "utf8")));
  } catch (err) {
    // Nothing has been parsed, so the result path is unknown and the parent
    // falls back to "ended without reporting a result". Say why here anyway —
    // this text is the only thing in the transcript.
    process.stdout.write(`antgrid setup: unreadable plan ${opts.plan}: ${(err as Error).message}\n`);
    return 1;
  }

  const count = plan.steps.length;
  process.stdout.write(`Preparing workspace — ${count} step${count === 1 ? "" : "s"}\n`);

  for (let index = 0; index < count; index++) {
    const step = plan.steps[index]!;
    // The marker leads the step so the banner names what is ABOUT to run; a
    // long install would otherwise sit under the previous step's name.
    process.stdout.write(formatSetupStepMarker(index, count, step.name));
    process.stdout.write(`\n→ [${index + 1}/${count}] ${step.name}\n`);

    const failure = step.run !== undefined ? runStep(plan, step) : copyStep(step);
    if (failure !== null) {
      process.stdout.write(`\n✖ ${failure.message}\n`);
      writeSetupResult(plan.resultPath, {
        exitCode: failure.exitCode,
        stepIndex: index,
        stepName: step.name,
        message: failure.message,
      });
      return failure.exitCode;
    }
  }

  process.stdout.write("\n✔ Workspace ready\n");
  writeSetupResult(plan.resultPath, {
    exitCode: 0,
    stepIndex: Math.max(count - 1, 0),
    stepName: plan.steps[count - 1]?.name,
  });
  return 0;
}

interface StepFailure {
  exitCode: number;
  message: string;
}

/**
 * A missing source is a warning, not a failure: not every developer has every
 * env file, and `scripts/worktree.ts:copyEnv` — the hand-rolled provisioner
 * this replaces — has always behaved this way.
 */
function copyStep(step: SetupPlanStep): StepFailure | null {
  for (const entry of step.copy ?? []) {
    if (!existsSync(entry.from)) {
      process.stdout.write(`  ! ${entry.rel} not found in the main checkout — skipping\n`);
      continue;
    }
    try {
      mkdirSync(dirname(entry.to), { recursive: true });
      copyFileSync(entry.from, entry.to);
    } catch (err) {
      return { exitCode: 1, message: `${step.name}: could not copy ${entry.rel} — ${(err as Error).message}` };
    }
    process.stdout.write(`  copied ${entry.rel}\n`);
  }
  return null;
}

/**
 * `shell: true` matches the `commands` / `services` blocks: a setup line is
 * written as shell, and it comes from the checkout's own `antgrid.yaml`, which
 * is the same trust class as those.
 *
 * Synchronous on purpose — the run is strictly sequential and stdio is
 * inherited, so interleaving would only scramble the transcript.
 */
function runStep(plan: SetupPlanFile, step: SetupPlanStep): StepFailure | null {
  process.stdout.write(`  $ ${step.run}  (in ${step.workingDir})\n`);
  const result = spawnSync(step.run!, {
    cwd: step.workingDir,
    env: { ...process.env, ...plan.env, ...step.env },
    stdio: "inherit",
    shell: true,
  });
  if (result.error) {
    return { exitCode: 1, message: `${step.name}: ${result.error.message}` };
  }
  if (result.signal) {
    return { exitCode: 1, message: `${step.name} was terminated (${result.signal})` };
  }
  const code = result.status ?? 1;
  if (code !== 0) {
    return { exitCode: code, message: `${step.name} failed (exit ${code})` };
  }
  return null;
}
