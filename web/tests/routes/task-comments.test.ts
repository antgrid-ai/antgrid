// SPDX-FileCopyrightText: 2026 Radha AI Products
// SPDX-License-Identifier: LicenseRef-Elastic-2.0

import { describe, test, expect, beforeAll, afterAll, beforeEach } from "bun:test";
import { startTestPg, type PgHandle } from "../helpers/pg.js";
import { buildTestApp } from "../helpers/app.js";
import {
  addTestMember,
  createTestSession,
  createTestSubscription,
  createTestUser,
} from "../helpers/fixtures.js";

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

type CommentJson = {
  id: string;
  author: { kind: string; userId?: string; name?: string; login?: string } | null;
  body: string;
  imported: boolean;
};

async function signedIn(email: string) {
  const user = await createTestUser(pg.db, email);
  await createTestSubscription(pg.db, user.id, { tier: "pro" });
  const { cookie } = await createTestSession(pg.db, user.id);
  const account = await pg.db.productAccount.findUniqueOrThrow({ where: { userId: user.id } });
  return { user, cookie, accountId: account.id };
}

function headers(cookie: string) {
  return { cookie, "content-type": "application/json" };
}

async function createTaskVia(app: App, cookie: string, title: string): Promise<number> {
  const res = await app.request("/tasks", {
    method: "POST",
    headers: headers(cookie),
    body: JSON.stringify({ title, publish: false }),
  });
  if (res.status !== 201) throw new Error(`create failed: ${res.status} ${await res.text()}`);
  return ((await res.json()) as { task: { number: number } }).task.number;
}

function post(app: App, cookie: string, number: number | string, body: unknown) {
  return app.request(`/tasks/${number}/comments`, {
    method: "POST",
    headers: headers(cookie),
    body: JSON.stringify(body),
  });
}

async function list(app: App, cookie: string, number: number): Promise<CommentJson[]> {
  const res = await app.request(`/tasks/${number}/comments`, { headers: headers(cookie) });
  expect(res.status).toBe(200);
  return ((await res.json()) as { comments: CommentJson[] }).comments;
}

async function errorOf(res: Response): Promise<string> {
  return ((await res.json()) as { error: string }).error;
}

