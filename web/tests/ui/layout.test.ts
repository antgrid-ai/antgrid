import { describe, test, expect } from "bun:test";
import { Layout } from "../../src/ui/layout.js";
import { BETA } from "../../src/billing/plans.js";

describe("Layout", () => {
  test("renders the wordmark in the header", () => {
    const html = Layout({ title: "Test", children: "x" }).toString();
    // The brand must be surfaced as a visible <img> in the header, not only as
    // a <link rel="icon"> in <head> — that's what brands the visible page.
    expect(html).toContain('<img src="/logo/antgrid-wordmark.svg"');
    // alt text keeps the lockup readable to screen readers / broken loads.
    expect(html).toContain('alt="antgrid"');
  });

  test("marks the product as beta inside the header lockup", () => {
    // Skipped rather than inverted once BETA flips: after launch the badge's
    // absence is the intent, not a regression worth asserting against.
    if (!BETA) return;
    // Signed-out on purpose — this is the beta signal on the pages that have
    // no account to read `promotional` off (login, signup, invite, reset).
    const html = Layout({ title: "Test", children: "x" }).toString();
    const lockup = html.slice(html.indexOf('<a href="/"'), html.indexOf("</a>"));
    expect(lockup).toContain(">beta<");
    // A span, never an anchor: nested anchors are invalid, and the badge is a
    // status marker rather than somewhere to navigate to.
    expect(lockup.slice(1)).not.toContain("<a ");
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
