import { describe, test, expect, beforeAll, afterAll, beforeEach } from "bun:test";
import { startTestPg, type PgHandle } from "../helpers/pg.js";
import { buildTestApp } from "../helpers/app.js";
import {
  addTestMember,
  createTestSession,
  createTestSubscription,
  createTestUser,
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

type App = ReturnType<typeof buildTestApp>["app"];

/**
 * An account holding both carriers: the session cookie the app and browser use
 * and a device JWT minted through the real token endpoint, which is the only way
 * to get a token carrying the `deviceUuid` claim the gate re-resolves.
 */
async function setupCaller(app: App, email: string) {
  const user = await createTestUser(pg.db, email);
  await createTestSubscription(pg.db, user.id, { tier: "pro" });
  const { cookie } = await createTestSession(pg.db, user.id);
  const deviceUuid = crypto.randomUUID();

  const provision = await app.request("/account/devices", {
    method: "POST",
    headers: { cookie, "content-type": "application/json" },
    body: JSON.stringify({
      deviceUuid,
      ed25519Pub: Buffer.alloc(32, 0xab).toString("base64"),
      x25519Pub: Buffer.alloc(32, 0xcd).toString("base64"),
      platform: "linux",
      displayName: "tasks-test-agent",
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
  if (mint.status !== 200) throw new Error(`mint failed: ${mint.status} ${await mint.text()}`);
  const { access_token: token } = (await mint.json()) as { access_token: string };

  const account = await pg.db.productAccount.findUniqueOrThrow({ where: { userId: user.id } });
  return { user, cookie, token, deviceUuid, accountId: account.id };
}

function cookieHeaders(cookie: string) {
  return { cookie, "content-type": "application/json" };
}
function bearerHeaders(token: string) {
  return { authorization: `Bearer ${token}`, "content-type": "application/json" };
}

function post(app: App, path: string, headers: Record<string, string>, body: unknown) {
  return app.request(path, { method: "POST", headers, body: JSON.stringify(body) });
}
function patch(app: App, path: string, headers: Record<string, string>, body: unknown) {
  return app.request(path, { method: "PATCH", headers, body: JSON.stringify(body) });
}

/** Every create states `publish` — the field is required and has no server-side
 *  default, so a helper that omitted it would be testing a route that does not
 *  exist. Callers override it where publishing is what is under test. */
async function createTaskVia(
  app: App,
  headers: Record<string, string>,
  body: Record<string, unknown>
): Promise<{ number: number }> {
  const res = await post(app, "/tasks", headers, { publish: false, ...body });
  if (res.status !== 201) throw new Error(`create failed: ${res.status} ${await res.text()}`);
  const { task } = (await res.json()) as { task: { number: number } };
  return task;
}

async function makeProject(accountId: string) {
  return pg.db.project.create({
    data: { accountId, repoKey: `github.com/acme/${crypto.randomUUID()}`, displayName: "acme" },
    select: { id: true },
  });
}

async function errorOf(res: Response): Promise<string> {
  return ((await res.json()) as { error: string }).error;
}

describe("task routes: the two gates", () => {
  test("cookie and Bearer reach the same route and resolve the same account", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const caller = await setupCaller(app, "alice@example.com");

    const viaCookie = await createTaskVia(app, cookieHeaders(caller.cookie), {
      title: "written from the browser",
    });
    const viaBearer = await createTaskVia(app, bearerHeaders(caller.token), {
      title: "written from the bridge",
    });

    // Same account, so one number sequence and one list.
    expect(viaCookie.number).toBe(1);
    expect(viaBearer.number).toBe(2);

    const rows = await pg.db.task.findMany({ select: { accountId: true } });
    expect(rows.map((row) => row.accountId)).toEqual([caller.accountId, caller.accountId]);

    for (const headers of [cookieHeaders(caller.cookie), bearerHeaders(caller.token)]) {
      const list = await app.request("/tasks", { headers });
      expect(list.status).toBe(200);
      const { tasks } = (await list.json()) as { tasks: { number: number }[] };
      expect(tasks.map((task) => task.number)).toEqual([1, 2]);
    }
  });

  test("the account is the caller's active membership, not the account they own", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const caller = await setupCaller(app, "member@example.com");
    const teamOwner = await createTestUser(pg.db, "owner@example.com");
    await createTestSubscription(pg.db, teamOwner.id, { tier: "pro" });
    const team = await pg.db.productAccount.findUniqueOrThrow({ where: { userId: teamOwner.id } });
    // The user still OWNS a personal account; `resolveBillingAccountId` would
    // fall back to it and the team would never see the task.
    await addTestMember(pg.db, team.id, caller.user.id);

    await createTaskVia(app, bearerHeaders(caller.token), { title: "for the team" });

    const row = await pg.db.task.findFirstOrThrow({ select: { accountId: true } });
    expect(row.accountId).toBe(team.id);
    expect(row.accountId).not.toBe(caller.accountId);
  });

  test("a caller with no active membership is refused", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const caller = await setupCaller(app, "grace@example.com");
    await pg.db.accountMember.updateMany({
      where: { userId: caller.user.id, status: "active" },
      data: { status: "left", endedAt: new Date() },
    });

    for (const headers of [cookieHeaders(caller.cookie), bearerHeaders(caller.token)]) {
      const res = await post(app, "/tasks", headers, { title: "nowhere to put this" });
      expect(res.status).toBe(403);
      expect(await errorOf(res)).toBe("NO_ACCOUNT");
    }
    expect(await pg.db.task.count()).toBe(0);
  });

  test("a Bearer caller whose device has been revoked is refused", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const caller = await setupCaller(app, "frank@example.com");
    await createTaskVia(app, bearerHeaders(caller.token), { title: "before revocation" });

    await pg.db.device.update({
      where: { userId_deviceId: { userId: caller.user.id, deviceId: caller.deviceUuid } },
      data: { revokedAt: new Date() },
    });

    const res = await app.request("/tasks", { headers: bearerHeaders(caller.token) });
    expect(res.status).toBe(401);
    // The token still verifies; only the device lookup fails, so the cookie the
    // same user holds must not rescue it.
    const withBoth = await app.request("/tasks", {
      headers: { ...bearerHeaders(caller.token), cookie: caller.cookie },
    });
    expect(withBoth.status).toBe(401);
  });

  test("no credential at all is 401", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const res = await app.request("/tasks");
    expect(res.status).toBe(401);
    expect(await errorOf(res)).toBe("UNAUTHENTICATED");
  });
});

