// SPDX-FileCopyrightText: 2026 Radha AI Products
// SPDX-License-Identifier: LicenseRef-Elastic-2.0

import { afterAll, beforeAll, beforeEach, describe, expect, test } from "bun:test";
import { startTestPg, type PgHandle } from "../helpers/pg.js";
import {
  admitRecipient, classifyBounce, isSuppressed, liftSuppression, suppressRecipient, sweepSuppressions,
} from "../../src/auth/email-suppression.js";
import { recipientDigest } from "../../src/auth/recipient-key.js";

let pg: PgHandle;
beforeAll(async () => { pg = await startTestPg(); });
afterAll(async () => { await pg.stop(); });
beforeEach(async () => { await pg.truncate(); });

const SECRET = "suppression-test-secret";
const DAY = 86400000;
const hash = recipientDigest(SECRET, "someone@real.io");

describe("classifyBounce", () => {
  const wrap = (details: unknown) => ({ event_data: [{ details: [details] }] });

  test("the live fixture is transient, not suppressing", () => {
    expect(classifyBounce(wrap({ reason: "relaying-issues", diagnostic_message: "bad-mailbox" }))).toBe("transient");
  });
  test("recipient-side reasons", () => {
    expect(classifyBounce(wrap({ reason: "unknown-user" }))).toBe("recipient");
    expect(classifyBounce({ reason: "unknown-user" })).toBe("recipient");
    expect(classifyBounce({ event_data: { details: [{ diagnostic_message: "550 5.1.1 user unknown" }] } })).toBe("recipient");
  });
  test("sender-side wins over generic mailbox wording", () => {
    expect(classifyBounce(wrap({ reason: "550 5.7.1 blocked" }))).toBe("sender");
    expect(classifyBounce(wrap({ reason: "mailbox unavailable 5.7.1" }))).toBe("sender");
  });
  test.each([
    ["553 5.1.8 Sender address rejected: Domain not found", "sender"],
    ["553 5.1.7 Invalid sender mailbox syntax", "sender"],
    ["550 5.1.1 <x@y.io>: Recipient address rejected: User unknown in relay recipient table", "recipient"],
    ["550 5.1.1 <x@y.io> check the address carefully", "recipient"],
    ["550 5.1.1 user unknown [host 10.4.5.6] from 192.5.7.1.9", "recipient"],
    ["452 4.2.2 mailbox full", "transient"],
    ["550 5.7.1 message looks like spam", "sender"],
    ["451 4.7.0 relay access denied", "transient"],
  ] as const)("diagnostic %s is %s", (diagnostic, expected) => {
    expect(classifyBounce(wrap({ diagnostic_message: diagnostic }))).toBe(expected);
  });
  test("a structured recipient category beats misleading free text", () => {
    expect(classifyBounce(wrap({ reason: "unknown-user", diagnostic_message: "relay recipient table, 10.4.5.6" }))).toBe("recipient");
    expect(classifyBounce(wrap({ reason: "bad-mailbox", diagnostic_message: "553 5.1.8 Sender address rejected" }))).toBe("sender");
  });
  test("transient and unclassified", () => {
    expect(classifyBounce(wrap({ reason: "over quota" }))).toBe("transient");
    expect(classifyBounce({})).toBe("unclassified");
    expect(classifyBounce(null)).toBe("unclassified");
    expect(classifyBounce(wrap({ reason: 42 }))).toBe("unclassified");
  });
});

async function row() { return pg.db.emailSuppression.findFirstOrThrow(); }

