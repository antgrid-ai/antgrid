// Task 13 security gates: the order in which a remote isolated-session request
// is checked, and the fact that every filesystem coordinate is host-derived.
//
// A remote `session:create` reaches the bridge on the project STREAM, so the
// first gates are the ones guarding `project:start` (there is no
// `sessions.create` control-plane verb); the path/branch gates live inside
// WorktreeManager. Both halves are asserted here.
import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { mkdtempSync, rmSync, writeFileSync, mkdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { HostServer, type HostRemoteConfig, type RemoteRuntime } from "../src/host-server";
import { MessageBus } from "../src/message-bus";
import { computeProjectId, isSafeProjectId } from "../src/project-id";
import { projectRootName } from "../src/worktrees/checkout-names";
import { WorktreeManager } from "../src/worktrees/worktree-manager";

function fakeRemoteConfig(): HostRemoteConfig {
  return {
    relayUrl: "ws://127.0.0.1:1",
    licenseApiUrl: "http://127.0.0.1:1",
    identity: { deviceId: "dev-1", deviceName: "dev-1", createdAt: "2026-01-01T00:00:00.000Z" },
    auth: { clientId: "cid", clientSecret: "secret", deviceUuid: "uuid-1" },
    onAuthRevoked: () => {},
  };
}

function fakeRuntime(): RemoteRuntime {
  return { maint: { getToken: () => "tok", stop: () => {} } };
}

async function git(cwd: string, args: string[]): Promise<void> {
  const proc = Bun.spawn(["git", ...args], { cwd, stdout: "ignore", stderr: "pipe" });
  if (await proc.exited !== 0) throw new Error(await new Response(proc.stderr).text());
}

describe("remote isolated-session security", () => {
  let host: HostServer | null = null;
  let abDir: string;
  let repo: string;
  let prevAbDir: string | undefined;

  beforeEach(async () => {
    prevAbDir = process.env.ANTGRID_DIR;
    abDir = mkdtempSync(join(tmpdir(), "antgrid-wt-sec-"));
    process.env.ANTGRID_DIR = abDir;
    repo = mkdtempSync(join(tmpdir(), "antgrid-wt-sec-repo-"));
    await git(repo, ["init"]);
    await git(repo, ["config", "user.email", "test@antgrid.local"]);
    await git(repo, ["config", "user.name", "Test"]);
    writeFileSync(join(repo, "readme.txt"), "v1\n");
    await git(repo, ["add", "."]);
    await git(repo, ["commit", "-m", "initial"]);
    host = new HostServer({
      remote: fakeRemoteConfig(),
      remoteRuntimeFactory: () => Promise.resolve(fakeRuntime()),
    });
  });

  afterEach(async () => {
    await host?.shutdown();
    host = null;
    if (prevAbDir === undefined) delete process.env.ANTGRID_DIR;
    else process.env.ANTGRID_DIR = prevAbDir;
    rmSync(abDir, { recursive: true, force: true });
    rmSync(repo, { recursive: true, force: true });
  });

  function seedCatalog(projectId: string, path: string): void {
    (host as any).seenProjects.set(projectId, { path, label: projectId });
  }

  /** Write a persisted session store for a cold project. */
  function seedManagedSession(projectId: string): void {
    const dir = join(abDir, "agents", projectId);
    mkdirSync(dir, { recursive: true });
    writeFileSync(join(dir, "sessions.json"), JSON.stringify({
      version: 1,
      sessions: [{
        id: "s1", name: "Isolated", createdAt: 1, lastUsedAt: 1, archived: false,
        checkoutId: "checkout-1", checkoutKind: "managed-worktree",
      }],
    }));
  }

  test("gate 1: the machine remote-access switch is checked before any core exists", async () => {
    const projectId = computeProjectId(repo);
    seedCatalog(projectId, repo);
    // Default-off on a fresh machine; no explicit set() call here on purpose.
    const res = await host!.handleControlPlaneVerb(
      { type: "project:start", projectId } as never,
      new MessageBus(),
    );
    expect(res).toMatchObject({ ok: false, error: { code: "NOT_ALLOWED" } });
    // The rejection must precede open(), which would run `terminals:` commands.
    expect(host!.get(projectId)).toBeNull();
  });

  test("gate 2: an id outside the host catalog is rejected, never opened by guess", async () => {
    await host!.handleRemoteAccessVerb({ id: "t", type: "mobile-access:set", enabled: true });
    const res = await host!.handleControlPlaneVerb(
      { type: "project:start", projectId: computeProjectId(repo) } as never,
      new MessageBus(),
    );
    expect(res).toMatchObject({ ok: false, error: { code: "UNKNOWN_PROJECT" } });
    expect(host!.list()).toHaveLength(0);
  });

  test("gate 3: a peer without checkoutRouting cannot start a project holding a managed session", async () => {
    await host!.handleRemoteAccessVerb({ id: "t", type: "mobile-access:set", enabled: true });
    const projectId = computeProjectId(repo);
    seedCatalog(projectId, repo);
    seedManagedSession(projectId);

    const res = await host!.handleControlPlaneVerb(
      { type: "project:start", projectId } as never,
      new MessageBus(),
    );
    expect(res).toMatchObject({ ok: false, error: { code: "UPDATE_REQUIRED" } });
    expect(host!.get(projectId)).toBeNull();

    // ...and the same project is advertised without a dialable streamId, so an
    // old app has nothing to replay onto.
    const advert = host!.buildProjectsAdvertisement().find((p) => p.projectId === projectId);
    expect(advert).toBeDefined();
    expect(advert?.streamId).toBeUndefined();
    expect(advert?.running).toBe(false);
  });

  test("catalog ids are always path-segment safe, so seenProjects cannot smuggle traversal", () => {
    expect(isSafeProjectId(computeProjectId(repo))).toBe(true);
    expect(isSafeProjectId("../../etc")).toBe(false);
  });

  test("gate 4: the worktree path is derived host-side and cannot leave the Antgrid root", async () => {
    const projectId = "project-test";
    const root = resolve(abDir, "wt", projectRootName(repo, projectId));
    // A checkout id is host-generated; model a compromised generator to prove
    // containment holds. Neither segment is the id any more — the directory is
    // built from a slugged word pair and a slugged tail — so the traversal
    // cannot be spelled at all, and the `pathBelow` guard behind that is the
    // second line rather than the only one.
    const escaping = new WorktreeManager({ abDir, newCheckoutId: () => join("..", "..", "escape") });
    const contained = await escaping.prepareForSession({
      projectId, repoPath: repo, sessionId: "s1", sessionName: join("..", "..", "escape"),
    });
    expect(contained.path.toLowerCase().startsWith(root.toLowerCase())).toBe(true);

    const honest = new WorktreeManager({ abDir, newCheckoutId: () => "checkout-1" });
    const record = await honest.prepareForSession({ projectId, repoPath: repo, sessionId: "s2" });
    expect(record.path.toLowerCase().startsWith(root.toLowerCase())).toBe(true);
    // The branch is generated too — the request carries no branch name at all.
    expect(record.branch).toMatch(/^antgrid\//);
  });

  test("gate 4: a base branch that does not exist locally is refused", async () => {
    const manager = new WorktreeManager({ abDir, newCheckoutId: () => "checkout-1" });
    await expect(manager.prepareForSession({
      projectId: "project-test", repoPath: repo, sessionId: "s1", baseBranch: "origin/attacker",
    })).rejects.toMatchObject({ code: "UNKNOWN_BASE_BRANCH" });
  });

  test("gate 4: a non-Git project cannot be isolated", async () => {
    const plain = mkdtempSync(join(tmpdir(), "antgrid-wt-sec-plain-"));
    try {
      const manager = new WorktreeManager({ abDir, newCheckoutId: () => "checkout-1" });
      await expect(manager.prepareForSession({
        projectId: "project-test", repoPath: plain, sessionId: "s1",
      })).rejects.toMatchObject({ code: "NOT_GIT_REPOSITORY" });
    } finally {
      rmSync(plain, { recursive: true, force: true });
    }
  });
});