describe("task routes: tenancy", () => {
  test("a task number belonging to another account is a 404, never that task", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const victim = await setupCaller(app, "victim@example.com");
    const attacker = await setupCaller(app, "attacker@example.com");

    await createTaskVia(app, cookieHeaders(victim.cookie), {
      title: "customer name and unreleased plan",
    });
    // Numbers restart per account, so #1 exists on both sides of the boundary
    // and a where-clause missing `accountId` would return the victim's row.
    expect(await pg.db.task.count()).toBe(1);

    for (const headers of [cookieHeaders(attacker.cookie), bearerHeaders(attacker.token)]) {
      const read = await app.request("/tasks/1", { headers });
      expect(read.status).toBe(404);

      const edit = await patch(app, "/tasks/1", headers, { title: "taken over" });
      expect(edit.status).toBe(404);

      const remove = await app.request("/tasks/1", { method: "DELETE", headers });
      expect(remove.status).toBe(404);

      const list = await app.request("/tasks", { headers });
      expect(((await list.json()) as { tasks: unknown[] }).tasks).toEqual([]);
    }

    const untouched = await pg.db.task.findFirstOrThrow();
    expect(untouched.title).toBe("customer name and unreleased plan");
    expect(untouched.deletedAt).toBeNull();
  });

  test("a move cannot land a task beside another account's task", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const victim = await setupCaller(app, "victim2@example.com");
    const attacker = await setupCaller(app, "attacker2@example.com");
    // Three on the victim's side and one on the attacker's, so #2 and #3 exist
    // only across the boundary — a neighbour lookup missing `accountId` would
    // resolve them and rank the attacker's task against a stranger's list.
    for (const title of ["theirs 1", "theirs 2", "theirs 3"]) {
      await createTaskVia(app, cookieHeaders(victim.cookie), { title });
    }
    const mine = await createTaskVia(app, cookieHeaders(attacker.cookie), { title: "mine" });
    const before = await pg.db.task.findFirstOrThrow({
      where: { accountId: attacker.accountId },
      select: { sortKey: true },
    });

    for (const neighbours of [{ previousNumber: 2 }, { nextNumber: 3 }]) {
      const res = await post(app, `/tasks/${mine.number}/move`, cookieHeaders(attacker.cookie), {
        previousNumber: null,
        nextNumber: null,
        ...neighbours,
      });
      expect(res.status).toBe(404);
    }

    const after = await pg.db.task.findFirstOrThrow({
      where: { accountId: attacker.accountId },
      select: { sortKey: true },
    });
    expect(after.sortKey).toBe(before.sortKey);
  });
});

describe("task routes: co-assignees", () => {
  /** The snapshot an import leaves behind, written straight to the column: the
   *  route's job is reading it, and standing up a webhook delivery to produce
   *  one would test the drain instead. */
  async function withRemoteAssignees(accountId: string, assignees: unknown[]) {
    const task = await pg.db.task.findFirstOrThrow({ where: { accountId } });
    await pg.db.task.update({
      where: { id: task.id },
      data: {
        remoteSnapshot: {
          title: task.title,
          body: task.body,
          status: { state: "open", stateReason: null },
          labels: [],
          assignee: assignees[0],
          assignees,
        } as never,
      },
    });
  }

  async function readTask(app: App, cookie: string) {
    const res = await app.request("/tasks/1", { headers: cookieHeaders(cookie) });
    expect(res.status).toBe(200);
    return ((await res.json()) as { task: Record<string, unknown> }).task;
  }

  test("a local task has no co-assignees to report", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const caller = await setupCaller(app, "coassignee-local@example.com");
    await createTaskVia(app, cookieHeaders(caller.cookie), {
      title: "wire the drain",
      assignee: { kind: "member", userId: caller.user.id },
    });

    expect((await readTask(app, caller.cookie)).otherAssignees).toEqual([]);
  });

  // GitHub allows ten assignees and the column pair keeps one. The rest are the
  // "+n others on GitHub" marker, and dropping them silently is the lossy
  // display the plan refuses.
  test("an imported multi-assignee task lists the ones the column dropped", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const caller = await setupCaller(app, "coassignee-import@example.com");
    await createTaskVia(app, cookieHeaders(caller.cookie), {
      title: "wire the drain",
      assignee: { kind: "member", userId: caller.user.id },
    });
    await withRemoteAssignees(caller.accountId, [
      { kind: "member", userId: caller.user.id },
      { kind: "external", externalId: "8", login: "outsider", avatarUrl: null },
      { kind: "external", externalId: "9", login: "another", avatarUrl: null },
    ]);

    expect((await readTask(app, caller.cookie)).otherAssignees).toEqual([
      { kind: "external", externalId: "8", login: "outsider", avatarUrl: null },
      { kind: "external", externalId: "9", login: "another", avatarUrl: null },
    ]);
  });

  test("a single remote assignee leaves nothing over", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const caller = await setupCaller(app, "coassignee-one@example.com");
    await createTaskVia(app, cookieHeaders(caller.cookie), {
      title: "wire the drain",
      assignee: { kind: "member", userId: caller.user.id },
    });
    await withRemoteAssignees(caller.accountId, [{ kind: "member", userId: caller.user.id }]);

    expect((await readTask(app, caller.cookie)).otherAssignees).toEqual([]);
  });

  // The snapshot mirrors the body, so shipping it would put a second copy of
  // every imported issue on every list response.
  test("the raw snapshot never crosses the wire", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const caller = await setupCaller(app, "coassignee-blob@example.com");
    await createTaskVia(app, cookieHeaders(caller.cookie), { title: "wire the drain" });
    await withRemoteAssignees(caller.accountId, []);

    expect((await readTask(app, caller.cookie)).remoteSnapshot).toBeUndefined();
  });
});

