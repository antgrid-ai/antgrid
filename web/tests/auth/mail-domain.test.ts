// SPDX-FileCopyrightText: 2026 Radha AI Products
// SPDX-License-Identifier: LicenseRef-Elastic-2.0

import { describe, expect, test } from "bun:test";
import { createMailDomainCheck, mailDomainOf, type MailResolver } from "../../src/auth/mail-domain.js";

const dnsError = (code: string) => Object.assign(new Error(code), { code });
const GOOD_MX = [{ priority: 10, exchange: "mx.gmail-smtp.example" }];

function stub(overrides: Partial<Record<"mx" | "a" | "aaaa", (d: string) => Promise<any>>> = {}) {
  const calls: string[] = [];
  const resolver: MailResolver = {
    resolveMx: (d) => { calls.push("mx:" + d); return (overrides.mx ?? (async (x: string) => (x === "gmail.com" ? GOOD_MX : Promise.reject(dnsError("ENOTFOUND")))))(d); },
    resolve4: (d) => { calls.push("a:" + d); return (overrides.a ?? (async () => Promise.reject(dnsError("ENOTFOUND"))))(d); },
    resolve6: (d) => { calls.push("aaaa:" + d); return (overrides.aaaa ?? (async () => Promise.reject(dnsError("ENODATA"))))(d); },
  };
  return { resolver, calls };
}

describe("createMailDomainCheck", () => {
  test("MX records mean deliverable", async () => {
    const { resolver } = stub({ mx: async () => GOOD_MX });
    expect(await createMailDomainCheck({ resolver })("a@real.test.io")).toBe("deliverable");
  });

  test("null MX, rendered as empty or dot, means no_mail", async () => {
    for (const exchange of ["", "."]) {
      const { resolver } = stub({ mx: async () => [{ priority: 0, exchange }] });
      expect(await createMailDomainCheck({ resolver })("a@nullmx.io")).toBe("no_mail");
    }
  });

  test("MX not found but an address record exists is deliverable", async () => {
    const { resolver } = stub({ mx: async () => { throw dnsError("ENOTFOUND"); }, a: async () => ["1.2.3.4"] });
    expect(await createMailDomainCheck({ resolver })("a@implicit.io")).toBe("deliverable");
  });

  test("no MX, A or AAAA with a healthy canary means no_mail", async () => {
    const { resolver } = stub();
    expect(await createMailDomainCheck({ resolver })("a@b.com")).toBe("no_mail");
  });

  test("an unhealthy canary downgrades no_mail to unknown", async () => {
    const { resolver } = stub({ mx: async () => { throw dnsError("ENOTFOUND"); } });
    expect(await createMailDomainCheck({ resolver })("a@b.com")).toBe("unknown");
  });

  test("resolver faults fail open", async () => {
    for (const fault of [dnsError("ESERVFAIL"), dnsError("ETIMEOUT"), dnsError("ECONNREFUSED"), new Error("boom")]) {
      const { resolver } = stub({ mx: async () => { throw fault; } });
      expect(await createMailDomainCheck({ resolver })("a@fault.io")).toBe("unknown");
    }
  });

  test("an address lookup fault on a missing MX fails open", async () => {
    const { resolver } = stub({ mx: async () => { throw dnsError("ENOTFOUND"); }, a: async () => { throw dnsError("ESERVFAIL"); } });
    expect(await createMailDomainCheck({ resolver })("a@flaky.io")).toBe("unknown");
  });

  test("a lookup that never settles yields unknown at the deadline", async () => {
    const { resolver } = stub({ mx: () => new Promise(() => {}) });
    const started = Date.now();
    expect(await createMailDomainCheck({ resolver, deadlineMs: 50 })("a@hung.io")).toBe("unknown");
    expect(Date.now() - started).toBeLessThan(500);
  });

  test("special-use domains are no_mail without any DNS", async () => {
    const { resolver, calls } = stub();
    const check = createMailDomainCheck({ resolver });
    for (const email of ["dev@antgrid.local", "x@foo.test", "a@example.com", "a@localhost", "a@[1.2.3.4]"]) {
      expect(await check(email)).toBe("no_mail");
    }
    expect(calls).toEqual([]);
  });

  test("the resolver receives the punycoded domain without a trailing dot", async () => {
    const { resolver, calls } = stub({ mx: async () => GOOD_MX });
    await createMailDomainCheck({ resolver })("a@bücher.de.");
    expect(calls).toEqual(["mx:xn--bcher-kva.de"]);
  });

  test("verdicts are cached except unknown", async () => {
    const dead = stub();
    const check = createMailDomainCheck({ resolver: dead.resolver });
    expect(await check("a@dead.io")).toBe("no_mail");
    const before = dead.calls.length;
    expect(await check("b@dead.io")).toBe("no_mail");
    expect(dead.calls.length).toBe(before);

    let fail = true;
    const flaky = stub({ mx: async () => { if (fail) throw dnsError("ESERVFAIL"); return GOOD_MX; } });
    const flakyCheck = createMailDomainCheck({ resolver: flaky.resolver });
    expect(await flakyCheck("a@flaky.io")).toBe("unknown");
    fail = false;
    expect(await flakyCheck("a@flaky.io")).toBe("deliverable");
  });

  test("cached entries expire", async () => {
    let clock = 0;
    const { resolver, calls } = stub({ mx: async () => GOOD_MX });
    const check = createMailDomainCheck({ resolver, now: () => clock });
    await check("a@ttl.io");
    clock += 7 * 3600000;
    await check("a@ttl.io");
    expect(calls.length).toBe(2);
  });

  test("beyond the in-flight cap the check answers unknown immediately", async () => {
    const { resolver } = stub({ mx: () => new Promise(() => {}) });
    const check = createMailDomainCheck({ resolver, maxInFlight: 1, deadlineMs: 5000 });
    void check("a@first.io");
    await Bun.sleep(10);
    const started = Date.now();
    expect(await check("a@second.io")).toBe("unknown");
    expect(Date.now() - started).toBeLessThan(200);
  });
});

describe("mailDomainOf", () => {
  test("returns null without a usable domain", () => {
    expect(mailDomainOf("nodomain")).toBeNull();
    expect(mailDomainOf("a@")).toBeNull();
    expect(mailDomainOf("A@Example.COM.")).toBe("example.com");
  });
});
