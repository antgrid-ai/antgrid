import { afterEach, beforeEach, describe, expect, spyOn, test } from "bun:test";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import type { TerminalSpawnConfig } from "../src/terminal-manager";
import {
  CheckoutSetupRunner,
  SetupPlanFileSchema,
  formatSetupStepMarker,
  parseSetupStepMarker,
  setupTerminalId,
  type SetupPlanFile,
} from "../src/worktrees/checkout-setup";
import { runWorktreeSetupCli } from "../src/cli/worktree-setup";
import type { CheckoutRecord, CheckoutSetupProgress } from "../src/worktrees/checkout-types";

let root: string;
let projectPath: string;
let checkoutPath: string;
let planDir: string;
let previousAbDir: string | undefined;

beforeEach(() => {
  previousAbDir = process.env.ANTGRID_DIR;
  root = mkdtempSync(join(tmpdir(), "antgrid-setup-"));
  // An ANTGRID_DIR of its own, or a developer's real ~/.antgrid/antgrid.yaml
  // decides what the global-fallback cases below see.
  process.env.ANTGRID_DIR = join(root, "state");
  projectPath = join(root, "project");
  checkoutPath = join(root, "worktree");
  planDir = join(root, "plans");
  mkdirSync(projectPath, { recursive: true });
  mkdirSync(checkoutPath, { recursive: true });
});

afterEach(() => {
  if (previousAbDir === undefined) delete process.env.ANTGRID_DIR;
  else process.env.ANTGRID_DIR = previousAbDir;
  rmSync(root, { recursive: true, force: true });
});

const CHECKOUT: CheckoutRecord = {
  id: "checkout-1",
  projectId: "p",
  kind: "managed-worktree",
  path: "",
  branch: "antgrid/tidy-otter",
  baseRef: "release/2.1",
  managed: true,
  sessionId: "session-1",
  createdAt: 1,
};

function checkout(): CheckoutRecord {
  return { ...CHECKOUT, path: checkoutPath };
}

/** Stands in for the TerminalManager: the runner only ever spawns and tree-kills,
 *  and a real PTY would make every case here depend on a shell. */
function fakeTerminals() {
  const spawns: TerminalSpawnConfig[] = [];
  const killed: string[] = [];
  return {
    spawns,
    killed,
    spawn: (config: TerminalSpawnConfig): string => {
      spawns.push(config);
      // The runner always names the setup terminal itself; an unnamed spawn is a bug worth failing on.
      if (!config.terminalId) throw new Error("setup spawn must carry an explicit terminalId");
      return config.terminalId;
    },
    killAndAwaitTree: async (terminalId: string): Promise<void> => { killed.push(terminalId); },
  };
}

function writeCheckoutConfig(body: string): void {
  writeFileSync(join(checkoutPath, "antgrid.yaml"), body);
}

function newRunner(terminals = fakeTerminals()) {
  const runner = new CheckoutSetupRunner({
    projectPath,
    terminals,
    planDir,
    execPath: "/fake/bun",
    entrypoint: "/fake/src/index.ts",
    compiled: false,
  });
  return { runner, terminals };
}

/** `start` is fire-and-forget; give its (synchronous) body a turn to land. */
async function settle(): Promise<void> {
  await new Promise((r) => setTimeout(r, 0));
}

function readPlan(): SetupPlanFile {
  return SetupPlanFileSchema.parse(
    JSON.parse(readFileSync(join(planDir, `${CHECKOUT.id}.plan.json`), "utf8")),
  );
}

