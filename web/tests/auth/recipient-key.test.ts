// SPDX-FileCopyrightText: 2026 Radha AI Products
// SPDX-License-Identifier: LicenseRef-Elastic-2.0

import { createHmac } from "node:crypto";
import { describe, expect, test } from "bun:test";
import { canonicalMailbox, recipientDigest } from "../../src/auth/recipient-key.js";

describe("canonicalMailbox", () => {
  test("folds Gmail dots, +tags, googlemail, case and a trailing dot", () => {
    expect(canonicalMailbox("  Je.F.f+x@GoogleMail.com. ")).toBe(canonicalMailbox("jeff@gmail.com"));
    expect(canonicalMailbox("jeff@gmail.com")).toBe("jeff@gmail.com");
  });

  test("leaves dots and +tags alone for other providers", () => {
    expect(canonicalMailbox("First.Last+x@Outlook.com")).toBe("first.last+x@outlook.com");
  });

  test("splits at the last @ and punycodes the domain", () => {
    expect(canonicalMailbox("a@b@bücher.de.")).toBe("a@b@xn--bcher-kva.de");
  });
});

describe("recipientDigest", () => {
  test("is 32 bytes, stable across variants, and never equals the rate-bucket key", () => {
    const digest = recipientDigest("secret", "Jeff@gmail.com");
    expect(digest.length).toBe(32);
    expect(Buffer.from(recipientDigest("secret", "j.e.f.f+x@googlemail.com")).equals(Buffer.from(digest))).toBe(true);
    const bucketKey = createHmac("sha256", "secret").update(canonicalMailbox("jeff@gmail.com")).digest();
    expect(Buffer.from(digest).equals(bucketKey)).toBe(false);
  });

  test("depends on the secret", () => {
    expect(Buffer.from(recipientDigest("a", "x@y.com")).equals(Buffer.from(recipientDigest("b", "x@y.com")))).toBe(false);
  });
});