describe("suppression lifecycle", () => {
  test("suppressing twice keeps one row, counts events and never shortens expiry", async () => {
    await suppressRecipient(pg.db, hash, "recipient", new Date());
    const first = await row();
    await suppressRecipient(pg.db, hash, "unclassified", new Date());
    const second = await row();
    expect(await pg.db.emailSuppression.count()).toBe(1);
    expect(second.events).toBe(2);
    expect(second.reason).toBe("recipient");
    expect(second.expiresAt.getTime()).toBeGreaterThanOrEqual(first.expiresAt.getTime());
    expect(first.expiresAt.getTime() - Date.now()).toBeGreaterThan(179 * DAY);
    expect(await isSuppressed(pg.db, hash)).toBe(true);
  });

  test("unclassified bounces last about a week", async () => {
    await suppressRecipient(pg.db, hash, "unclassified", new Date());
    const ttl = (await row()).expiresAt.getTime() - Date.now();
    expect(ttl).toBeGreaterThan(6 * DAY);
    expect(ttl).toBeLessThan(8 * DAY);
  });

  test("a lift beats a late retry for an earlier job but not a later bounce", async () => {
    const earlyJob = new Date(Date.now() - 60000);
    await suppressRecipient(pg.db, hash, "recipient", earlyJob);
    await liftSuppression(pg.db, hash);
    expect(await isSuppressed(pg.db, hash)).toBe(false);

    await suppressRecipient(pg.db, hash, "recipient", earlyJob);
    expect(await isSuppressed(pg.db, hash)).toBe(false);

    await Bun.sleep(20);
    await suppressRecipient(pg.db, hash, "recipient", new Date());
    expect(await isSuppressed(pg.db, hash)).toBe(true);
    expect((await row()).liftedAt).toBeNull();
  });

  test("a lift does not carry the old expiry into a new suppression", async () => {
    await suppressRecipient(pg.db, hash, "recipient", new Date());
    await liftSuppression(pg.db, hash);
    await Bun.sleep(20);
    await suppressRecipient(pg.db, hash, "unclassified", new Date());
    const current = await row();
    expect(current.reason).toBe("unclassified");
    expect(current.expiresAt.getTime() - Date.now()).toBeLessThan(8 * DAY);
  });

  test("expired rows no longer suppress", async () => {
    await suppressRecipient(pg.db, hash, "recipient", new Date());
    await pg.db.emailSuppression.updateMany({ data: { expiresAt: new Date(Date.now() - 1000) } });
    expect(await isSuppressed(pg.db, hash)).toBe(false);
  });

  test("sweep removes long-expired and long-lifted rows and keeps the rest", async () => {
    const mk = (label: string) => recipientDigest(SECRET, `${label}@real.io`);
    const data = (label: string, extra: object) => ({ recipientHash: mk(label), reason: "recipient", expiresAt: new Date(Date.now() + DAY), ...extra });
    await pg.db.emailSuppression.createMany({ data: [
      data("active", {}),
      data("expired-old", { expiresAt: new Date(Date.now() - 2 * DAY) }),
      data("expired-recent", { expiresAt: new Date(Date.now() - 1000) }),
      data("lifted-old", { liftedAt: new Date(Date.now() - 31 * DAY) }),
      data("lifted-recent", { liftedAt: new Date(Date.now() - DAY) }),
    ] });
    await sweepSuppressions(pg.db);
    const left = (await pg.db.emailSuppression.findMany()).map((r) => Buffer.from(r.recipientHash).toString("hex")).sort();
    const expected = ["active", "expired-recent", "lifted-recent"].map((l) => Buffer.from(mk(l)).toString("hex")).sort();
    expect(left).toEqual(expected);
  });
});

describe("admitRecipient", () => {
  const admit = (email: string, domain: "deliverable" | "no_mail" | "unknown" = "deliverable", googleOnly = false) =>
    admitRecipient(pg.db, SECRET, email, domain, { googleOnly });

  test("passes ordinary and malformed addresses", async () => {
    expect(await admit("someone@real.io")).toBe("ok");
    expect(await admit("not-an-email", "no_mail", true)).toBe("ok");
  });

  test("refuses Gmail only where Google sign-in is required", async () => {
    for (const email of ["x@gmail.com", "X.Y+z@GoogleMail.com", "je.f.f.spea.k.m.a.n@gmail.com"]) {
      expect(await admit(email, "deliverable", true)).toBe("google");
      expect(await admit(email, "deliverable", false)).toBe("ok");
    }
    expect(await admit("x@workspace.io", "deliverable", true)).toBe("ok");
  });

  test("refuses domains that cannot receive mail", async () => {
    expect(await admit("a@dead.io", "no_mail")).toBe("domain");
    expect(await admit("a@dead.io", "unknown")).toBe("ok");
  });

  test("refuses suppressed recipients, including Gmail dot variants", async () => {
    await suppressRecipient(pg.db, recipientDigest(SECRET, "User@Real.io"), "recipient", new Date());
    expect(await admit("user@real.io")).toBe("suppressed");
    await suppressRecipient(pg.db, recipientDigest(SECRET, "jeff@gmail.com"), "recipient", new Date());
    expect(await admit("J.e.f.f+x@googlemail.com")).toBe("suppressed");
  });

  test("checks Gmail before the domain verdict", async () => {
    expect(await admit("x@gmail.com", "no_mail", true)).toBe("google");
  });
});