describe("CheckoutSetupRunner plan resolution", () => {
  test("interpolates every checkout variable against the real worktree", async () => {
    // The whole reason `worktree` is excluded from config.ts's eager resolveAll:
    // that pass interpolates ${project.path} against process.cwd(), which for a
    // checkout's own antgrid.yaml is the MAIN tree.
    writeCheckoutConfig([
      "worktree:",
      "  setup:",
      "    steps:",
      "      - name: Report",
      "        run: echo ${project.path} ${checkout.path} ${checkout.branch} ${base.branch} ${session.id} ${env.ANTGRID_SETUP_FIXTURE}",
      "        workingDir: sub",
      "        env:",
      "          BRANCH: ${checkout.branch}",
    ].join("\n"));
    const { runner } = newRunner();
    process.env.ANTGRID_SETUP_FIXTURE = "from-env";
    try {
      runner.start(checkout(), "session-1", () => {});
      await settle();
    } finally {
      delete process.env.ANTGRID_SETUP_FIXTURE;
    }

    const step = readPlan().steps[0]!;
    expect(step.run).toBe(
      `echo ${resolve(projectPath)} ${resolve(checkoutPath)} antgrid/tidy-otter release/2.1 session-1 from-env`,
    );
    // workingDir resolves against the CHECKOUT, never the project: a relative
    // dir in a setup block names a directory in the tree being provisioned.
    expect(step.workingDir).toBe(resolve(checkoutPath, "sub"));
    expect(step.env).toEqual({ BRANCH: "antgrid/tidy-otter" });
  });

  test("a copy step reads from the project and writes the same relative path into the checkout", async () => {
    writeCheckoutConfig([
      "worktree:",
      "  setup:",
      "    steps:",
      "      - name: Copy env files",
      "        copy: [\"web/.env\"]",
    ].join("\n"));
    const { runner } = newRunner();
    runner.start(checkout(), "session-1", () => {});
    await settle();

    expect(readPlan().steps[0]!.copy).toEqual([{
      rel: "web/.env",
      from: resolve(projectPath, "web/.env"),
      to: resolve(checkoutPath, "web/.env"),
    }]);
  });

  test("the plan hands the child absolute paths and the ANTGRID_* contract", async () => {
    writeCheckoutConfig("worktree:\n  setup:\n    steps:\n      - name: Install\n        run: bun install\n");
    const { runner, terminals } = newRunner();
    runner.start(checkout(), "session-1", () => {});
    await settle();

    const plan = readPlan();
    expect(plan).toMatchObject({
      version: 1,
      checkoutId: "checkout-1",
      checkoutPath: resolve(checkoutPath),
      projectPath: resolve(projectPath),
      sessionId: "session-1",
      env: {
        ANTGRID_PROJECT_PATH: resolve(projectPath),
        ANTGRID_CHECKOUT_PATH: resolve(checkoutPath),
        ANTGRID_CHECKOUT_BRANCH: "antgrid/tidy-otter",
        ANTGRID_BASE_BRANCH: "release/2.1",
        ANTGRID_SESSION_ID: "session-1",
        ANTGRID_SETUP: "1",
      },
    });

    const spawn = terminals.spawns[0]!;
    expect(spawn.terminalId).toBe(setupTerminalId("checkout-1"));
    expect(spawn.cwd).toBe(checkoutPath);
    expect(spawn.command).toBe("/fake/bun");
    // Uncompiled, execPath is bun itself, so the entrypoint leads the subcommand.
    expect(spawn.args).toEqual([
      "/fake/src/index.ts", "worktree-setup", "--plan", join(planDir, "checkout-1.plan.json"),
    ]);
    // `suppressOscTitle` would suppress the onTitle callback itself, which is
    // the channel every step transition travels on.
    expect(spawn.suppressOscTitle).toBeUndefined();
    expect(spawn.suppressOscNotifications).toBe(true);
    // Neither an agent nor a service: typing it would put a provisioning log in
    // the services list.
    expect(spawn.type).toBeUndefined();
    expect(spawn.retainScrollbackOnExit).toBe(true);
  });

  test("a compiled bridge invokes its own subcommand with no entrypoint", async () => {
    writeCheckoutConfig("worktree:\n  setup:\n    steps:\n      - name: Install\n        run: bun install\n");
    const terminals = fakeTerminals();
    const runner = new CheckoutSetupRunner({
      projectPath, terminals, planDir, execPath: "/opt/antgrid/antgrid", compiled: true,
    });
    runner.start(checkout(), "session-1", () => {});
    await settle();
    expect(terminals.spawns[0]!.args).toEqual([
      "worktree-setup", "--plan", join(planDir, "checkout-1.plan.json"),
    ]);
  });

  test("a checkout with no setup block reports done without spawning", async () => {
    // The caller stamped `running` before calling and has to be released either
    // way — silence would leave the session preparing forever.
    const { runner, terminals } = newRunner();
    const progress: CheckoutSetupProgress[] = [];
    runner.start(checkout(), "session-1", (p) => progress.push(p));
    await settle();
    expect(progress).toEqual([{ state: "done", stepIndex: 0, stepCount: 0 }]);
    expect(terminals.spawns).toEqual([]);
  });

  test("a machine-global antgrid.yaml never provisions someone else's worktree", async () => {
    // findConfigFile falls back to <ANTGRID_DIR>/antgrid.yaml, and a global setup
    // block would then run for every project's worktrees without anyone asking.
    mkdirSync(process.env.ANTGRID_DIR!, { recursive: true });
    writeFileSync(
      join(process.env.ANTGRID_DIR!, "antgrid.yaml"),
      "worktree:\n  setup:\n    steps:\n      - name: Global\n        run: echo global\n",
    );
    const { runner, terminals } = newRunner();
    expect(runner.resolveSetup(checkout())).toBeNull();
    runner.start(checkout(), "session-1", () => {});
    await settle();
    expect(terminals.spawns).toEqual([]);
  });

  test("an unparseable checkout config fails the run instead of throwing at the caller", async () => {
    writeCheckoutConfig("worktree:\n  setup:\n    steps:\n      - name: Both\n        run: echo hi\n        copy: [\".env\"]\n");
    const { runner, terminals } = newRunner();
    const progress: CheckoutSetupProgress[] = [];
    runner.start(checkout(), "session-1", (p) => progress.push(p));
    await settle();
    expect(progress).toHaveLength(1);
    expect(progress[0]!.state).toBe("failed");
    expect(progress[0]!.message).toContain("either copy or run");
    expect(terminals.spawns).toEqual([]);
  });
});