describe("task routes: CRUD", () => {
  test("create returns 201 and the task the caller can read back", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const caller = await setupCaller(app, "crud@example.com");
    const project = await makeProject(caller.accountId);

    const res = await post(app, "/tasks", cookieHeaders(caller.cookie), {
      title: "  wire the drain  ",
      body: "with backoff",
      status: "in_progress",
      priority: 2,
      projectId: project.id,
      assignee: { kind: "member", userId: caller.user.id },
      publish: false,
    });
    expect(res.status).toBe(201);
    const { task } = (await res.json()) as { task: Record<string, unknown> };
    expect(task.number).toBe(1);
    expect(task.title).toBe("wire the drain");
    expect(task.status).toBe("in_progress");
    expect(task.projectId).toBe(project.id);
    expect(task.assignee).toEqual({ kind: "member", userId: caller.user.id });
    expect(task.source).toBe("local");
    // The uuid is not an address the API offers, so it never crosses the wire.
    expect(task.id).toBeUndefined();
    expect(task.accountId).toBeUndefined();

    const read = await app.request("/tasks/1", { headers: cookieHeaders(caller.cookie) });
    expect(read.status).toBe(200);
    expect(((await read.json()) as { task: { title: string } }).task.title).toBe("wire the drain");
  });

  // The link this app writes into a GitHub issue body is the prefixed form, so
  // the route has to answer it — a 404 there would be self-inflicted.
  test("the prefixed display id addresses the same task as the bare number", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const caller = await setupCaller(app, "displayid@example.com");
    const headers = cookieHeaders(caller.cookie);
    await createTaskVia(app, headers, { title: "wire the drain" });

    for (const path of ["/tasks/1", "/tasks/ANT-1", "/tasks/ant-1"]) {
      const res = await app.request(path, { headers });
      expect(res.status).toBe(200);
      const { task } = (await res.json()) as { task: { number: number; displayId: string } };
      expect(task.number).toBe(1);
      expect(task.displayId).toBe("ANT-1");
    }

    // Another prefix is a miss, not a lenient parse of the digits inside it.
    expect((await app.request("/tasks/OTHER-1", { headers })).status).toBe(404);
  });

  test("a client cannot claim a task was born anywhere but here", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const caller = await setupCaller(app, "source@example.com");
    await createTaskVia(app, bearerHeaders(caller.token), {
      title: "not an import",
      source: "github",
    });
    expect((await pg.db.task.findFirstOrThrow()).source).toBe("local");
  });

  test("patch edits only what it names, and closing stamps closedAt", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const caller = await setupCaller(app, "patch@example.com");
    await createTaskVia(app, cookieHeaders(caller.cookie), { title: "one", body: "keep me" });

    const res = await patch(app, "/tasks/1", cookieHeaders(caller.cookie), { status: "done" });
    expect(res.status).toBe(200);
    const { task } = (await res.json()) as {
      task: { body: string; status: string; closedAt: string | null };
    };
    expect(task.body).toBe("keep me");
    expect(task.status).toBe("done");
    expect(task.closedAt).not.toBeNull();
  });

  test("move reorders without renumbering", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const caller = await setupCaller(app, "move@example.com");
    const headers = cookieHeaders(caller.cookie);
    for (const title of ["a", "b", "c"]) await createTaskVia(app, headers, { title });

    const res = await post(app, "/tasks/3/move", headers, {
      previousNumber: null,
      nextNumber: 1,
    });
    expect(res.status).toBe(200);

    const list = await app.request("/tasks", { headers });
    const { tasks } = (await list.json()) as { tasks: { number: number }[] };
    expect(tasks.map((task) => task.number)).toEqual([3, 1, 2]);
  });

  test("delete is a soft delete that keeps the number spent", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const caller = await setupCaller(app, "delete@example.com");
    const headers = cookieHeaders(caller.cookie);
    await createTaskVia(app, headers, { title: "gone" });

    const res = await app.request("/tasks/1", { method: "DELETE", headers });
    expect(res.status).toBe(200);
    expect((await app.request("/tasks/1", { headers })).status).toBe(404);
    // A second delete is a 404, not a second success.
    expect((await app.request("/tasks/1", { method: "DELETE", headers })).status).toBe(404);
    expect(await pg.db.task.count()).toBe(1);

    const next = await createTaskVia(app, headers, { title: "fresh" });
    expect(next.number).toBe(2);
  });

  test("filters narrow by status, project and assignee", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const caller = await setupCaller(app, "filter@example.com");
    const headers = cookieHeaders(caller.cookie);
    const project = await makeProject(caller.accountId);

    await createTaskVia(app, headers, { title: "open one" });
    await createTaskVia(app, headers, { title: "blocked one", status: "blocked" });
    await createTaskVia(app, headers, {
      title: "mine",
      projectId: project.id,
      assignee: { kind: "member", userId: caller.user.id },
    });

    const numbers = async (query: string) => {
      const res = await app.request(`/tasks${query}`, { headers });
      expect(res.status).toBe(200);
      const { tasks } = (await res.json()) as { tasks: { number: number }[] };
      return tasks.map((task) => task.number);
    };

    expect(await numbers("?status=blocked")).toEqual([2]);
    expect(await numbers("?status=open&status=blocked")).toEqual([1, 2, 3]);
    expect(await numbers(`?projectId=${project.id}`)).toEqual([3]);
    expect(await numbers("?assignee=me")).toEqual([3]);
    expect(await numbers(`?assignee=${caller.user.id}`)).toEqual([3]);
  });
});

