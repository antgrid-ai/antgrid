import { describe, test, expect } from "bun:test";
import { Layout } from "../../src/ui/layout.js";

describe("Layout", () => {
  test("renders the wordmark in the header", () => {
    const html = Layout({ title: "Test", children: "x" }).toString();
    // The brand must be surfaced as a visible <img> in the header, not only as
    // a <link rel="icon"> in <head> — that's what brands the visible page.
    expect(html).toContain('<img src="/logo/antgrid-wordmark.svg"');
    // alt text keeps the lockup readable to screen readers / broken loads.
    expect(html).toContain('alt="antgrid"');
  });

  test("signed-in users get an /account link so delete is discoverable", () => {
    // The whole delete-account flow is unreachable without this link — it's the
    // only entry point to /account, and its absence undercuts the App Store /
    // Play data-deletion compliance the page exists for.
    const html = Layout({
      title: "Test",
      user: { email: "gita@example.com" },
      children: "x",
    }).toString();
    expect(html).toContain('href="/account"');
  });

  test("omits the account menu for signed-out visitors", () => {
    const html = Layout({ title: "Test", children: "x" }).toString();
    expect(html).not.toContain('href="/account"');
  });

  test("signed-in users get a /devices nav link", () => {
    const html = Layout({
      title: "Test",
      user: { email: "gita@example.com" },
      children: "x",
    }).toString();
    expect(html).toContain('href="/devices"');
  });

  test("signed-in users get a /team nav link", () => {
    // Shown to members too, not only owners: it is the only place a member is
    // told whose account their plan and limits come from.
    const html = Layout({
      title: "Test",
      user: { email: "gita@example.com" },
      children: "x",
    }).toString();
    expect(html).toContain('href="/team"');
  });
});
