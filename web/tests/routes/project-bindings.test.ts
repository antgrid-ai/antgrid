import { describe, test, expect, beforeAll, afterAll, beforeEach } from "bun:test";
import { startTestPg, type PgHandle } from "../helpers/pg.js";
import { buildTestApp } from "../helpers/app.js";
import {
  createTestUser,
  createTestSession,
  createTestSubscription,
} from "../helpers/fixtures.js";

const AGENT_RESOURCE = "http://localhost:8787/api/auth";

let pg: PgHandle;
beforeAll(async () => {
  pg = await startTestPg();
});
afterAll(async () => {
  await pg.stop();
});
beforeEach(async () => {
  await pg.truncate();
});

/**
 * Provision a device through the real session-authenticated route, then mint an
 * OAuth `client_credentials` JWT via the real token endpoint — the same path the
 * bridge takes in prod, so the token carries a `deviceUuid` claim the route must
 * not read.
 *
 * `deviceUuid` is a parameter because it is client-chosen at registration and
 * unique only per user: two accounts naming the same one is the cross-tenant case
 * these tests exist for.
 */
async function provisionAndMintToken(
  app: ReturnType<typeof buildTestApp>["app"],
  cookie: string,
  deviceUuid: string = crypto.randomUUID()
): Promise<{ token: string; deviceUuid: string }> {
  const provision = await app.request("/account/devices", {
    method: "POST",
    headers: { cookie, "content-type": "application/json" },
    body: JSON.stringify({
      deviceUuid,
      ed25519Pub: Buffer.alloc(32, 0xab).toString("base64"),
      x25519Pub: Buffer.alloc(32, 0xcd).toString("base64"),
      platform: "linux",
      displayName: "binding-test-agent",
    }),
  });
  if (provision.status !== 201) {
    throw new Error(`provision failed: ${provision.status} ${await provision.text()}`);
  }
  const creds = (await provision.json()) as { clientId: string; clientSecret: string };
  const mint = await app.request("/api/auth/oauth2/token", {
    method: "POST",
    headers: {
      "content-type": "application/x-www-form-urlencoded",
      authorization:
        "Basic " + Buffer.from(`${creds.clientId}:${creds.clientSecret}`).toString("base64"),
    },
    body: new URLSearchParams({
      grant_type: "client_credentials",
      scope: "agent",
      resource: AGENT_RESOURCE,
    }).toString(),
  });
  if (mint.status !== 200) {
    throw new Error(`mint failed: ${mint.status} ${await mint.text()}`);
  }
  const tokenJson = (await mint.json()) as { access_token: string };
  return { token: tokenJson.access_token, deviceUuid };
}

/** A signed-in bridge on a paid account, ready to bind. */
async function setupAgent(
  app: ReturnType<typeof buildTestApp>["app"],
  email: string,
  deviceUuid?: string
) {
  const user = await createTestUser(pg.db, email);
  await createTestSubscription(pg.db, user.id, { tier: "pro" });
  const { cookie } = await createTestSession(pg.db, user.id);
  const minted = await provisionAndMintToken(app, cookie, deviceUuid);
  return { user, cookie, ...minted };
}

function bind(
  app: ReturnType<typeof buildTestApp>["app"],
  token: string,
  body: Record<string, unknown>
) {
  return app.request("/account/projects/bindings", {
    method: "POST",
    headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
    body: JSON.stringify(body),
  });
}