describe("CheckoutSetupRunner copy path guard", () => {
  /** Both roots are checked against the SAME relative path, so an escape refuses
   *  the run whichever side you read it from: the source would read outside the
   *  main project and the destination would write outside the worktree. A
   *  checkout's antgrid.yaml is branch-supplied content, so neither is theoretical. */
  async function refusedCopy(entry: string): Promise<CheckoutSetupProgress> {
    writeCheckoutConfig([
      "worktree:",
      "  setup:",
      "    steps:",
      "      - name: Copy env files",
      `        copy: [${JSON.stringify(entry)}]`,
    ].join("\n"));
    const { runner, terminals } = newRunner();
    const progress: CheckoutSetupProgress[] = [];
    runner.start(checkout(), "session-1", (p) => progress.push(p));
    await settle();
    // Refused at plan time: nothing spawns, so neither root is ever touched.
    expect(terminals.spawns).toEqual([]);
    expect(progress).toHaveLength(1);
    return progress[0]!;
  }

  test("refuses a parent-directory escape", async () => {
    const failure = await refusedCopy("../../.ssh/id_ed25519");
    expect(failure.state).toBe("failed");
    expect(failure.message).toContain("escapes the project root");
  });

  test("refuses an interior .. that climbs back out", async () => {
    const failure = await refusedCopy("web/../../secrets.env");
    expect(failure.state).toBe("failed");
    expect(failure.message).toContain("escapes the project root");
  });

  test("refuses the root itself, which would copy a whole tree over another", async () => {
    const failure = await refusedCopy(".");
    expect(failure.state).toBe("failed");
    expect(failure.message).toContain("escapes the project root");
  });

  test("refuses an absolute source outright", async () => {
    const failure = await refusedCopy(process.platform === "win32" ? "C:/secrets/.env" : "/etc/shadow");
    expect(failure.state).toBe("failed");
    expect(failure.message).toContain("must be relative to the project root");
  });

  test("refuses an escape that only appears after interpolation", async () => {
    // The guard runs on the RESOLVED path: checking the raw string would let
    // `${env.X}` smuggle the `..` past it.
    process.env.ANTGRID_SETUP_ESCAPE = "../..";
    try {
      const failure = await refusedCopy("${env.ANTGRID_SETUP_ESCAPE}/secrets.env");
      expect(failure.state).toBe("failed");
      expect(failure.message).toContain("escapes the project root");
    } finally {
      delete process.env.ANTGRID_SETUP_ESCAPE;
    }
  });
});

