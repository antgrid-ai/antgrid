// SPDX-FileCopyrightText: 2026 Radha AI Products
// SPDX-License-Identifier: LicenseRef-Elastic-2.0

import { afterAll, beforeAll, beforeEach, describe, expect, test } from "bun:test";
import { runWithEndpointContext } from "@better-auth/core/context";
import { startTestPg, type PgHandle } from "../helpers/pg.js";
import { TEST_BETTER_AUTH_SECRET, buildTestApp } from "../helpers/app.js";
import { createTestUser } from "../helpers/fixtures.js";
import { recipientDigest } from "../../src/auth/recipient-key.js";

let pg: PgHandle;
beforeAll(async () => { pg = await startTestPg(); });
afterAll(async () => { await pg.stop(); });
beforeEach(async () => { await pg.truncate(); });

async function sessionVia(path: string, opts: { verified: boolean }) {
  const { auth } = buildTestApp(pg.db, pg.url);
  const user = await createTestUser(pg.db, "owner@example.com");
  if (!opts.verified) await pg.db.user.update({ where: { id: user.id }, data: { emailVerified: false } });
  const hash = recipientDigest(TEST_BETTER_AUTH_SECRET, user.email);
  await pg.db.emailSuppression.create({ data: { recipientHash: hash, reason: "recipient", expiresAt: new Date(Date.now() + 86400000) } });
  const context = await auth.$context;
  await runWithEndpointContext({ path } as never, () => context.internalAdapter.createSession(user.id));
  return pg.db.emailSuppression.findUniqueOrThrow({ where: { recipientHash: hash } });
}

describe("suppression lift on session creation", () => {
  test("a verified social callback lifts the suppression", async () => {
    expect((await sessionVia("/callback/google", { verified: true })).liftedAt).not.toBeNull();
  });

  test("a verified ID-token sign-in lifts the suppression", async () => {
    expect((await sessionVia("/sign-in/social", { verified: true })).liftedAt).not.toBeNull();
  });

  test("password sign-in proves no mailbox and leaves it active", async () => {
    expect((await sessionVia("/sign-in/email", { verified: true })).liftedAt).toBeNull();
  });

  test("an unverified user leaves it active", async () => {
    expect((await sessionVia("/callback/google", { verified: false })).liftedAt).toBeNull();
  });
});