describe("POST /account/projects/bindings", () => {
  test("creates the project and its binding, and is idempotent per folder", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const { user, token, deviceUuid } = await setupAgent(app, "alice@example.com");

    const res = await bind(app, token, {
      deviceUuid,
      localProjectId: "proj-a",
      localPath: "/home/alice/antgrid",
      repoKey: "github.com/antgrid/antgrid",
    });
    expect(res.status).toBe(200);
    const { projectId } = (await res.json()) as { projectId: string };

    const account = await pg.db.productAccount.findUniqueOrThrow({ where: { userId: user.id } });
    const project = await pg.db.project.findUniqueOrThrow({ where: { id: projectId } });
    expect(project.accountId).toBe(account.id);
    expect(project.repoKey).toBe("github.com/antgrid/antgrid");
    // No displayName in the body, so the repository's own name is the label —
    // the folder name would differ per machine.
    expect(project.displayName).toBe("antgrid");

    const binding = await pg.db.projectBinding.findUniqueOrThrow({
      where: { deviceId_localProjectId: { deviceId: deviceUuid, localProjectId: "proj-a" } },
    });
    expect(binding.projectId).toBe(projectId);
    expect(binding.localPath).toBe("/home/alice/antgrid");
    expect(binding.lastSeenAt).not.toBeNull();

    // A second bind of the same folder moves the path, never adds a row.
    const again = await bind(app, token, {
      deviceUuid,
      localProjectId: "proj-a",
      localPath: "/home/alice/work/antgrid",
      repoKey: "github.com/antgrid/antgrid",
    });
    expect(again.status).toBe(200);
    expect(await again.json()).toEqual({ ok: true, projectId });
    expect(await pg.db.project.count()).toBe(1);
    expect(await pg.db.projectBinding.count()).toBe(1);
    const moved = await pg.db.projectBinding.findUniqueOrThrow({
      where: { deviceId_localProjectId: { deviceId: deviceUuid, localProjectId: "proj-a" } },
    });
    expect(moved.localPath).toBe("/home/alice/work/antgrid");
  });

  test("two machines on one account resolve the same repository to one project", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const user = await createTestUser(pg.db, "bob@example.com");
    await createTestSubscription(pg.db, user.id, { tier: "pro" });
    const { cookie } = await createTestSession(pg.db, user.id);
    const laptop = await provisionAndMintToken(app, cookie);
    const desktop = await provisionAndMintToken(app, cookie);

    const one = await bind(app, laptop.token, {
      deviceUuid: laptop.deviceUuid,
      localProjectId: "p1",
      localPath: "/home/bob/antgrid",
      repoKey: "github.com/antgrid/antgrid",
    });
    const two = await bind(app, desktop.token, {
      deviceUuid: desktop.deviceUuid,
      localProjectId: "p1",
      localPath: "D:/repos/antgrid",
      repoKey: "github.com/antgrid/antgrid",
    });
    expect(one.status).toBe(200);
    expect(two.status).toBe(200);
    expect(((await one.json()) as { projectId: string }).projectId).toBe(
      ((await two.json()) as { projectId: string }).projectId
    );
    expect(await pg.db.project.count()).toBe(1);
    expect(await pg.db.projectBinding.count()).toBe(2);
  });

  test("a folder whose origin remote changed re-points to the new repository", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const { token, deviceUuid } = await setupAgent(app, "carol@example.com");

    const first = await bind(app, token, {
      deviceUuid,
      localProjectId: "p1",
      localPath: "/home/carol/tool",
      repoKey: "github.com/carol/tool",
    });
    const second = await bind(app, token, {
      deviceUuid,
      localProjectId: "p1",
      localPath: "/home/carol/tool",
      repoKey: "github.com/carol-org/tool",
    });
    expect(second.status).toBe(200);
    const before = ((await first.json()) as { projectId: string }).projectId;
    const after = ((await second.json()) as { projectId: string }).projectId;
    expect(after).not.toBe(before);
    // The old project row survives (work may hang off it); the binding moves.
    expect(await pg.db.project.count()).toBe(2);
    expect(await pg.db.projectBinding.count()).toBe(1);
  });

  test("the synthetic per-machine key binds like any other", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const { token, deviceUuid } = await setupAgent(app, "dave@example.com");

    const res = await bind(app, token, {
      deviceUuid,
      localProjectId: "scratch",
      localPath: "/home/dave/scratch",
      repoKey: `local:${deviceUuid}/scratch`,
    });
    expect(res.status).toBe(200);
  });

  test("refuses a repoKey the bridge could not have produced, before the database", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const { token, deviceUuid } = await setupAgent(app, "eve@example.com");

    for (const repoKey of [
      "git@github.com:eve/tool.git",
      "https://github.com/eve/tool.git",
      "github.com/eve",
      "github.com/Eve/Tool",
      "github.com/eve/../tool",
    ]) {
      const res = await bind(app, token, {
        deviceUuid,
        localProjectId: "p1",
        localPath: "/home/eve/tool",
        repoKey,
      });
      expect(res.status).toBe(400);
      expect(((await res.json()) as { error: string }).error).toBe("BAD_REPO_KEY");
    }
    expect(await pg.db.project.count()).toBe(0);
  });

  test("each account gets its own project row for the same repository", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const a = await setupAgent(app, "a-tenant@example.com");
    const b = await setupAgent(app, "b-tenant@example.com");

    const one = await bind(app, a.token, {
      deviceUuid: a.deviceUuid,
      localProjectId: "p1",
      localPath: "/a/antgrid",
      repoKey: "github.com/antgrid/antgrid",
    });
    const two = await bind(app, b.token, {
      deviceUuid: b.deviceUuid,
      localProjectId: "p1",
      localPath: "/b/antgrid",
      repoKey: "github.com/antgrid/antgrid",
    });
    expect(((await one.json()) as { projectId: string }).projectId).not.toBe(
      ((await two.json()) as { projectId: string }).projectId
    );
    expect(await pg.db.project.count()).toBe(2);
  });

  test("account A's token cannot bind a device belonging to account B", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const a = await setupAgent(app, "alice-x@example.com");
    const b = await setupAgent(app, "bob-x@example.com");

    const res = await bind(app, a.token, {
      deviceUuid: b.deviceUuid,
      localProjectId: "p1",
      localPath: "/b/antgrid",
      repoKey: "github.com/antgrid/antgrid",
    });

    expect(res.status).toBe(404);
    expect(await pg.db.project.count()).toBe(0);
    expect(await pg.db.projectBinding.count()).toBe(0);
  });

  test("account A cannot re-point account B's binding by reusing its device uuid", async () => {
    // A device uuid is client-chosen at registration and unique only per user, so
    // A can hold one that collides with B's — while the unique index the binding
    // is addressed by, (device_id, local_project_id), is global. Nothing but the
    // model's own tenancy check stands between that and A owning B's binding.
    const { app } = buildTestApp(pg.db, pg.url);
    const shared = crypto.randomUUID();
    const b = await setupAgent(app, "bob-y@example.com", shared);
    const a = await setupAgent(app, "alice-y@example.com", shared);

    const bBind = await bind(app, b.token, {
      deviceUuid: shared,
      localProjectId: "p1",
      localPath: "/b/antgrid",
      repoKey: "github.com/antgrid/antgrid",
    });
    expect(bBind.status).toBe(200);
    const bProjectId = ((await bBind.json()) as { projectId: string }).projectId;

    const res = await bind(app, a.token, {
      deviceUuid: shared,
      localProjectId: "p1",
      localPath: "/a/antgrid",
      repoKey: "github.com/attacker/tool",
    });

    expect(res.status).toBe(409);
    const binding = await pg.db.projectBinding.findUniqueOrThrow({
      where: { deviceId_localProjectId: { deviceId: shared, localProjectId: "p1" } },
    });
    expect(binding.projectId).toBe(bProjectId);
    expect(binding.localPath).toBe("/b/antgrid");
    // The refusal lands before any write, so A gets no project row out of it
    // either — otherwise a retry loop would mint one repository per attempt.
    expect(await pg.db.project.count()).toBe(1);
  });

  // 401, not the handler's 404: the gate resolves the token's own device and a
  // revoked one takes the credential down with it.
  test("returns 401 when the calling device is revoked", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const { user, token, deviceUuid } = await setupAgent(app, "frank@example.com");
    await pg.db.device.update({
      where: { userId_deviceId: { userId: user.id, deviceId: deviceUuid } },
      data: { revokedAt: new Date() },
    });

    const res = await bind(app, token, {
      deviceUuid,
      localProjectId: "p1",
      localPath: "/home/frank/antgrid",
      repoKey: "github.com/antgrid/antgrid",
    });
    expect(res.status).toBe(401);
  });

  test("returns 403 when the caller holds no active membership", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const { user, token, deviceUuid } = await setupAgent(app, "grace@example.com");
    // Membership is the record of truth, so a user who has left every account has
    // no account to land a project on — the owner fallback is deliberately not
    // consulted here.
    await pg.db.accountMember.updateMany({
      where: { userId: user.id, status: "active" },
      data: { status: "left", endedAt: new Date() },
    });

    const res = await bind(app, token, {
      deviceUuid,
      localProjectId: "p1",
      localPath: "/home/grace/antgrid",
      repoKey: "github.com/antgrid/antgrid",
    });
    expect(res.status).toBe(403);
    expect(await pg.db.project.count()).toBe(0);
  });

  test("rejects a session cookie (binding is Bearer-only)", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const { cookie, deviceUuid } = await setupAgent(app, "heidi@example.com");

    const res = await app.request("/account/projects/bindings", {
      method: "POST",
      headers: { cookie, "content-type": "application/json" },
      body: JSON.stringify({
        deviceUuid,
        localProjectId: "p1",
        localPath: "/home/heidi/antgrid",
        repoKey: "github.com/antgrid/antgrid",
      }),
    });
    expect(res.status).toBe(401);
  });

  test("returns 401 unauthenticated and 400 on a malformed body", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const unauth = await app.request("/account/projects/bindings", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ deviceUuid: crypto.randomUUID() }),
    });
    expect(unauth.status).toBe(401);

    const { token } = await setupAgent(app, "ivan@example.com");
    const bad = await bind(app, token, { deviceUuid: "not-a-uuid", repoKey: "github.com/a/b" });
    expect(bad.status).toBe(400);
    expect(((await bad.json()) as { error: string }).error).toBe("BAD_REQUEST");
  });
});

