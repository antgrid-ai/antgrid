// SPDX-FileCopyrightText: 2026 Radha AI Products
// SPDX-License-Identifier: LicenseRef-Elastic-2.0

import { describe, expect, test } from "bun:test";
import { runInNewContext } from "node:vm";
import { AUTH_MEMORY_SCRIPT, AUTH_METHODS } from "../../src/ui/auth-memory.js";
import { LoginPage } from "../../src/ui/login.js";
import { PendingPage } from "../../src/ui/pending.js";

const KEY = "antgrid.auth.methods.v1";
const LAST = "antgrid.auth.last-method.v1";

class Element {
  value = "";
  hidden = true;
  tagName = "SPAN";
  form = null;
  private listeners = new Map<string, ((event: object) => void)[]>();
  constructor(private attributes: Record<string, string> = {}) {}
  getAttribute(name: string) { return this.attributes[name] ?? null; }
  closest() { return null; }
  addEventListener(name: string, listener: (event: object) => void) {
    this.listeners.set(name, [...(this.listeners.get(name) ?? []), listener]);
  }
  emit(name: string, event = {}) {
    this.listeners.get(name)?.forEach((listener) => listener(event));
  }
}

function browser({
  entries = new Map<string, string>(),
  email = "",
  blocked = false,
  apple = true,
}: { entries?: Map<string, string>; email?: string; blocked?: boolean; apple?: boolean } = {}) {
  const input = new Element();
  input.value = email;
  const window = new Element();
  const html = LoginPage({ apple }).toString();
  const badges = [...html.matchAll(/<span\b[^>]*data-ab-last-used="([^"]+)"[^>]*>/g)]
    .map((match) => new Element({ "data-ab-last-used": match[1]! }));
  const choices = ["github", "google", "apple"].map((method) => {
    const el = new Element({ "data-ab-remember": method });
    el.tagName = "A";
    return el;
  });
  const localStorage = {
    getItem(key: string) {
      if (blocked) throw new Error("Storage unavailable");
      return entries.get(key) ?? null;
    },
    setItem(key: string, value: string) {
      if (blocked) throw new Error("Storage unavailable");
      entries.set(key, value);
    },
  };
  runInNewContext(AUTH_MEMORY_SCRIPT, {
    localStorage, window,
    document: {
      querySelector(selector: string) {
        return selector === "[data-ab-prefill]" || selector === '[name="email"]' ? input : null;
      },
      querySelectorAll(selector: string) {
        if (selector === "[data-ab-last-used]") return badges;
        if (selector === "[data-ab-remember]") return choices;
        return [];
      },
    },
  });
  return {
    entries, input, window, choices,
    visible: () => badges.filter((badge) => !badge.hidden).map((badge) => badge.getAttribute("data-ab-last-used")),
    type(value: string) { input.value = value; input.emit("input"); },
  };
}

describe("Last used sign-in method", () => {
  for (const method of AUTH_METHODS) {
    test(`shows the stored ${method} method after email prefill`, () => {
      const page = browser({ entries: new Map([[KEY, JSON.stringify([{ e: "alice@example.com", m: method }])]]) });
      expect(page.input.value).toBe("alice@example.com");
      expect(page.visible()).toEqual([method]);
    });
  }

  test("follows the typed address, hiding hints for unknown accounts", () => {
    const page = browser({ entries: new Map([
      [KEY, JSON.stringify([{ e: "alice@example.com", m: "github" }, { e: "bob@example.com", m: "password" }])],
      [LAST, "google"],
    ]) });
    page.type(" BOB@example.com ");
    expect(page.visible()).toEqual(["password"]);
    page.type("unknown@example.com");
    expect(page.visible()).toEqual([]);
    page.type("");
    expect(page.visible()).toEqual(["google"]);
  });

  test("remembers an OAuth choice without an email and keeps address routing hints separate", () => {
    const entries = new Map<string, string>();
    const page = browser({ entries });
    page.choices[0]!.emit("click");
    expect(entries.get(LAST)).toBe("github");
    expect(entries.has(KEY)).toBe(false);
    expect(browser({ entries }).visible()).toEqual(["github"]);

    entries.set(KEY, JSON.stringify([{ e: "alice@example.com", m: "password" }]));
    expect(browser({ entries, email: "alice@example.com" }).visible()).toEqual(["password"]);
  });

  test("refreshes on browser back and changes from another tab", () => {
    const page = browser({ email: "alice@example.com" });
    page.entries.set(KEY, JSON.stringify([{ e: "alice@example.com", m: "link" }]));
    page.window.emit("pageshow", { persisted: true });
    expect(page.visible()).toEqual(["link"]);
    page.entries.set(KEY, JSON.stringify([{ e: "alice@example.com", m: "google" }]));
    page.window.emit("storage", { key: KEY });
    expect(page.visible()).toEqual(["google"]);
    page.entries.clear();
    page.window.emit("storage", { key: null });
    expect(page.visible()).toEqual([]);
  });

  test("hides badges when storage is empty, invalid, or unavailable", () => {
    expect(browser().visible()).toEqual([]);
    expect(browser({ blocked: true }).visible()).toEqual([]);
    expect(browser({ entries: new Map([[KEY, "{"], [LAST, "unrecognized"]]) }).visible()).toEqual([]);
    const page = browser({ blocked: true });
    expect(() => page.choices[0]!.emit("click")).not.toThrow();
  });

  test("does not advertise Apple when the deployment does not offer it", () => {
    expect(browser({ apple: false, entries: new Map([[LAST, "apple"]]) }).visible()).toEqual([]);
  });

  test("keeps badges hidden without JavaScript and the password fallback attached to the email form", () => {
    const html = LoginPage({ apple: true }).toString();
    const badges = [...html.matchAll(/<span\b[^>]*data-ab-last-used="([^"]+)"[^>]*>/g)];
    expect(badges).toHaveLength(AUTH_METHODS.length);
    expect(badges.every((match) => /\bhidden(?:[\s>]|=)/.test(match[0]))).toBe(true);
    const password = html.match(/<button\b[^>]*value="password"[^>]*>/)?.[0];
    expect(password).toContain('form="login-form"');
    expect(password).not.toContain("data-ab-remember=");
  });

  test("the email-link landing remembers the address and method after a send", () => {
    const html = PendingPage({ email: "alice@example.com", pendingId: "pending-1" }).toString();
    expect(html).toContain('data-ab-remember-now="link" data-ab-email="alice@example.com"');
  });
});