describe("task routes: refusals", () => {
  test("a malformed body is a 400, never a 500", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const caller = await setupCaller(app, "malformed@example.com");
    const headers = cookieHeaders(caller.cookie);
    await createTaskVia(app, headers, { title: "exists" });

    const bodies: unknown[] = [
      {},
      { title: 7, publish: false },
      { title: "ok", status: "shipped", publish: false },
      { title: "ok", projectId: "not-a-uuid", publish: false },
      { title: "ok", labelIds: ["not-a-uuid"], publish: false },
      {
        title: "ok",
        assignee: { kind: "external", externalId: "1", login: "octocat" },
        publish: false,
      },
      // Well-formed in every other respect, and still a refusal: `publish` has
      // no server-side default, so an omission can never resolve to an outcome.
      { title: "ok" },
      { title: "ok", publish: "false" },
      { title: "ok", publish: true, publishRepoId: "not-a-uuid" },
    ];
    for (const body of bodies) {
      const res = await post(app, "/tasks", headers, body);
      expect(res.status).toBe(400);
      expect(await errorOf(res)).toBe("BAD_REQUEST");
    }

    const notJson = await app.request("/tasks", { method: "POST", headers, body: "{" });
    expect(notJson.status).toBe(400);

    const badQuery = await app.request("/tasks?status=shipped", { headers });
    expect(badQuery.status).toBe(400);
    const badLimit = await app.request("/tasks?limit=0", { headers });
    expect(badLimit.status).toBe(400);
  });

  test("an unparseable task number is a 404, not a database error", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const caller = await setupCaller(app, "number@example.com");
    const headers = cookieHeaders(caller.cookie);

    for (const path of ["/tasks/abc", "/tasks/0", "/tasks/-1", "/tasks/99999999999999999999"]) {
      const res = await app.request(path, { headers });
      expect(res.status).toBe(404);
    }
  });

  test("invalid_title is INVALID_TITLE, distinct from a malformed body", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const caller = await setupCaller(app, "title@example.com");
    const headers = cookieHeaders(caller.cookie);

    const create = await post(app, "/tasks", headers, { title: "   ", publish: false });
    expect(create.status).toBe(400);
    expect(await errorOf(create)).toBe("INVALID_TITLE");

    await createTaskVia(app, headers, { title: "fine" });
    const edit = await patch(app, "/tasks/1", headers, { title: "" });
    expect(edit.status).toBe(400);
    expect(await errorOf(edit)).toBe("INVALID_TITLE");
  });

  test("project_not_found is PROJECT_NOT_FOUND for another account's project", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const caller = await setupCaller(app, "proj@example.com");
    const stranger = await setupCaller(app, "stranger@example.com");
    const foreign = await makeProject(stranger.accountId);
    const headers = cookieHeaders(caller.cookie);

    const create = await post(app, "/tasks", headers, {
      title: "t",
      projectId: foreign.id,
      publish: false,
    });
    expect(create.status).toBe(400);
    expect(await errorOf(create)).toBe("PROJECT_NOT_FOUND");

    await createTaskVia(app, headers, { title: "fine" });
    const edit = await patch(app, "/tasks/1", headers, { projectId: foreign.id });
    expect(edit.status).toBe(400);
    expect(await errorOf(edit)).toBe("PROJECT_NOT_FOUND");
    expect(await pg.db.task.count()).toBe(1);
  });

  test("assignee_not_member is ASSIGNEE_NOT_MEMBER for a user outside the account", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const caller = await setupCaller(app, "assign@example.com");
    const outsider = await createTestUser(pg.db, "outsider@example.com");
    const headers = cookieHeaders(caller.cookie);

    const res = await post(app, "/tasks", headers, {
      title: "t",
      assignee: { kind: "member", userId: outsider.id },
      publish: false,
    });
    expect(res.status).toBe(400);
    const body = (await res.json()) as { error: string; userId: string };
    expect(body.error).toBe("ASSIGNEE_NOT_MEMBER");
    expect(body.userId).toBe(outsider.id);
  });

  test("not_found is NOT_FOUND on every verb that addresses a task", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const caller = await setupCaller(app, "missing@example.com");
    const headers = cookieHeaders(caller.cookie);

    expect((await app.request("/tasks/9", { headers })).status).toBe(404);
    expect((await patch(app, "/tasks/9", headers, { title: "x" })).status).toBe(404);
    expect(
      (await post(app, "/tasks/9/move", headers, { previousNumber: null, nextNumber: null })).status
    ).toBe(404);
    expect((await app.request("/tasks/9", { method: "DELETE", headers })).status).toBe(404);

    // A neighbour that does not resolve is the same refusal: it is addressed by
    // number too, so it must not distinguish "gone" from "not yours".
    await createTaskVia(app, headers, { title: "only one" });
    const move = await post(app, "/tasks/1/move", headers, { previousNumber: 9, nextNumber: null });
    expect(move.status).toBe(404);
    expect(await errorOf(move)).toBe("NOT_FOUND");
  });

  test("neighbours named in the wrong order are a 400, not a 500", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const caller = await setupCaller(app, "inverted@example.com");
    const headers = cookieHeaders(caller.cookie);
    for (const title of ["a", "b", "c"]) await createTaskVia(app, headers, { title });

    // `keyBetween` has no key to hand back when `before >= after`, and it raises
    // rather than returning a refusal — a well-typed body that would otherwise
    // reach the top-level handler as an INTERNAL.
    for (const neighbours of [
      { previousNumber: 3, nextNumber: 2 },
      { previousNumber: 2, nextNumber: 2 },
    ]) {
      const res = await post(app, "/tasks/1/move", headers, neighbours);
      expect(res.status).toBe(400);
      expect(await errorOf(res)).toBe("NEIGHBOURS_OUT_OF_ORDER");
    }
  });
});