describe("CheckoutSetupRunner step markers", () => {
  test("a marker round-trips through the OSC title it rides", () => {
    const title = formatSetupStepMarker(2, 4, "Install dependencies");
    expect(title.startsWith("\x1b]2;")).toBe(true);
    expect(title.endsWith("\x07")).toBe(true);
    // The parser sees the TITLE, which is what the PTY hands the callback —
    // the escape wrapper never reaches it.
    expect(parseSetupStepMarker(title.slice(4, -1)))
      .toEqual({ index: 2, count: 4, name: "Install dependencies" });
  });

  test("a control byte in a step name is scrubbed rather than splitting the marker", () => {
    const title = formatSetupStepMarker(0, 1, "Install\x07dependencies");
    expect(parseSetupStepMarker(title.slice(4, -1)))
      .toEqual({ index: 0, count: 1, name: "Install dependencies" });
  });

  test("an ordinary title is not a marker", () => {
    expect(parseSetupStepMarker("bun install")).toBeNull();
  });

  test("a marker becomes a running transition and a foreign title is left alone", async () => {
    writeCheckoutConfig([
      "worktree:",
      "  setup:",
      "    steps:",
      "      - name: Copy env files",
      "        copy: [\".env\"]",
      "      - name: Install dependencies",
      "        run: bun install",
    ].join("\n"));
    const { runner } = newRunner();
    const progress: CheckoutSetupProgress[] = [];
    runner.start(checkout(), "session-1", (p) => progress.push(p));
    await settle();
    const terminalId = setupTerminalId("checkout-1");

    // The seed transition carries the terminal id, which is how the app learns
    // which log to replay.
    expect(progress).toEqual([{
      state: "running", stepIndex: 0, stepCount: 2, stepName: "Copy env files", terminalId,
    }]);

    expect(runner.handleTitle(terminalId, "antgrid-setup:1/2:Install dependencies")).toBe(true);
    expect(progress[1]).toEqual({
      state: "running", stepIndex: 1, stepCount: 2, stepName: "Install dependencies", terminalId,
    });

    // Owned but not a marker: swallowed all the same, or the session namer would
    // read a setup step's shell prompt as the conversation's title.
    expect(runner.handleTitle(terminalId, "bun install")).toBe(true);
    expect(progress).toHaveLength(2);

    // A PTY the runner does not own must fall straight through to the namer.
    expect(runner.handleTitle("some-session", "antgrid-setup:1/2:Install")).toBe(false);
  });

  test("the last marker's step survives into the terminal state", async () => {
    writeCheckoutConfig("worktree:\n  setup:\n    steps:\n      - name: One\n        run: echo one\n      - name: Two\n        run: echo two\n");
    const { runner } = newRunner();
    const progress: CheckoutSetupProgress[] = [];
    runner.start(checkout(), "session-1", (p) => progress.push(p));
    await settle();
    const terminalId = setupTerminalId("checkout-1");
    runner.handleTitle(terminalId, "antgrid-setup:1/2:Two");

    writeFileSync(
      join(planDir, "checkout-1.result.json"),
      JSON.stringify({ exitCode: 4, stepIndex: 1, stepName: "Two", message: "Two failed (exit 4)" }),
    );
    expect(runner.handleExit(terminalId)).toBe(true);
    expect(progress.at(-1)).toEqual({
      state: "failed", stepIndex: 1, stepCount: 2, stepName: "Two", terminalId,
      exitCode: 4, message: "Two failed (exit 4)",
    });
    // The staging files are the runner's, not the user's — and a stale result
    // would be read as the next run's outcome.
    expect(existsSync(join(planDir, "checkout-1.result.json"))).toBe(false);
    expect(existsSync(join(planDir, "checkout-1.plan.json"))).toBe(false);
  });

  test("a child that dies without a result is a failure, not a success", async () => {
    writeCheckoutConfig("worktree:\n  setup:\n    steps:\n      - name: One\n        run: echo one\n");
    const { runner } = newRunner();
    const progress: CheckoutSetupProgress[] = [];
    runner.start(checkout(), "session-1", (p) => progress.push(p));
    await settle();
    runner.handleExit(setupTerminalId("checkout-1"));
    expect(progress.at(-1)).toMatchObject({ state: "failed", message: "Setup ended without reporting a result" });
  });

  test("an exit for a terminal the runner never owned is ignored", () => {
    const { runner } = newRunner();
    expect(runner.handleExit("some-session")).toBe(false);
  });
});

