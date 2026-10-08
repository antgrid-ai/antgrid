import { afterAll, afterEach, beforeEach, expect, mock, spyOn, test } from "bun:test";
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { computeProjectId } from "../src/project-id";
import type { AgentCaller } from "../src/scheduler";

// The kill switch is a module constant, so it is flipped by replacing the module. Bun applies the replacement to
// modules that already imported it, and keeps it for the rest of the process, so it is put back after this file.
mock.module("../src/worktree-capability", () => ({ WORKTREE_SESSIONS_SUPPORTED: false }));
afterAll(() => { mock.module("../src/worktree-capability", () => ({ WORKTREE_SESSIONS_SUPPORTED: true })); });
const { HostServer } = await import("../src/host-server");

let root: string;
let previous: string | undefined;
let host: InstanceType<typeof HostServer>;

beforeEach(async () => {
  root = mkdtempSync(join(tmpdir(), "scheduler-flag-"));
  previous = process.env.ANTGRID_DIR;
  process.env.ANTGRID_DIR = join(root, "state");
  host = new HostServer({ desktopOwned: true, warmCap: 2 });
  spyOn(host, "buildToolsAdvertisement").mockResolvedValue([{ tool: "claude-code", path: "fixture", label: "Claude", chatCapable: true }]);
  await host.startControlPlane();
});
afterEach(async () => {
  await host.shutdown();
  if (previous === undefined) delete process.env.ANTGRID_DIR; else process.env.ANTGRID_DIR = previous;
  rmSync(root, { recursive: true, force: true, maxRetries: 10, retryDelay: 50 });
});

test("with isolated worktrees switched off, an agent's create on a git project defaults to the shared workspace", async () => {
  const folder = join(root, "repo"); mkdirSync(folder);
  const git = (...args: string[]) => {
    const result = Bun.spawnSync(["git", "-c", "user.email=t@example.com", "-c", "user.name=T", ...args], { cwd: folder });
    if (result.exitCode !== 0) throw new Error(`git ${args.join(" ")}: ${result.stderr.toString()}`);
  };
  git("init", "-b", "main");
  writeFileSync(join(folder, "a.txt"), "a");
  git("add", "."); git("commit", "-m", "init");
  const projectId = computeProjectId(folder);
  await host.open(projectId, folder, "local");
  const caller: AgentCaller = { projectId, sessionId: "caller", sessionName: "Planner", agentId: "claude-code", mode: "terminal",
    approvalLevel: "gated", scheduled: false };
  const result = await host.schedulerRequestForAgent(caller, "create", { name: "Nightly", prompt: "Review", cron: "0 9 * * *" }) as any;
  expect(result.schedule).toMatchObject({ workspace: "shared" });
  expect(result.schedule.baseBranch).toBeUndefined();
});