describe("task routes: conflict resolution", () => {
  const RAISED_AT = "2026-08-18T09:30:00.000Z";

  /** The snapshot the last agreed state left behind. Asserted unchanged by the
   *  take-local test: re-seeding it would turn a resolution into a second
   *  surrender the next delivery performs silently. */
  const SNAPSHOT = {
    title: "base title",
    body: "base body",
    status: { state: "open", stateReason: null },
    labels: [] as string[],
    assignee: null,
  };

  type Entry = { localValue: unknown; remoteValue: unknown; at: string };

  /** The state an import leaves on a task both sides edited, written straight to
   *  the columns: standing up a webhook delivery would test the drain instead of
   *  the route. */
  async function withConflict(
    accountId: string,
    blob: { conflicts: Record<string, Entry>; labelRemoveWins?: string[] },
    syncState = "conflict"
  ) {
    const task = await pg.db.task.findFirstOrThrow({
      where: { accountId },
      orderBy: { number: "asc" },
    });
    await pg.db.task.update({
      where: { id: task.id },
      data: {
        source: "github",
        externalProvider: "github",
        externalId: "42",
        syncState,
        remoteSnapshot: SNAPSHOT as never,
        localConflict: {
          conflicts: blob.conflicts,
          labelRemoveWins: blob.labelRemoveWins ?? [],
        } as never,
      },
    });
  }

  function entry(localValue: unknown, remoteValue: unknown): Entry {
    return { localValue, remoteValue, at: RAISED_AT };
  }

  async function readTask(app: App, cookie: string) {
    const res = await app.request("/tasks/1", { headers: cookieHeaders(cookie) });
    expect(res.status).toBe(200);
    return ((await res.json()) as { task: Record<string, unknown> }).task;
  }

  function resolve(app: App, cookie: string, body: unknown, number = 1) {
    return post(app, "/tasks/" + number + "/conflict/resolve", cookieHeaders(cookie), body);
  }

  test("a conflicted task carries every losing edit and the moment it lost", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const caller = await setupCaller(app, "conflict-wire@example.com");
    await createTaskVia(app, cookieHeaders(caller.cookie), { title: "remote title" });
    await withConflict(caller.accountId, {
      conflicts: {
        title: entry("my title", "remote title"),
        body: entry("my body", "remote body"),
      },
      labelRemoveWins: ["needs-triage"],
    });

    expect((await readTask(app, caller.cookie)).conflict).toEqual({
      fields: [
        { field: "title", localValue: "my title", remoteValue: "remote title", at: RAISED_AT },
        { field: "body", localValue: "my body", remoteValue: "remote body", at: RAISED_AT },
      ],
      labelRemoveWins: ["needs-triage"],
    });
  });

  test("a task nothing ever merged carries no conflict at all", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const caller = await setupCaller(app, "conflict-clean@example.com");
    await createTaskVia(app, cookieHeaders(caller.cookie), { title: "born here" });

    expect((await readTask(app, caller.cookie)).conflict).toBeNull();
  });

  // The merge applied the remote value when it raised the conflict, so taking it
  // writes no column — re-deriving it from the blob would clobber whatever the
  // user has edited since.
  test("taking the remote drops the entry and returns the task to synced", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const caller = await setupCaller(app, "conflict-remote@example.com");
    await createTaskVia(app, cookieHeaders(caller.cookie), { title: "remote title" });
    await withConflict(caller.accountId, {
      conflicts: { title: entry("my title", "remote title") },
    });

    const res = await resolve(app, caller.cookie, { field: "title", take: "remote" });
    expect(res.status).toBe(200);
    const { task } = (await res.json()) as { task: Record<string, unknown> };
    expect(task.title).toBe("remote title");
    expect(task.syncState).toBe("synced");
    expect(task.conflict).toBeNull();

    const row = await pg.db.task.findFirstOrThrow({ where: { accountId: caller.accountId } });
    expect(row.localConflict).toBeNull();
  });

  // `remoteSnapshot` stays where it was on purpose: leaving `local != base` is
  // what a future push has to send, and what stops the next delivery — where
  // `remote == base` — clobbering the same edit a second time.
  test("taking the local value writes it back and leaves the snapshot alone", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const caller = await setupCaller(app, "conflict-local@example.com");
    await createTaskVia(app, cookieHeaders(caller.cookie), { title: "remote title" });
    await withConflict(caller.accountId, {
      conflicts: { title: entry("my title", "remote title") },
    });

    const res = await resolve(app, caller.cookie, { field: "title", take: "local" });
    expect(res.status).toBe(200);
    const { task } = (await res.json()) as { task: Record<string, unknown> };
    expect(task.title).toBe("my title");
    expect(task.syncState).toBe("synced");
    expect(task.conflict).toBeNull();

    const row = await pg.db.task.findFirstOrThrow({ where: { accountId: caller.accountId } });
    expect(row.title).toBe("my title");
    expect(row.remoteSnapshot).toEqual(SNAPSHOT);
  });

  test("resolving one of two fields leaves the task in conflict", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const caller = await setupCaller(app, "conflict-partial@example.com");
    await createTaskVia(app, cookieHeaders(caller.cookie), { title: "remote title" });
    await withConflict(caller.accountId, {
      conflicts: {
        title: entry("my title", "remote title"),
        body: entry("my body", "remote body"),
      },
    });

    const res = await resolve(app, caller.cookie, { field: "title", take: "remote" });
    expect(res.status).toBe(200);
    const { task } = (await res.json()) as { task: Record<string, unknown> };
    expect(task.syncState).toBe("conflict");
    expect(task.conflict).toEqual({
      fields: [{ field: "body", localValue: "my body", remoteValue: "remote body", at: RAISED_AT }],
      labelRemoveWins: [],
    });
  });

  // A retry of a resolve that already landed is a call about an entry that no
  // longer exists, not a no-op — answering 200 would let a stale client believe
  // it had just adjudicated something.
  test("resolving the same field twice is NOT_CONFLICTED", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const caller = await setupCaller(app, "conflict-twice@example.com");
    await createTaskVia(app, cookieHeaders(caller.cookie), { title: "remote title" });
    await withConflict(caller.accountId, {
      conflicts: { title: entry("my title", "remote title") },
    });

    expect((await resolve(app, caller.cookie, { field: "title", take: "remote" })).status).toBe(200);
    const again = await resolve(app, caller.cookie, { field: "title", take: "remote" });
    expect(again.status).toBe(409);
    expect(await errorOf(again)).toBe("NOT_CONFLICTED");
  });

  test("a field that never conflicted is NOT_CONFLICTED, not a silent success", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const caller = await setupCaller(app, "conflict-absent@example.com");
    await createTaskVia(app, cookieHeaders(caller.cookie), { title: "remote title" });
    await withConflict(caller.accountId, {
      conflicts: { title: entry("my title", "remote title") },
    });

    const res = await resolve(app, caller.cookie, { field: "status", take: "remote" });
    expect(res.status).toBe(409);
    expect(await errorOf(res)).toBe("NOT_CONFLICTED");
  });

  // Restoring a dropped label would leave it on this task and absent from the
  // issue with nothing to push it, so the marker is acknowledge-only — and the
  // refusal says so rather than quietly treating "local" as an acknowledge.
  test("labels can only be acknowledged, and acknowledging leaves the set alone", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const caller = await setupCaller(app, "conflict-labels@example.com");
    const headers = cookieHeaders(caller.cookie);
    await createTaskVia(app, headers, { title: "remote title" });
    const created = await post(app, "/labels", headers, { name: "bug", color: "ff0000" });
    const { label } = (await created.json()) as { label: { id: string } };
    expect((await post(app, "/tasks/1/labels", headers, { labelId: label.id })).status).toBe(200);
    await withConflict(
      caller.accountId,
      { conflicts: {}, labelRemoveWins: ["needs-triage"] },
      "synced"
    );

    const refused = await resolve(app, caller.cookie, { field: "labels", take: "local" });
    expect(refused.status).toBe(400);
    expect(await errorOf(refused)).toBe("LABELS_LOCAL_UNSUPPORTED");

    const res = await resolve(app, caller.cookie, { field: "labels", take: "remote" });
    expect(res.status).toBe(200);
    const { task } = (await res.json()) as {
      task: { conflict: unknown; syncState: string; labels: { name: string }[] };
    };
    expect(task.conflict).toBeNull();
    expect(task.syncState).toBe("synced");
    expect(task.labels.map((entry) => entry.name)).toEqual(["bug"]);
  });

  // `labelRemoveWins` never raised `conflict`, so acknowledging it must not be
  // the thing that moves a task out of it either.
  test("acknowledging a dropped label leaves a scalar conflict standing", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const caller = await setupCaller(app, "conflict-labels-partial@example.com");
    await createTaskVia(app, cookieHeaders(caller.cookie), { title: "remote title" });
    await withConflict(caller.accountId, {
      conflicts: { title: entry("my title", "remote title") },
      labelRemoveWins: ["needs-triage"],
    });

    const res = await resolve(app, caller.cookie, { field: "labels", take: "remote" });
    expect(res.status).toBe(200);
    const { task } = (await res.json()) as { task: Record<string, unknown> };
    expect(task.syncState).toBe("conflict");
    expect(task.conflict).toEqual({
      fields: [
        { field: "title", localValue: "my title", remoteValue: "remote title", at: RAISED_AT },
      ],
      labelRemoveWins: [],
    });
  });

  // A conflicted task is addressed by the same small sequential number as any
  // other, so the resolve route has to be as anonymous about a miss as the read.
  test("another account's conflicted task is a 404 whatever its number", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const owner = await setupCaller(app, "conflict-owner@example.com");
    const stranger = await setupCaller(app, "conflict-stranger@example.com");
    await createTaskVia(app, cookieHeaders(owner.cookie), { title: "remote title" });
    await withConflict(owner.accountId, { conflicts: { title: entry("my title", "remote title") } });

    for (const number of [1, 2]) {
      const res = await resolve(app, stranger.cookie, { field: "title", take: "remote" }, number);
      expect(res.status).toBe(404);
      expect(await errorOf(res)).toBe("NOT_FOUND");
    }

    const row = await pg.db.task.findFirstOrThrow({ where: { accountId: owner.accountId } });
    expect(row.syncState).toBe("conflict");
    expect(row.localConflict).not.toBeNull();
  });

  // A stored `assigneeUserId` is a value the merge saw, not evidence the user is
  // still on the account.
  test("restoring an assignee who has left the account is refused, not written", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const caller = await setupCaller(app, "conflict-assignee@example.com");
    const outsider = await createTestUser(pg.db, "conflict-outsider@example.com");
    await createTaskVia(app, cookieHeaders(caller.cookie), { title: "remote title" });
    await withConflict(caller.accountId, {
      conflicts: { assignee: entry({ kind: "member", userId: outsider.id }, null) },
    });

    const res = await resolve(app, caller.cookie, { field: "assignee", take: "local" });
    expect(res.status).toBe(400);
    expect(await errorOf(res)).toBe("ASSIGNEE_NOT_MEMBER");

    const row = await pg.db.task.findFirstOrThrow({ where: { accountId: caller.accountId } });
    expect(row.assigneeUserId).toBeNull();
    expect(row.syncState).toBe("conflict");
  });

  // The blob is JSON a merge wrote in the past and nothing has validated since;
  // a value that no longer parses must refuse rather than land in the column
  // every other reader trusts.
  test("a stored local value that no longer parses is refused", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const caller = await setupCaller(app, "conflict-unreadable@example.com");
    await createTaskVia(app, cookieHeaders(caller.cookie), { title: "remote title" });
    await withConflict(caller.accountId, { conflicts: { title: entry("", "remote title") } });

    const res = await resolve(app, caller.cookie, { field: "title", take: "local" });
    expect(res.status).toBe(409);
    expect(await errorOf(res)).toBe("LOCAL_VALUE_UNREADABLE");

    const row = await pg.db.task.findFirstOrThrow({ where: { accountId: caller.accountId } });
    expect(row.title).toBe("remote title");
  });

  // Status is stored in provider space, so restoring it reads back through
  // `fromRemote` rather than being written as it sits in the blob.
  test("a status conflict restores from the provider projection it was stored as", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const caller = await setupCaller(app, "conflict-status@example.com");
    await createTaskVia(app, cookieHeaders(caller.cookie), {
      title: "remote title",
      status: "done",
    });
    await withConflict(caller.accountId, {
      conflicts: {
        status: entry({ state: "open" }, { state: "closed", stateReason: "completed" }),
      },
    });

    const res = await resolve(app, caller.cookie, { field: "status", take: "local" });
    expect(res.status).toBe(200);
    const { task } = (await res.json()) as { task: Record<string, unknown> };
    expect(task.status).toBe("open");
    expect(task.closedAt).toBeNull();
  });

  // `unlinked` is a tombstone: clearing the blob is not evidence of an agreement
  // with a provider this task no longer answers to.
  test("resolving on an unlinked task clears the blob and leaves the state alone", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const caller = await setupCaller(app, "conflict-unlinked@example.com");
    await createTaskVia(app, cookieHeaders(caller.cookie), { title: "remote title" });
    await withConflict(
      caller.accountId,
      { conflicts: { title: entry("my title", "remote title") } },
      "unlinked"
    );

    const res = await resolve(app, caller.cookie, { field: "title", take: "remote" });
    expect(res.status).toBe(200);
    const { task } = (await res.json()) as { task: Record<string, unknown> };
    expect(task.syncState).toBe("unlinked");
    expect(task.conflict).toBeNull();
  });
});