describe("CheckoutSetupRunner cancel and timeout", () => {
  test("cancel kills the tree and settles as skipped, not failed", async () => {
    writeCheckoutConfig("worktree:\n  setup:\n    steps:\n      - name: Install\n        run: bun install\n");
    const { runner, terminals } = newRunner();
    const progress: CheckoutSetupProgress[] = [];
    runner.start(checkout(), "session-1", (p) => progress.push(p));
    await settle();
    expect(runner.isRunning("checkout-1")).toBe(true);

    await runner.cancel("checkout-1");
    // Awaited before `git worktree remove` runs: on Windows a live `bun install`
    // holding the checkout as its cwd makes the remove fail.
    expect(terminals.killed).toEqual([setupTerminalId("checkout-1")]);
    expect(progress.at(-1)).toMatchObject({ state: "skipped", message: "Setup cancelled" });
    expect(runner.isRunning("checkout-1")).toBe(false);
    expect(runner.owns(setupTerminalId("checkout-1"))).toBe(false);
  });

  test("the PTY's own exit after a cancel cannot reopen the run", async () => {
    writeCheckoutConfig("worktree:\n  setup:\n    steps:\n      - name: Install\n        run: bun install\n");
    const { runner } = newRunner();
    const progress: CheckoutSetupProgress[] = [];
    runner.start(checkout(), "session-1", (p) => progress.push(p));
    await settle();
    await runner.cancel("checkout-1");
    const settled = progress.length;
    expect(runner.handleExit(setupTerminalId("checkout-1"))).toBe(false);
    expect(progress).toHaveLength(settled);
  });

  test("cancelling a checkout with nothing running is a no-op", async () => {
    const { runner, terminals } = newRunner();
    await runner.cancel("checkout-1");
    expect(terminals.killed).toEqual([]);
  });

  test("the timeout budgets the whole run and reports which step wedged", async () => {
    writeCheckoutConfig([
      "worktree:",
      "  setup:",
      "    timeoutMs: 20",
      "    steps:",
      "      - name: Install dependencies",
      "        run: bun install",
    ].join("\n"));
    const { runner, terminals } = newRunner();
    const progress: CheckoutSetupProgress[] = [];
    runner.start(checkout(), "session-1", (p) => progress.push(p));
    await settle();

    const deadline = Date.now() + 3000;
    while (runner.isRunning("checkout-1") && Date.now() < deadline) {
      await new Promise((r) => setTimeout(r, 5));
    }
    expect(terminals.killed).toEqual([setupTerminalId("checkout-1")]);
    expect(progress.at(-1)).toMatchObject({
      state: "failed",
      stepName: "Install dependencies",
    });
    expect(progress.at(-1)!.message).toContain("timed out");
  });

  test("a rerun kills the run it replaces before spawning its own", async () => {
    writeCheckoutConfig("worktree:\n  setup:\n    steps:\n      - name: Install\n        run: bun install\n");
    const { runner, terminals } = newRunner();
    runner.start(checkout(), "session-1", () => {});
    await settle();
    const secondProgress: CheckoutSetupProgress[] = [];
    runner.start(checkout(), "session-1", (p) => secondProgress.push(p));
    await settle();

    // Two children writing the same result file is the failure this prevents.
    expect(terminals.killed).toEqual([setupTerminalId("checkout-1")]);
    expect(terminals.spawns).toHaveLength(2);
    expect(secondProgress[0]).toMatchObject({ state: "running", stepCount: 1 });
  });
});

