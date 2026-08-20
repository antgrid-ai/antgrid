import { test, expect, beforeEach, afterEach } from "bun:test";
import { existsSync, mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { HostServer, type HostRemoteConfig, type RemoteRuntime } from "../src/host-server";
import { SessionManager } from "../src/session-manager";
import { projectRootName } from "../src/worktrees/checkout-names";
import { resolveProject } from "../src/worktrees/project-resolver";
import { WorktreeManager } from "../src/worktrees/worktree-manager";

function fakeRemoteConfig(): HostRemoteConfig {
  return {
    relayUrl: "ws://127.0.0.1:1", licenseApiUrl: "http://127.0.0.1:1",
    identity: { deviceId: "dev-1", deviceName: "dev-1", createdAt: "2026-01-01T00:00:00.000Z" },
    auth: { clientId: "cid", clientSecret: "secret", deviceUuid: "uuid-1" },
    onAuthRevoked: () => {},
  };
}
function fakeRuntime(): RemoteRuntime {
  return { maint: { getToken: () => "tok", stop: () => {} } };
}

async function git(cwd: string, args: string[]): Promise<string> {
  const proc = Bun.spawn(["git", ...args], { cwd, stdout: "pipe", stderr: "pipe" });
  const [code, stdout, stderr] = await Promise.all([proc.exited, new Response(proc.stdout).text(), new Response(proc.stderr).text()]);
  if (code !== 0) throw new Error(stderr);
  return stdout.trim();
}

let host: HostServer | null = null;
let prevAbDir: string | undefined;
let abDir: string | undefined;
let repo: string | undefined;

/** A real Git repository posing as a project folder: the reclamation this suite
 *  pins is entirely about Git registrations, so a fake folder proves nothing. */
async function gitProject(): Promise<{ folder: string; projectId: string }> {
  const folder = mkdtempSync(join(tmpdir(), "antgrid-forget-wt-proj-"));
  writeFileSync(join(folder, "antgrid.yaml"), "name: forget-wt\nagent:\n  tool: claude-code\n");
  await git(folder, ["init"]);
  await git(folder, ["config", "user.email", "test@antgrid.local"]);
  await git(folder, ["config", "user.name", "Antgrid Test"]);
  await git(folder, ["add", "."]);
  await git(folder, ["commit", "-m", "initial"]);
  const resolved = await resolveProject(folder);
  return { folder: resolved.repoPath, projectId: resolved.projectId };
}

function seedSessions(projectId: string, sessions: unknown[]): void {
  const dir = join(abDir!, "agents", projectId);
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, "sessions.json"), JSON.stringify({ version: 1, sessions }));
}

beforeEach(() => {
  prevAbDir = process.env.ANTGRID_DIR;
  abDir = mkdtempSync(join(tmpdir(), "antgrid-forget-wt-abdir-"));
  process.env.ANTGRID_DIR = abDir;
  host = new HostServer({ remote: fakeRemoteConfig(), remoteRuntimeFactory: () => Promise.resolve(fakeRuntime()) });
});

afterEach(async () => {
  await host?.shutdown();
  host = null;
  if (prevAbDir === undefined) delete process.env.ANTGRID_DIR; else process.env.ANTGRID_DIR = prevAbDir;
  if (abDir) rmSync(abDir, { recursive: true, force: true });
  if (repo) rmSync(repo, { recursive: true, force: true });
  repo = undefined;
});

test("forget() reclaims managed worktrees before the metadata naming them is deleted", async () => {
  const h = host!;
  const { folder, projectId } = await gitProject();
  repo = folder;
  await h.open(projectId, folder, "local");
  const checkout = await new WorktreeManager({ abDir: abDir! })
    .prepareForSession({ projectId, repoPath: folder, sessionId: "s1", sessionName: "One" });
  expect(existsSync(checkout.path)).toBe(true);

  await h.forget(projectId);

  // Reclamation reads `agents/<id>/checkouts.json`, which the store deletion
  // destroys — so this passing is the ordering proof, not just a disk check.
  expect(existsSync(join(abDir!, "wt", projectRootName(folder, projectId)))).toBe(false);
  expect(existsSync(join(abDir!, "agents", projectId))).toBe(false);
  expect((await git(folder, ["worktree", "list", "--porcelain"])).match(/^worktree /gm)?.length).toBe(1);
  // Committed work survives forgetting a project: only the branch's checkout
  // directory is Antgrid's to remove.
  expect(await git(folder, ["branch", "--list", checkout.branch!])).toContain(checkout.branch!);
});

test("forget() still erases the stores when the project folder is gone", async () => {
  const h = host!;
  const { folder, projectId } = await gitProject();
  await h.open(projectId, folder, "local");
  await new WorktreeManager({ abDir: abDir! })
    .prepareForSession({ projectId, repoPath: folder, sessionId: "s1" });
  await h.stop(projectId);
  rmSync(folder, { recursive: true, force: true });

  await h.forget(projectId);

  // Reclamation is best-effort by contract: a Git or fs failure must never
  // strand the store deletion or the catalog update that follow it.
  expect(existsSync(join(abDir!, "agents", projectId))).toBe(false);
  expect(existsSync(join(abDir!, "wt", projectRootName(folder, projectId)))).toBe(false);
  const seen = JSON.parse(readFileSync(join(abDir!, "agents", "projects.json"), "utf8"));
  expect(seen.projects[projectId]).toBeUndefined();
});

test("a cold isolated session whose checkout row is gone is still deletable", async () => {
  const h = host!;
  seedSessions("projA", [{
    id: "a", name: "A", createdAt: 1, lastUsedAt: 10, archived: false,
    checkoutId: "checkout-gone", checkoutKind: "managed-worktree", checkoutState: "missing",
  }]);
  (h as any).seenProjects.set("projA", { path: "/p", label: "projA" });
  await h.handleRemoteAccessVerb({ id: "t", type: "mobile-access:set", enabled: true });

  const res = (await h.handleSessionsDeleteRpc({
    id: "x", timestamp: 0, type: "request", requestId: "rq1", method: "sessions.delete",
    params: { projectId: "projA", sessionId: "a" },
  } as any)) as any;

  // Without the record lookup this fails WORKTREE_MISSING forever: the pre-fix
  // forget() destroyed checkouts.json while leaving these rows behind, so the
  // cold path must tolerate exactly what the warm one does.
  expect(res.ok).toBe(true);
  expect(res.result.deleted).toBe(true);
  expect(await SessionManager.readPersisted(abDir!, "projA", true)).toEqual([]);
});