describe("task routes: push blocks", () => {
  const BLOCKED_AT = "2026-08-18T09:30:00.000Z";

  type Entry = { count: number; lastAt: string; reason: string };

  function entry(count: number, reason: string): Entry {
    return { count, lastAt: BLOCKED_AT, reason };
  }

  /** The counter as the outbox executor leaves it, written straight to the
   *  column: standing up a provider round trip would test `apply-op.ts` instead
   *  of the route. */
  async function withPushBlocked(accountId: string, blob: Record<string, Entry>) {
    const task = await pg.db.task.findFirstOrThrow({
      where: { accountId },
      orderBy: { number: "asc" },
    });
    await pg.db.task.update({
      where: { id: task.id },
      data: {
        source: "github",
        externalProvider: "github",
        externalId: "42",
        syncState: "synced",
        pushBlocked: blob as never,
      },
    });
    return task;
  }

  /** A repository the task may be written to, so the re-queued push has a
   *  target to resolve. Rows written directly rather than through the install
   *  flow, which is a provider round trip this route knows nothing about. */
  async function linkPushable(caller: { accountId: string; user: { id: string } }, taskId: string) {
    const integration = await pg.db.integration.create({
      data: {
        accountId: caller.accountId,
        provider: "github",
        externalAccountId: "org-x",
        installationId: crypto.randomUUID(),
        displayName: "acme",
        status: "active",
        installedBy: caller.user.id,
      },
      select: { id: true },
    });
    const repo = await pg.db.integrationRepo.create({
      data: {
        integrationId: integration.id,
        repoKey: `github.com/acme/${crypto.randomUUID()}`,
        externalRepoId: crypto.randomUUID(),
        visibility: "private",
        syncEnabled: true,
        pushEnabled: true,
      },
      select: { id: true },
    });
    await pg.db.task.update({ where: { id: taskId }, data: { integrationRepoId: repo.id } });
  }

  async function readTask(app: App, cookie: string) {
    const res = await app.request("/tasks/1", { headers: cookieHeaders(cookie) });
    expect(res.status).toBe(200);
    return ((await res.json()) as { task: Record<string, unknown> }).task;
  }

  function clear(app: App, cookie: string, body: unknown, number = 1) {
    return post(app, "/tasks/" + number + "/push-block/clear", cookieHeaders(cookie), body);
  }

  // Written status-first, because jsonb hands the keys back in an order of its
  // own: the wire order has to come from the field enum or it is not an order.
  test("a blocked task names every field that stopped, in field order", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const caller = await setupCaller(app, "block-wire@example.com");
    await createTaskVia(app, cookieHeaders(caller.cookie), { title: "declined" });
    await withPushBlocked(caller.accountId, {
      status: entry(4, "GitHub ignores state_reason unless the open/closed state changes"),
      title: entry(3, "GitHub stored a different title"),
    });

    expect((await readTask(app, caller.cookie)).pushBlocked).toEqual({
      fields: [
        {
          field: "title",
          reason: "GitHub stored a different title",
          count: 3,
          lastAt: BLOCKED_AT,
        },
        {
          field: "status",
          reason: "GitHub ignores state_reason unless the open/closed state changes",
          count: 4,
          lastAt: BLOCKED_AT,
        },
      ],
    });
  });

  test("a task nothing ever declined carries no push block at all", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const caller = await setupCaller(app, "block-clean@example.com");
    await createTaskVia(app, cookieHeaders(caller.cookie), { title: "born here" });

    expect((await readTask(app, caller.cookie)).pushBlocked).toBeNull();
  });

  // A field mid-count is still being pushed. Reporting it would tell a user a
  // value stopped syncing while it is still on its way.
  test("a field under the threshold is not reported and cannot be cleared", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const caller = await setupCaller(app, "block-counting@example.com");
    await createTaskVia(app, cookieHeaders(caller.cookie), { title: "declined once" });
    await withPushBlocked(caller.accountId, { title: entry(2, "GitHub stored a different title") });

    expect((await readTask(app, caller.cookie)).pushBlocked).toBeNull();
    const res = await clear(app, caller.cookie, { field: "title" });
    expect(res.status).toBe(409);
    expect(await errorOf(res)).toBe("NOT_BLOCKED");

    const row = await pg.db.task.findFirstOrThrow({ where: { accountId: caller.accountId } });
    expect(row.pushBlocked).toEqual({ title: entry(2, "GitHub stored a different title") });
  });

  // Lifting the block alone would change nothing anyone can see: the op that
  // carried the field was cancelled when the block was read, and the outbox is
  // driven by edits. So the value the provider never took is queued again.
  test("clearing lifts the block and queues the value that never landed", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const caller = await setupCaller(app, "block-clear@example.com");
    await createTaskVia(app, cookieHeaders(caller.cookie), { title: "the title GitHub declined" });
    const task = await withPushBlocked(caller.accountId, {
      title: entry(3, "GitHub stored a different title"),
    });
    await linkPushable(caller, task.id);

    const res = await clear(app, caller.cookie, { field: "title" });
    expect(res.status).toBe(200);
    expect(((await res.json()) as { task: Record<string, unknown> }).task.pushBlocked).toBeNull();

    const row = await pg.db.task.findUniqueOrThrow({ where: { id: task.id } });
    expect(row.pushBlocked).toBeNull();

    const ops = await pg.db.taskSyncOp.findMany({ where: { taskId: task.id } });
    expect(ops).toHaveLength(1);
    expect(ops[0]?.kind).toBe("issue.patch.title");
    expect(ops[0]?.status).toBe("pending");
    expect(ops[0]?.payload).toMatchObject({ title: "the title GitHub declined" });
  });

  // The push is queued undiffed on purpose: what is re-sent is exactly a value
  // the row already holds and the provider does not, so a diff against the row
  // would queue nothing and the button would be decorative.
  test("clearing labels queues the set the task holds now", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const caller = await setupCaller(app, "block-labels@example.com");
    const headers = cookieHeaders(caller.cookie);
    await createTaskVia(app, headers, { title: "labelled" });
    const created = await post(app, "/labels", headers, { name: "bug", color: "ff0000" });
    const { label } = (await created.json()) as { label: { id: string } };
    expect((await post(app, "/tasks/1/labels", headers, { labelId: label.id })).status).toBe(200);
    const task = await withPushBlocked(caller.accountId, {
      labels: entry(3, "GitHub returned a different label set"),
    });
    await linkPushable(caller, task.id);

    expect((await clear(app, caller.cookie, { field: "labels" })).status).toBe(200);

    const ops = await pg.db.taskSyncOp.findMany({ where: { taskId: task.id } });
    expect(ops).toHaveLength(1);
    expect(ops[0]?.kind).toBe("issue.labels");
    expect(ops[0]?.payload).toMatchObject({ labels: ["bug"] });
  });

  test("clearing one field leaves the others stopped", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const caller = await setupCaller(app, "block-partial@example.com");
    await createTaskVia(app, cookieHeaders(caller.cookie), { title: "declined" });
    await withPushBlocked(caller.accountId, {
      title: entry(3, "GitHub stored a different title"),
      body: entry(3, "GitHub stored a different body"),
    });

    const res = await clear(app, caller.cookie, { field: "title" });
    expect(res.status).toBe(200);
    const { task } = (await res.json()) as { task: Record<string, unknown> };
    expect(task.pushBlocked).toEqual({
      fields: [
        { field: "body", reason: "GitHub stored a different body", count: 3, lastAt: BLOCKED_AT },
      ],
    });
  });

  // A retry of a clear that already landed is a call about a block that no
  // longer exists, not a no-op — 200 would let a stale client believe it had
  // just restarted something.
  test("clearing the same field twice is NOT_BLOCKED", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const caller = await setupCaller(app, "block-twice@example.com");
    await createTaskVia(app, cookieHeaders(caller.cookie), { title: "declined" });
    await withPushBlocked(caller.accountId, { title: entry(3, "GitHub stored a different title") });

    expect((await clear(app, caller.cookie, { field: "title" })).status).toBe(200);
    const again = await clear(app, caller.cookie, { field: "title" });
    expect(again.status).toBe(409);
    expect(await errorOf(again)).toBe("NOT_BLOCKED");
  });

  // `assignee` is never pushed by construction, so it can never be blocked and
  // the route must not accept a name the counter has no vocabulary for.
  test("a field outside the pushable set is a 400 and writes nothing", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const caller = await setupCaller(app, "block-unpushable@example.com");
    await createTaskVia(app, cookieHeaders(caller.cookie), { title: "declined" });
    await withPushBlocked(caller.accountId, { title: entry(3, "GitHub stored a different title") });

    for (const body of [{ field: "assignee" }, {}]) {
      const res = await clear(app, caller.cookie, body);
      expect(res.status).toBe(400);
      expect(await errorOf(res)).toBe("BAD_REQUEST");
    }

    const row = await pg.db.task.findFirstOrThrow({ where: { accountId: caller.accountId } });
    expect(row.pushBlocked).not.toBeNull();
  });

  // Addressed by the same small sequential number as any other task, so a miss
  // and another account's task have to be the same answer.
  test("another account's blocked task is a 404 whatever its number", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const owner = await setupCaller(app, "block-owner@example.com");
    const stranger = await setupCaller(app, "block-stranger@example.com");
    await createTaskVia(app, cookieHeaders(owner.cookie), { title: "declined" });
    await withPushBlocked(owner.accountId, { title: entry(3, "GitHub stored a different title") });

    for (const number of [1, 2]) {
      const res = await clear(app, stranger.cookie, { field: "title" }, number);
      expect(res.status).toBe(404);
      expect(await errorOf(res)).toBe("NOT_FOUND");
    }

    const row = await pg.db.task.findFirstOrThrow({ where: { accountId: owner.accountId } });
    expect(row.pushBlocked).not.toBeNull();
  });

  // The whole point of putting it on the wire: a client that cannot see the
  // block cannot tell a saved value from a synced one.
  test("the list carries the block, not only the single-task read", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const caller = await setupCaller(app, "block-list@example.com");
    await createTaskVia(app, cookieHeaders(caller.cookie), { title: "declined" });
    await withPushBlocked(caller.accountId, { title: entry(3, "GitHub stored a different title") });

    const res = await app.request("/tasks", { headers: cookieHeaders(caller.cookie) });
    expect(res.status).toBe(200);
    const { tasks } = (await res.json()) as { tasks: { pushBlocked: unknown }[] };
    expect(tasks[0]?.pushBlocked).toEqual({
      fields: [
        { field: "title", reason: "GitHub stored a different title", count: 3, lastAt: BLOCKED_AT },
      ],
    });
  });
});