describe("worktree-setup CLI", () => {
  function capture(): { lines: () => string; restore: () => void } {
    let buffer = "";
    const spy = spyOn(process.stdout, "write").mockImplementation(((chunk: unknown) => {
      buffer += String(chunk);
      return true;
    }) as typeof process.stdout.write);
    return { lines: () => buffer, restore: () => spy.mockRestore() };
  }

  function writePlan(steps: SetupPlanFile["steps"]): string {
    mkdirSync(planDir, { recursive: true });
    const path = join(planDir, "plan.json");
    const plan: SetupPlanFile = {
      version: 1,
      checkoutId: "checkout-1",
      checkoutPath: resolve(checkoutPath),
      projectPath: resolve(projectPath),
      sessionId: "session-1",
      resultPath: join(planDir, "result.json"),
      env: { ANTGRID_SETUP: "1" },
      steps,
    };
    writeFileSync(path, JSON.stringify(plan));
    return path;
  }

  function result(): unknown {
    return JSON.parse(readFileSync(join(planDir, "result.json"), "utf8"));
  }

  async function run(planPath: string): Promise<{ code: number; out: string }> {
    const captured = capture();
    try {
      return { code: await runWorktreeSetupCli({ plan: planPath }), out: captured.lines() };
    } finally {
      captured.restore();
    }
  }

  test("a missing copy source warns and the run carries on", async () => {
    // Not every developer has every env file, and the hand-rolled provisioner
    // this replaces (scripts/worktree.ts:copyEnv) has always skipped them.
    writeFileSync(join(projectPath, "present.env"), "KEY=value\n");
    const planPath = writePlan([{
      name: "Copy env files",
      copy: [
        { rel: "absent.env", from: join(projectPath, "absent.env"), to: join(checkoutPath, "absent.env") },
        { rel: "present.env", from: join(projectPath, "present.env"), to: join(checkoutPath, "present.env") },
      ],
      workingDir: checkoutPath,
    }]);

    const { code, out } = await run(planPath);
    expect(code).toBe(0);
    expect(out).toContain("absent.env not found in the main checkout");
    // The entry AFTER the missing one still runs: a skip must not abandon the step.
    expect(readFileSync(join(checkoutPath, "present.env"), "utf8")).toBe("KEY=value\n");
    expect(existsSync(join(checkoutPath, "absent.env"))).toBe(false);
    expect(result()).toMatchObject({ exitCode: 0, stepName: "Copy env files" });
  });

  test("a copy creates the directories its destination needs", async () => {
    mkdirSync(join(projectPath, "web"), { recursive: true });
    writeFileSync(join(projectPath, "web", ".env"), "DB=1\n");
    const planPath = writePlan([{
      name: "Copy env files",
      copy: [{ rel: "web/.env", from: join(projectPath, "web", ".env"), to: join(checkoutPath, "web", ".env") }],
      workingDir: checkoutPath,
    }]);
    expect((await run(planPath)).code).toBe(0);
    expect(readFileSync(join(checkoutPath, "web", ".env"), "utf8")).toBe("DB=1\n");
  });

  test("each step announces itself with an OSC marker before it runs", async () => {
    const planPath = writePlan([
      { name: "First", copy: [], workingDir: checkoutPath },
      { name: "Second", copy: [], workingDir: checkoutPath },
    ]);
    const { code, out } = await run(planPath);
    expect(code).toBe(0);
    // Leading the step, not trailing it: a long install would otherwise sit
    // under the previous step's name in the banner.
    expect(out).toContain(formatSetupStepMarker(0, 2, "First"));
    expect(out).toContain(formatSetupStepMarker(1, 2, "Second"));
    expect(out.indexOf(formatSetupStepMarker(0, 2, "First")))
      .toBeLessThan(out.indexOf(formatSetupStepMarker(1, 2, "Second")));
  });

  test("a failing run step stops the run and names itself in the result", async () => {
    const planPath = writePlan([
      { name: "Fails", run: "exit 3", workingDir: checkoutPath },
      { name: "Never runs", copy: [], workingDir: checkoutPath },
    ]);
    const { code, out } = await run(planPath);
    expect(code).toBe(3);
    expect(out).not.toContain(formatSetupStepMarker(1, 2, "Never runs"));
    expect(result()).toEqual({
      exitCode: 3, stepIndex: 0, stepName: "Fails", message: "Fails failed (exit 3)",
    });
  });

  test("an unreadable plan says so in the transcript rather than dying silently", async () => {
    const { code, out } = await run(join(planDir, "does-not-exist.json"));
    expect(code).toBe(1);
    expect(out).toContain("unreadable plan");
  });
});
