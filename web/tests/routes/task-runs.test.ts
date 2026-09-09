import { describe, test, expect, beforeAll, afterAll, beforeEach } from "bun:test";
import { startTestPg, type PgHandle } from "../helpers/pg.js";
import { buildTestApp } from "../helpers/app.js";
import { createTestSession, createTestSubscription, createTestUser } from "../helpers/fixtures.js";

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
 * A bridge on its own account: a device provisioned through the real route and
 * a token minted through the real endpoint, so the `deviceUuid` claim the gate
 * re-resolves is genuinely present.
 */
async function setupBridge(app: App, email: string) {
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
      displayName: "runs-test-agent",
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

function bearerHeaders(token: string) {
  return { authorization: `Bearer ${token}`, "content-type": "application/json" };
}
function cookieHeaders(cookie: string) {
  return { cookie, "content-type": "application/json" };
}

async function createTaskVia(app: App, cookie: string, title: string): Promise<number> {
  const res = await app.request("/tasks", {
    method: "POST",
    headers: cookieHeaders(cookie),
    body: JSON.stringify({ title, publish: false }),
  });
  if (res.status !== 201) throw new Error(`create failed: ${res.status} ${await res.text()}`);
  const { task } = (await res.json()) as { task: { number: number } };
  return task.number;
}

function reportRun(
  app: App,
  headers: Record<string, string>,
  number: number,
  body: Record<string, unknown>
) {
  return app.request(`/tasks/${number}/runs`, {
    method: "POST",
    headers,
    body: JSON.stringify(body),
  });
}

function runBody(deviceUuid: string, overrides: Record<string, unknown> = {}) {
  return {
    deviceUuid,
    localProjectId: "9f2c1a0b7d3e4f56",
    sessionId: "5f0f1f2f-3f4f-5f6f-7f8f-9f0f1f2f3f4f",
    status: "working",
    ...overrides,
  };
}

async function errorOf(res: Response): Promise<string> {
  return ((await res.json()) as { error: string }).error;
}

describe("POST /tasks/:number/runs", () => {
  test("a bridge records a run and the task moves to in_progress", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const bridge = await setupBridge(app, "bridge@example.com");
    const number = await createTaskVia(app, bridge.cookie, "ship the thing");

    const res = await reportRun(
      app,
      bearerHeaders(bridge.token),
      number,
      runBody(bridge.deviceUuid, {
        tool: "claude",
        checkoutId: "checkout-1",
        branch: "antgrid/ship-the-thing-a1b2c3d4",
      })
    );

    expect(res.status).toBe(200);
    const body = (await res.json()) as {
      run: { sessionId: string; status: string; branch: string; deviceId: string };
      task: { number: number; status: string };
    };
    expect(body.run.status).toBe("working");
    expect(body.run.deviceId).toBe(bridge.deviceUuid);
    expect(body.run.branch).toBe("antgrid/ship-the-thing-a1b2c3d4");
    expect(body.task.status).toBe("in_progress");
  });

  test("repeated reports for one session are one row", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const bridge = await setupBridge(app, "repeat@example.com");
    const number = await createTaskVia(app, bridge.cookie, "ship the thing");

    await reportRun(app, bearerHeaders(bridge.token), number, runBody(bridge.deviceUuid));
    const second = await reportRun(
      app,
      bearerHeaders(bridge.token),
      number,
      runBody(bridge.deviceUuid, { status: "attention" })
    );

    expect(second.status).toBe(200);
    const { task } = (await second.json()) as { task: { status: string } };
    expect(task.status).toBe("blocked");
    expect(await pg.db.taskRun.count()).toBe(1);
  });

  test("done reports the run and leaves the task alone", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const bridge = await setupBridge(app, "done@example.com");
    const number = await createTaskVia(app, bridge.cookie, "ship the thing");

    const res = await reportRun(
      app,
      bearerHeaders(bridge.token),
      number,
      runBody(bridge.deviceUuid, { status: "done", ended: true, resultSummary: "opened a PR" })
    );

    expect(res.status).toBe(200);
    const body = (await res.json()) as {
      run: { status: string; endedAt: string | null; resultSummary: string | null };
      task: { status: string };
    };
    expect(body.task.status).toBe("open");
    expect(body.run.endedAt).not.toBeNull();
    expect(body.run.resultSummary).toBe("opened a PR");
  });

  // The gate's device names the caller. A machine reporting under another
  // device's id would attribute its work — and the task status write it drives —
  // to a machine that never ran anything.
  test("a run reported for a device the caller does not own is refused", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const bridge = await setupBridge(app, "owner@example.com");
    const other = await setupBridge(app, "stranger@example.com");
    const number = await createTaskVia(app, bridge.cookie, "ship the thing");

    const res = await reportRun(
      app,
      bearerHeaders(bridge.token),
      number,
      runBody(other.deviceUuid)
    );

    expect(res.status).toBe(403);
    expect(await errorOf(res)).toBe("DEVICE_MISMATCH");
    expect(await pg.db.taskRun.count()).toBe(0);
  });

  test("a run reported against another account's task is a 404", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const bridge = await setupBridge(app, "mine@example.com");
    const victim = await setupBridge(app, "theirs@example.com");
    const theirNumber = await createTaskVia(app, victim.cookie, "their private task");

    const res = await reportRun(
      app,
      bearerHeaders(bridge.token),
      theirNumber,
      runBody(bridge.deviceUuid)
    );

    expect(res.status).toBe(404);
    expect(await errorOf(res)).toBe("NOT_FOUND");
    expect(await pg.db.taskRun.count()).toBe(0);
    // And the victim's task is untouched, not merely unreported.
    const theirs = await pg.db.task.findFirstOrThrow({ where: { accountId: victim.accountId } });
    expect(theirs.status).toBe("open");
  });

  test("a cookie caller cannot report a run", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const bridge = await setupBridge(app, "browser@example.com");
    const number = await createTaskVia(app, bridge.cookie, "ship the thing");

    const res = await reportRun(
      app,
      cookieHeaders(bridge.cookie),
      number,
      runBody(bridge.deviceUuid)
    );

    expect(res.status).toBe(403);
    expect(await errorOf(res)).toBe("DEVICE_REQUIRED");
  });

  test("an unauthenticated caller is refused", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const bridge = await setupBridge(app, "anon@example.com");
    const number = await createTaskVia(app, bridge.cookie, "ship the thing");

    const res = await reportRun(
      app,
      { "content-type": "application/json" },
      number,
      runBody(bridge.deviceUuid)
    );

    expect(res.status).toBe(401);
  });

  test("a summary over 200 characters is refused rather than truncated", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const bridge = await setupBridge(app, "verbose@example.com");
    const number = await createTaskVia(app, bridge.cookie, "ship the thing");

    const res = await reportRun(
      app,
      bearerHeaders(bridge.token),
      number,
      runBody(bridge.deviceUuid, { status: "done", resultSummary: "x".repeat(201) })
    );

    expect(res.status).toBe(400);
    expect(await errorOf(res)).toBe("BAD_REQUEST");
    expect(await pg.db.taskRun.count()).toBe(0);
  });

  test("a session already attached to another task is a 409", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const bridge = await setupBridge(app, "conflict@example.com");
    const first = await createTaskVia(app, bridge.cookie, "first");
    const second = await createTaskVia(app, bridge.cookie, "second");

    await reportRun(app, bearerHeaders(bridge.token), first, runBody(bridge.deviceUuid));
    const res = await reportRun(app, bearerHeaders(bridge.token), second, runBody(bridge.deviceUuid));

    expect(res.status).toBe(409);
    expect(await res.json()).toMatchObject({
      error: "SESSION_TASK_CONFLICT",
      boundNumber: first,
    });
  });

  // The app renders a run's PR link as something tappable, so the scheme is
  // part of the contract and not a formatting detail.
  test("a pr url that is not http(s) is refused", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const bridge = await setupBridge(app, "scheme@example.com");
    const number = await createTaskVia(app, bridge.cookie, "ship the thing");

    const res = await reportRun(
      app,
      bearerHeaders(bridge.token),
      number,
      runBody(bridge.deviceUuid, { prUrl: "javascript:alert(1)" })
    );

    expect(res.status).toBe(400);
    expect(await errorOf(res)).toBe("BAD_REQUEST");
    expect(await pg.db.taskRun.count()).toBe(0);
  });
});

describe("GET /tasks/:number/runs", () => {
  test("the account's own runs are listed, another account's task is a 404", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const bridge = await setupBridge(app, "reader@example.com");
    const other = await setupBridge(app, "elsewhere@example.com");
    const number = await createTaskVia(app, bridge.cookie, "ship the thing");
    await reportRun(app, bearerHeaders(bridge.token), number, runBody(bridge.deviceUuid));

    const mine = await app.request(`/tasks/${number}/runs`, {
      headers: cookieHeaders(bridge.cookie),
    });
    expect(mine.status).toBe(200);
    const { runs } = (await mine.json()) as { runs: { sessionId: string }[] };
    expect(runs).toHaveLength(1);

    const theirs = await app.request(`/tasks/${number}/runs`, {
      headers: cookieHeaders(other.cookie),
    });
    expect(theirs.status).toBe(404);
  });
});