/**
 * The carrier gate on the one verb that cannot be taken back.
 *
 * `requireBearerJwt` blanks `sessionId`, so a device token is the only thing
 * that says a request came from a machine rather than a person. Every
 * assertion here is that the refusal happens on the credential and *before*
 * anything else is considered — a 409 about a missing repository would mean the
 * route reasoned about the publish at all.
 */
describe("task routes: publishing is not reachable programmatically", () => {
  test("a device credential cannot create a published task", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const caller = await setupCaller(app, "publish-bearer@example.com");

    const res = await post(app, "/tasks", bearerHeaders(caller.token), {
      title: "a private note",
      publish: true,
    });
    expect(res.status).toBe(403);
    expect(await errorOf(res)).toBe("PUBLISH_REQUIRES_SESSION");
    expect(await pg.db.task.count({ where: { accountId: caller.accountId } })).toBe(0);
  });

  test("the same caller may still create a local task", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const caller = await setupCaller(app, "publish-bearer-local@example.com");

    const task = await createTaskVia(app, bearerHeaders(caller.token), { title: "from a bridge" });
    expect(task.number).toBe(1);
  });

  test("a device credential cannot publish an existing task", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const caller = await setupCaller(app, "publish-bearer-after@example.com");
    await createTaskVia(app, cookieHeaders(caller.cookie), { title: "a private note" });

    const res = await post(app, "/tasks/1/publish", bearerHeaders(caller.token), {});
    expect(res.status).toBe(403);
    expect(await errorOf(res)).toBe("PUBLISH_REQUIRES_SESSION");
  });

  // Unlink writes nothing to the provider and reads nothing out of it, so it is
  // deliberately outside the gate: a bridge that stops syncing a task has not
  // published anything.
  test("unlink is not gated on the carrier", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const caller = await setupCaller(app, "unlink-bearer@example.com");
    await createTaskVia(app, cookieHeaders(caller.cookie), { title: "never linked" });

    const res = await post(app, "/tasks/1/unlink", bearerHeaders(caller.token), {});
    expect(res.status).toBe(409);
    expect(await errorOf(res)).toBe("NOT_LINKED");
  });
});