/**
 * The project list the task surfaces file against.
 *
 * The tenancy assertion is the point: a project is addressed by uuid from the
 * app's picker, so a list that leaked another account's projects would hand a
 * client an id it could then file a task, and publish an issue, against.
 */
describe("GET /account/projects", () => {
  async function makeCaller(email: string) {
    const user = await createTestUser(pg.db, email);
    await createTestSubscription(pg.db, user.id, { tier: "pro" });
    const { cookie } = await createTestSession(pg.db, user.id);
    const account = await pg.db.productAccount.findUniqueOrThrow({
      where: { userId: user.id },
    });
    return { user, cookie, accountId: account.id };
  }

  async function list(
    app: ReturnType<typeof buildTestApp>["app"],
    headers: Record<string, string>
  ) {
    const res = await app.request("/account/projects", { headers });
    return { status: res.status, body: (await res.json()) as Record<string, unknown> };
  }

  test("names the caller's own projects, in display order, and only those", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const owner = await makeCaller("projects-owner@example.com");
    const stranger = await makeCaller("projects-stranger@example.com");
    for (const [repo, name] of [
      ["github.com/acme/zed", "Zed"],
      ["github.com/acme/mine", "Mine"],
    ]) {
      await pg.db.project.create({
        data: { accountId: owner.accountId, repoKey: repo, displayName: name },
      });
    }
    await pg.db.project.create({
      data: {
        accountId: stranger.accountId,
        repoKey: "github.com/acme/theirs",
        displayName: "Theirs",
      },
    });

    const mine = await list(app, { cookie: owner.cookie });
    expect(mine.status).toBe(200);
    expect(mine.body.projects).toEqual([
      { id: expect.any(String), repoKey: "github.com/acme/mine", displayName: "Mine" },
      { id: expect.any(String), repoKey: "github.com/acme/zed", displayName: "Zed" },
    ]);
  });

  test("an account with no projects answers an empty list, not a 404", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const caller = await makeCaller("projects-empty@example.com");

    const res = await list(app, { cookie: caller.cookie });
    expect(res.status).toBe(200);
    expect(res.body.projects).toEqual([]);
  });

  test("the bridge reaches it with its device token", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const caller = await makeCaller("projects-bridge@example.com");
    const { token } = await provisionAndMintToken(app, caller.cookie);
    await pg.db.project.create({
      data: {
        accountId: caller.accountId,
        repoKey: "github.com/acme/b",
        displayName: "B",
      },
    });

    const res = await list(app, { authorization: `Bearer ${token}` });
    expect(res.status).toBe(200);
    expect((res.body.projects as unknown[]).length).toBe(1);
  });

  test("an unauthenticated caller is refused", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const res = await app.request("/account/projects");
    expect(res.status).toBe(401);
  });
});
