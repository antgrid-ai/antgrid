// SPDX-FileCopyrightText: 2026 Radha AI Products
// SPDX-License-Identifier: LicenseRef-Elastic-2.0

import { describe, test, expect } from "bun:test";
import { taskRoutes } from "../../src/routes/tasks.js";
import type { Auth } from "../../src/auth/better-auth.js";
import type { DB } from "../../src/db/index.js";
import type { Env } from "../../src/env.js";

/**
 * `/tasks/*` already matches the literal `/tasks` in Hono — a wildcard segment
 * is optional, not "one or more below" — so registering the gate on both
 * `/tasks` and `/tasks/*` ran the session lookup and the membership query
 * twice per request. Counting real calls through fakes is the only way to see
 * that: an HTTP status code looks identical either way.
 */
describe("task route gate runs once per request", () => {
  function countingDeps() {
    const calls = { session: 0, membership: 0 };
    const auth = {
      api: {
        getSession: async () => {
          calls.session += 1;
          return {
            session: { id: "sess-1" },
            user: { id: "user-1", email: "a@example.com", name: "A" },
          };
        },
      },
    } as unknown as Auth;
    const db = {
      accountMember: {
        findFirst: async () => {
          calls.membership += 1;
          return { accountId: "acct-1", role: "owner" };
        },
      },
      task: { findMany: async () => [], findFirst: async () => null },
      label: { findMany: async () => [] },
    } as unknown as DB;
    const env = {} as Env;
    return { calls, deps: { db, auth, env } };
  }

  test("GET /tasks", async () => {
    const { calls, deps } = countingDeps();
    const router = taskRoutes(deps);
    const res = await router.request("/tasks");
    expect(res.status).toBe(200);
    expect(calls.session).toBe(1);
    expect(calls.membership).toBe(1);
  });

  test("GET /labels", async () => {
    const { calls, deps } = countingDeps();
    const router = taskRoutes(deps);
    const res = await router.request("/labels");
    expect(res.status).toBe(200);
    expect(calls.session).toBe(1);
    expect(calls.membership).toBe(1);
  });

  test("a sub-path still gets both the gate and the account resolved once", async () => {
    const { calls, deps } = countingDeps();
    const router = taskRoutes(deps);
    const res = await router.request("/tasks/ANT-14");
    // Not found is fine — a bare fake `db` cannot answer this read — the point
    // is that the gate ran, and ran exactly once, before the handler did.
    expect(res.status).toBe(404);
    expect(calls.session).toBe(1);
    expect(calls.membership).toBe(1);
  });
});