describe("task comments", () => {
  test("a member adds a comment and reads it back in order", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const me = await signedIn("me@example.com");
    const number = await createTaskVia(app, me.cookie, "thread");

    const first = await post(app, me.cookie, number, { body: "  first  " });
    expect(first.status).toBe(201);
    const created = ((await first.json()) as { comment: CommentJson }).comment;
    expect(created.body).toBe("first");
    expect(created.imported).toBe(false);
    expect(created.author).toMatchObject({ kind: "member", userId: me.user.id, name: me.user.email });

    await post(app, me.cookie, number, { body: "second" });
    expect((await list(app, me.cookie, number)).map((c) => c.body)).toEqual(["first", "second"]);
  });

  test("the ANT- display id addresses the same thread", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const me = await signedIn("me@example.com");
    const number = await createTaskVia(app, me.cookie, "thread");
    expect((await post(app, me.cookie, `ANT-${number}`, { body: "hi" })).status).toBe(201);
    expect(await list(app, me.cookie, number)).toHaveLength(1);
  });

  test("an empty or whitespace body is refused", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const me = await signedIn("me@example.com");
    const number = await createTaskVia(app, me.cookie, "thread");
    const res = await post(app, me.cookie, number, { body: "   " });
    expect(res.status).toBe(400);
    expect(await errorOf(res)).toBe("EMPTY_COMMENT");
  });

  test("the author edits and deletes their own comment", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const me = await signedIn("me@example.com");
    const number = await createTaskVia(app, me.cookie, "thread");
    const { comment } = (await (await post(app, me.cookie, number, { body: "draft" })).json()) as {
      comment: CommentJson;
    };

    const edit = await app.request(`/tasks/${number}/comments/${comment.id}`, {
      method: "PATCH",
      headers: headers(me.cookie),
      body: JSON.stringify({ body: "final" }),
    });
    expect(edit.status).toBe(200);
    expect(((await edit.json()) as { comment: CommentJson }).comment.body).toBe("final");

    const del = await app.request(`/tasks/${number}/comments/${comment.id}`, {
      method: "DELETE",
      headers: headers(me.cookie),
    });
    expect(del.status).toBe(200);
    expect(await list(app, me.cookie, number)).toEqual([]);

    // Gone is gone: a second delete misses rather than answering ok again.
    const again = await app.request(`/tasks/${number}/comments/${comment.id}`, {
      method: "DELETE",
      headers: headers(me.cookie),
    });
    expect(again.status).toBe(404);
    expect(await errorOf(again)).toBe("COMMENT_NOT_FOUND");
  });

  test("a teammate reads the comment but cannot edit or delete it", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const owner = await signedIn("owner@example.com");
    const mate = await signedIn("mate@example.com");
    await addTestMember(pg.db, owner.accountId, mate.user.id);
    const number = await createTaskVia(app, owner.cookie, "shared");
    const { comment } = (await (await post(app, owner.cookie, number, { body: "mine" })).json()) as {
      comment: CommentJson;
    };

    expect((await list(app, mate.cookie, number)).map((c) => c.body)).toEqual(["mine"]);

    const edit = await app.request(`/tasks/${number}/comments/${comment.id}`, {
      method: "PATCH",
      headers: headers(mate.cookie),
      body: JSON.stringify({ body: "theirs" }),
    });
    expect(edit.status).toBe(403);
    expect(await errorOf(edit)).toBe("NOT_COMMENT_AUTHOR");

    const del = await app.request(`/tasks/${number}/comments/${comment.id}`, {
      method: "DELETE",
      headers: headers(mate.cookie),
    });
    expect(del.status).toBe(403);
  });

  test("an imported comment is listed with its provider author and is read-only", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const me = await signedIn("me@example.com");
    const number = await createTaskVia(app, me.cookie, "imported");
    const task = await pg.db.task.findFirstOrThrow({ where: { accountId: me.accountId, number } });
    const row = await pg.db.taskComment.create({
      data: { taskId: task.id, externalId: "gh:1", authorExternalLogin: "octocat", body: "from GitHub" },
    });

    const [listed] = await list(app, me.cookie, number);
    expect(listed).toMatchObject({ imported: true, author: { kind: "external", login: "octocat" } });

    const edit = await app.request(`/tasks/${number}/comments/${row.id}`, {
      method: "PATCH",
      headers: headers(me.cookie),
      body: JSON.stringify({ body: "rewritten" }),
    });
    expect(edit.status).toBe(409);
    expect(await errorOf(edit)).toBe("COMMENT_IMPORTED");
  });

  test("another account's task and its comments are a 404", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const owner = await signedIn("owner@example.com");
    const stranger = await signedIn("stranger@example.com");
    const number = await createTaskVia(app, owner.cookie, "private");
    const { comment } = (await (await post(app, owner.cookie, number, { body: "secret" })).json()) as {
      comment: CommentJson;
    };

    const read = await app.request(`/tasks/${number}/comments`, { headers: headers(stranger.cookie) });
    expect(read.status).toBe(404);
    expect((await post(app, stranger.cookie, number, { body: "x" })).status).toBe(404);

    // Even holding the uuid, a stranger whose own task shares the number misses.
    const own = await createTaskVia(app, stranger.cookie, "mine");
    expect(own).toBe(number);
    const del = await app.request(`/tasks/${own}/comments/${comment.id}`, {
      method: "DELETE",
      headers: headers(stranger.cookie),
    });
    expect(del.status).toBe(404);
    expect(await errorOf(del)).toBe("COMMENT_NOT_FOUND");
  });

  test("a malformed comment id is a miss, not a server error", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const me = await signedIn("me@example.com");
    const number = await createTaskVia(app, me.cookie, "thread");
    const res = await app.request(`/tasks/${number}/comments/not-a-uuid`, {
      method: "DELETE",
      headers: headers(me.cookie),
    });
    expect(res.status).toBe(404);
  });

  test("a deleted task's thread is a 404", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const me = await signedIn("me@example.com");
    const number = await createTaskVia(app, me.cookie, "doomed");
    await post(app, me.cookie, number, { body: "bye" });
    await app.request(`/tasks/${number}`, { method: "DELETE", headers: headers(me.cookie) });
    const res = await app.request(`/tasks/${number}/comments`, { headers: headers(me.cookie) });
    expect(res.status).toBe(404);
  });
});

describe("GET /tasks/members", () => {
  test("lists every active member, and a listed teammate is assignable", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const owner = await signedIn("owner@example.com");
    const mate = await signedIn("mate@example.com");
    await addTestMember(pg.db, owner.accountId, mate.user.id);

    const res = await app.request("/tasks/members", { headers: headers(mate.cookie) });
    expect(res.status).toBe(200);
    const { members } = (await res.json()) as {
      members: { userId: string; name: string; email: string }[];
    };
    expect(members.map((m) => m.userId).sort()).toEqual([owner.user.id, mate.user.id].sort());
    expect(members.find((m) => m.userId === mate.user.id)).toMatchObject({
      email: "mate@example.com",
      name: "mate@example.com",
    });

    const number = await createTaskVia(app, owner.cookie, "for the teammate");
    const assign = await app.request(`/tasks/${number}`, {
      method: "PATCH",
      headers: headers(owner.cookie),
      body: JSON.stringify({ assignee: { kind: "member", userId: mate.user.id } }),
    });
    expect(assign.status).toBe(200);
  });

  test("a member who left is no longer listed", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const owner = await signedIn("owner@example.com");
    const gone = await signedIn("gone@example.com");
    await addTestMember(pg.db, owner.accountId, gone.user.id);
    await pg.db.accountMember.updateMany({
      where: { accountId: owner.accountId, userId: gone.user.id },
      data: { status: "left", endedAt: new Date() },
    });

    const res = await app.request("/tasks/members", { headers: headers(owner.cookie) });
    const { members } = (await res.json()) as { members: { userId: string }[] };
    expect(members.map((m) => m.userId)).toEqual([owner.user.id]);
  });

  test("another account's members never appear", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const me = await signedIn("me@example.com");
    await signedIn("stranger@example.com");
    const res = await app.request("/tasks/members", { headers: headers(me.cookie) });
    const { members } = (await res.json()) as { members: { userId: string }[] };
    expect(members.map((m) => m.userId)).toEqual([me.user.id]);
  });
});
